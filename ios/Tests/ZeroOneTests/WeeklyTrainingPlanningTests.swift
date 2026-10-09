import XCTest
@testable import ZeroOne

@MainActor
final class WeeklyTrainingPlanningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_024_000)
    private let planner = WeeklyTrainingPlanner()
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var programme: WorkoutProgramme { WorkoutProgrammeLibrary.programme(id: .zeroOneStart)! }

    func testSpacingUsesConfirmedAvailabilityAndKeepsFrequencyAndFullProgramme() throws {
        let context = try context(days: [2, 3, 4])
        let available = availability([2, 3, 4, 6])
        let proposal = try planner.proposal(change: .spreadDays, availability: available, context: context, at: now, calendar: calendar)
        XCTAssertEqual(proposal.proposedWeekdays.count, context.schedule.weekdays.count)
        XCTAssertTrue(proposal.proposedWeekdays.isSubset(of: available.weekdays))
        XCTAssertLessThan(planner.adjacentPairs(proposal.proposedWeekdays), planner.adjacentPairs(Set(context.schedule.weekdays)))
        XCTAssertEqual(proposal.programme, programme)
        XCTAssertEqual(proposal.originalSchedule, context.schedule)
        XCTAssertEqual(proposal.programme.sessions, context.programme.sessions)
        XCTAssertEqual(try planner.proposal(change: .spreadDays, availability: available, context: context, at: now, calendar: calendar), proposal)
    }

    func testFoundationSundaySaturdaySpacingIsIndependentOfDisplayedFirstWeekday() throws {
        XCTAssertEqual(planner.adjacentPairs([7, 1, 2]), 2)
        let source = try context(days: [7, 1, 2])
        let available = availability(Set(1 ... 7))
        var monday = calendar
        monday.firstWeekday = 2
        let sunday = try planner.proposal(change: .spreadDays, availability: available, context: source, at: now, calendar: calendar)
        let other = try planner.proposal(change: .spreadDays, availability: available, context: source, at: now, calendar: monday)
        XCTAssertEqual(sunday.proposedWeekdays, other.proposedWeekdays)
        XCTAssertEqual(planner.adjacentPairs(sunday.proposedWeekdays), 0)
    }

    func testFewerDaysChangesOnlyFrequencyAndKeepsAtLeastProgrammeMinimum() throws {
        let source = try context(days: [2, 3, 4])
        let proposal = try planner.proposal(change: .fewerDays, availability: availability(Set(1 ... 7)), context: source, at: now, calendar: calendar)
        XCTAssertEqual(proposal.proposedWeekdays.count, 2)
        XCTAssertTrue(proposal.proposedWeekdays.isSubset(of: Set(source.schedule.weekdays)))
        XCTAssertEqual(proposal.programme.sessions.map(\.exercisePlans), programme.sessions.map(\.exercisePlans))
        let minimum = try context(days: [2, 5])
        XCTAssertThrowsError(try planner.proposal(change: .fewerDays, availability: availability(Set(1 ... 7)), context: minimum, at: now, calendar: calendar)) {
            XCTAssertEqual($0 as? WeeklyTrainingPlanningError, .noChange)
        }
    }

    func testAlreadySpacedAndInsufficientAvailableDaysKeepExistingPlan() throws {
        let spaced = try context(days: [2, 4, 6])
        XCTAssertThrowsError(try planner.proposal(change: .spreadDays, availability: availability(Set(spaced.schedule.weekdays)), context: spaced, at: now, calendar: calendar)) {
            XCTAssertEqual($0 as? WeeklyTrainingPlanningError, .noChange)
        }
        XCTAssertThrowsError(try planner.proposal(change: .spreadDays, availability: availability([2]), context: spaced, at: now, calendar: calendar))
        XCTAssertEqual(spaced.schedule.weekdays, [2, 4, 6])
    }

    func testUnavailableStaleFutureWrongZoneAndWrongDayAvailabilityRejects() throws {
        let source = try context()
        let values = [availability([]), availability([0, 2, 8]), availability([2, 3, 4], at: now.addingTimeInterval(-601)),
            availability([2, 3, 4], at: now.addingTimeInterval(1)),
            ReportedTrainingWeekdays(weekdays: [2, 3, 4], confirmedAt: now, timeZoneID: "Europe/Sofia")]
        for value in values {
            XCTAssertThrowsError(try planner.proposal(change: .fewerDays, availability: value, context: source, at: now, calendar: calendar)) {
                XCTAssertEqual($0 as? WeeklyTrainingPlanningError, .availability)
            }
        }
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let yesterday = availability([2, 3, 4], at: midnight.addingTimeInterval(-30))
        let nextDay = try context(at: midnight)
        XCTAssertThrowsError(try planner.proposal(change: .fewerDays, availability: yesterday, context: nextDay, at: midnight, calendar: calendar))
    }

    func testCurrentSymptomsActiveWorkAndResolvedConcernDoNotAuthoriseWeeklyChange() throws {
        for source in [try context(active: true), try context(pain: true), try context(soreness: .none)] {
            let expected: WeeklyTrainingPlanningError = source.hasUnfinishedWorkout ? .activeWorkout
                : source.assessment.recommendations.contains(where: { $0.kind == .symptoms }) ? .symptoms : .noConcern
            XCTAssertThrowsError(try planner.proposal(change: .fewerDays, availability: availability([2, 3, 4]), context: source, at: now, calendar: calendar)) {
                XCTAssertEqual($0 as? WeeklyTrainingPlanningError, expected)
            }
        }
    }

    func testFreshAcceptanceRejectsScheduleConcernAndAppointmentChanges() throws {
        let original = try context()
        let proposal = try planner.proposal(change: .fewerDays, availability: availability([2, 3, 4]), context: original, at: now, calendar: calendar)
        let changedSchedule = try context(days: [2, 4, 6])
        let changedConcern = try context(energy: .low)
        let appointment = WorkoutAppointment(reference: .programme(programme.id, sessionID: programme.sessions[0].id),
            title: "Booked training", startsAt: now.addingTimeInterval(3_600), timeZoneIdentifier: calendar.timeZone.identifier)
        let changedAppointment = try context(appointments: [appointment])
        for changed in [changedSchedule, changedConcern, changedAppointment] {
            XCTAssertThrowsError(try planner.revalidated(proposal, context: changed, at: now, calendar: calendar)) {
                XCTAssertEqual($0 as? WeeklyTrainingPlanningError, .stale)
            }
        }
        XCTAssertEqual(try planner.revalidated(proposal, context: original, at: now, calendar: calendar), proposal)
        XCTAssertThrowsError(try planner.revalidated(proposal, context: try context(soreness: .none), at: now, calendar: calendar))
        XCTAssertThrowsError(try planner.revalidated(proposal, context: try context(pain: true), at: now, calendar: calendar))
    }

    func testExpiredProposalAndTamperedOutputAreRejected() throws {
        let original = try context()
        let proposed = try planner.proposal(change: .fewerDays, availability: availability([2, 3, 4]), context: original, at: now, calendar: calendar)
        let later = now.addingTimeInterval(601)
        XCTAssertThrowsError(try planner.revalidated(proposed, context: try context(at: later), at: later, calendar: calendar)) {
            XCTAssertEqual($0 as? WeeklyTrainingPlanningError, .stale)
        }
        let tampered = WeeklyTrainingProposal(policyVersion: proposed.policyVersion, change: proposed.change, offeredAt: now,
            timeZoneID: proposed.timeZoneID, availability: proposed.availability, programme: proposed.programme,
            originalSchedule: proposed.originalSchedule, proposedWeekdays: [1, 5], concerns: proposed.concerns, appointments: [])
        XCTAssertThrowsError(try planner.revalidated(tampered, context: original, at: now, calendar: calendar))
    }

    func testStaleScreenCannotOverwriteNewerConfirmedSchedule() throws {
        let store = WeeklyScheduleStore()
        let coordinator = WorkoutProgrammeCoordinator(selectionStore: WeeklySelectionStore(), scheduleStore: store)
        try coordinator.confirmSchedule(for: programme.id, weekdays: [2, 3, 4], at: now)
        let reviewed = coordinator.activeSchedule
        let newer = try WorkoutProgrammeSchedule(programme: programme, weekdays: [2, 4, 6], confirmedAt: now.addingTimeInterval(1))
        store.stored = newer
        let writes = store.writes
        XCTAssertThrowsError(try coordinator.confirmSchedule(for: programme.id, weekdays: [2, 5], replacing: reviewed, at: now.addingTimeInterval(2))) {
            XCTAssertEqual($0 as? WorkoutProgrammeScheduleError, .staleSchedule)
        }
        XCTAssertEqual(store.stored, newer)
        XCTAssertEqual(store.writes, writes)
        XCTAssertTrue(coordinator.reloadSchedule(at: now.addingTimeInterval(2)))
        XCTAssertEqual(coordinator.activeSchedule, newer)
    }

    func testCorruptAfterInitializationAndFutureSchedulesArePreserved() throws {
        let store = WeeklyScheduleStore()
        let coordinator = WorkoutProgrammeCoordinator(selectionStore: WeeklySelectionStore(), scheduleStore: store)
        try coordinator.confirmSchedule(for: programme.id, weekdays: [2, 3, 4], at: now)
        let reviewed = coordinator.activeSchedule
        store.failRead = true
        XCTAssertThrowsError(try coordinator.confirmSchedule(for: programme.id, weekdays: [2, 5], replacing: reviewed, at: now))
        XCTAssertEqual(store.stored, reviewed)
        XCTAssertFalse(coordinator.scheduleIsAvailable)
        store.failRead = false
        let future = try WorkoutProgrammeSchedule(programme: programme, weekdays: [2, 4, 6], confirmedAt: now.addingTimeInterval(10))
        store.stored = future
        XCTAssertFalse(coordinator.reloadSchedule(at: now))
        XCTAssertThrowsError(try coordinator.confirmSchedule(for: programme.id, weekdays: [2, 5], replacing: reviewed, at: now))
        XCTAssertEqual(store.stored, future)
        XCTAssertThrowsError(try WorkoutProgrammeSchedule(programme: programme, weekdays: [2, 5], confirmedAt: .init(timeIntervalSinceReferenceDate: .infinity)))
    }

    func testFailedReadbackDoesNotPublishAnUnacknowledgedSchedule() throws {
        let store = WeeklyScheduleStore()
        let coordinator = WorkoutProgrammeCoordinator(selectionStore: WeeklySelectionStore(), scheduleStore: store)
        try coordinator.confirmSchedule(for: programme.id, weekdays: [2, 3, 4], at: now)
        let before = coordinator.activeSchedule
        store.failAfterSave = true
        XCTAssertThrowsError(try coordinator.confirmSchedule(for: programme.id, weekdays: [2, 5], replacing: before, at: now))
        XCTAssertEqual(coordinator.activeSchedule, before)
        XCTAssertFalse(coordinator.scheduleIsAvailable)
        XCTAssertEqual(store.stored?.weekdays, [2, 5])
        store.failAfterSave = false
        store.failRead = false
        XCTAssertTrue(coordinator.reloadSchedule(at: now))
        XCTAssertEqual(coordinator.activeSchedule, store.stored)
        XCTAssertThrowsError(try coordinator.confirmSchedule(for: programme.id, weekdays: [2, 5], replacing: before, at: now))
    }

    func testRealUserDefaultsAcceptedRhythmSurvivesRelaunchWithoutAdvancingSession() throws {
        let name = "01.weekly-planning." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsWorkoutProgrammeScheduleStore(defaults: defaults, key: "schedule")
        let selection = UserDefaultsWorkoutProgrammeSelectionStore(defaults: defaults, key: "selection")
        let coordinator = WorkoutProgrammeCoordinator(selectionStore: selection, scheduleStore: store)
        try coordinator.confirmSchedule(for: programme.id, weekdays: [2, 3, 4], at: now)
        let source = try context(schedule: XCTUnwrap(coordinator.activeSchedule))
        let offered = try planner.proposal(change: .fewerDays, availability: availability([2, 3, 4]), context: source, at: now, calendar: calendar)
        XCTAssertEqual(try store.load(), source.schedule) // Displaying a proposal has no write.
        let checked = try planner.revalidated(offered, context: source, at: now, calendar: calendar)
        try coordinator.confirmSchedule(for: programme.id, weekdays: checked.proposedWeekdays, replacing: checked.originalSchedule, at: now)
        let restored = WorkoutProgrammeCoordinator(selectionStore: selection, scheduleStore: store)
        XCTAssertEqual(restored.activeSchedule?.weekdays, checked.proposedWeekdays.sorted())
        XCTAssertEqual(restored.selectedProgrammeID, programme.id)
        XCTAssertEqual(restored.startSelectedProgramme()?.title, programme.sessions[0].title)
        XCTAssertEqual(restored.programmes.first(where: { $0.id == programme.id })?.sessions, programme.sessions)
    }

    func testAppointmentsAreBoundForAcceptanceAndNeverMovedByProposal() throws {
        var appointment = WorkoutAppointment(reference: .programme(programme.id, sessionID: programme.sessions[0].id),
            title: "My appointment", startsAt: now.addingTimeInterval(3_600), timeZoneIdentifier: calendar.timeZone.identifier)
        let original = appointment
        let source = try context(appointments: [appointment])
        let offered = try planner.proposal(change: .fewerDays, availability: availability([2, 3, 4]), context: source, at: now, calendar: calendar)
        XCTAssertEqual(offered.appointments, [original])
        XCTAssertEqual(source.appointments, [original])
        appointment.revision += 1
        appointment.startsAt = appointment.startsAt.addingTimeInterval(3_600)
        XCTAssertThrowsError(try planner.revalidated(offered, context: try context(appointments: [appointment]), at: now, calendar: calendar))
        XCTAssertEqual(original.startsAt, now.addingTimeInterval(3_600))
    }

    func testActualFuellingConcernQualifiesButChangedMealsInvalidateAcceptance() throws {
        let today = calendar.startOfDay(for: now)
        let days = [-1, -2].map { calendar.date(byAdding: .day, value: $0, to: today)! }
        let meals = days.map { NutritionEntry(id: UUID(), title: "Meal", calories: 900,
            proteinGrams: nil, carbohydrateGrams: nil, fatGrams: nil, loggedAt: $0.addingTimeInterval(3_600)) }
        let work = ExercisePlan(exerciseID: ExerciseIDs.gobletSquat, name: "Squat", targetLoad: Load(10),
            targetReps: RepRange(8, 12), plannedSetCount: 1, restSeconds: 120, previousPerformance: [])
        let histories = days.map { day in
            WorkoutHistoryEntry(session: WorkoutSession(title: "Training", exercises: [WorkoutExercise(plan: work,
                completedSets: [CompletedSet(load: Load(10), reps: 8, completedAt: day.addingTimeInterval(3_600))])],
                completedAt: day.addingTimeInterval(3_600)))
        }
        let reviews = try days.map { day in
            NutritionDayReview(id: UUID(), day: day, timeZoneID: calendar.timeZone.identifier, reviewedAt: now,
                coverage: .complete, mealFingerprint: try XCTUnwrap(NutritionDayReview.fingerprint(entries: meals, on: day, calendar: calendar)),
                reviewedFoodGroups: nil, reportedCalorieGoal: 2_500,
                    energyTargetContext: .init(source: .selfChosen, intent: .performance))
        }
        let report = RecoveryCheckIn(id: UUID(), day: today, timeZoneID: calendar.timeZone.identifier,
            reportedAt: now, energy: .low, soreness: .none, sleepHours: nil,
            hasNewOrWorseningPain: false, feelsUnwell: false, feelsUnusuallyHungry: false, feelsThirsty: false)
        func evaluate(_ records: [NutritionEntry]) -> WellbeingAssessment {
            WellbeingRecommendationEngine().assess(WellbeingContext(asOf: now, calendar: calendar,
                strengthHistory: histories, outdoorHistory: [], recoveryCheckIns: [report], meals: records,
                nutritionReviews: reviews, chosenFoodGoal: nil, hydration: nil, healthSleep: nil,
                nutritionGuidance: .init(reportedAt: now, isAdult: true, needsTailoredNutrition: false,
                    hasFoodRestrictions: false, hasPrescribedFluidRestriction: false)))
        }
        let schedule = try WorkoutProgrammeSchedule(programme: programme, weekdays: [2, 3, 4], confirmedAt: now)
        let source = WeeklyTrainingContext(programme: programme, schedule: schedule, assessment: evaluate(meals),
            hasUnfinishedWorkout: false, appointments: [])
        let offered = try planner.proposal(change: .fewerDays, availability: availability([2, 3, 4]), context: source, at: now, calendar: calendar)
        XCTAssertEqual(offered.concerns.map(\.kind), [.fuelling])
        let extra = NutritionEntry(id: UUID(), title: "Later meal", calories: 900, proteinGrams: nil,
            carbohydrateGrams: nil, fatGrams: nil, loggedAt: days[0].addingTimeInterval(7_200))
        let changed = WeeklyTrainingContext(programme: programme, schedule: schedule, assessment: evaluate(meals + [extra]),
            hasUnfinishedWorkout: false, appointments: [])
        XCTAssertThrowsError(try planner.revalidated(offered, context: changed, at: now, calendar: calendar)) {
            XCTAssertEqual($0 as? WeeklyTrainingPlanningError, .noConcern)
        }
    }

    func testMissingCurrentReportAndSupersededOrExpiredAssessmentRejects() throws {
        let original = try context()
        let inputs = [WellbeingAssessment(recommendations: original.assessment.recommendations,
                recordedTrainingDays: 0, reviewedNutritionDays: 0, hasCurrentRecoveryReport: false,
                hasConflictingSleep: false, evaluatedAt: now, timeZoneID: calendar.timeZone.identifier),
            WellbeingAssessment(recommendations: original.assessment.recommendations.map {
                .init(kind: $0.kind, demand: $0.demand, evidence: $0.evidence, policyVersion: "wellbeing-v0", sourceReferences: $0.sourceReferences)
            }, recordedTrainingDays: 0, reviewedNutritionDays: 0, hasCurrentRecoveryReport: true,
                hasConflictingSleep: false, evaluatedAt: now, timeZoneID: calendar.timeZone.identifier),
            WellbeingAssessment(recommendations: original.assessment.recommendations,
                recordedTrainingDays: 0, reviewedNutritionDays: 0, hasCurrentRecoveryReport: true,
                hasConflictingSleep: false, evaluatedAt: now.addingTimeInterval(-601), timeZoneID: calendar.timeZone.identifier)]
        for input in inputs {
            let unavailable = WeeklyTrainingContext(programme: programme, schedule: original.schedule,
                assessment: input, hasUnfinishedWorkout: false, appointments: [])
            XCTAssertThrowsError(try planner.proposal(change: .fewerDays, availability: availability([2, 3, 4]), context: unavailable, at: now, calendar: calendar)) {
                XCTAssertEqual($0 as? WeeklyTrainingPlanningError, .unavailable)
            }
        }
    }

    private func availability(_ days: Set<Int>, at stamp: Date? = nil) -> ReportedTrainingWeekdays {
        .init(weekdays: days, confirmedAt: stamp ?? now, timeZoneID: calendar.timeZone.identifier)
    }

    private func context(days: Set<Int> = [2, 3, 4], active: Bool = false, pain: Bool = false,
                         soreness: RecoverySoreness = .severe, energy: RecoveryEnergy = .usual,
                         appointments: [WorkoutAppointment] = [], at stamp: Date? = nil,
                         schedule: WorkoutProgrammeSchedule? = nil) throws -> WeeklyTrainingContext {
        let stamp = stamp ?? now
        let report = RecoveryCheckIn(id: UUID(), day: calendar.startOfDay(for: stamp), timeZoneID: calendar.timeZone.identifier,
            reportedAt: stamp, energy: energy, soreness: soreness, sleepHours: nil,
            hasNewOrWorseningPain: pain, feelsUnwell: false, feelsUnusuallyHungry: false, feelsThirsty: false)
        let assessment = WellbeingRecommendationEngine().assess(WellbeingContext(asOf: stamp, calendar: calendar,
            strengthHistory: [], outdoorHistory: [], recoveryCheckIns: [report], meals: [], nutritionReviews: [],
            chosenFoodGoal: nil, hydration: nil, healthSleep: nil))
        return .init(programme: programme, schedule: try schedule ?? WorkoutProgrammeSchedule(programme: programme, weekdays: days, confirmedAt: stamp),
            assessment: assessment, hasUnfinishedWorkout: active, appointments: appointments)
    }
}

private final class WeeklyScheduleStore: WorkoutProgrammeSchedulePersisting {
    var stored: WorkoutProgrammeSchedule?
    var failRead = false
    var failAfterSave = false
    private(set) var writes = 0
    func load() throws -> WorkoutProgrammeSchedule? {
        if failRead { throw WorkoutProgrammeScheduleError.unavailable }
        return stored
    }
    func save(_ schedule: WorkoutProgrammeSchedule) throws {
        stored = schedule
        writes += 1
        if failAfterSave { failRead = true }
    }
}

private final class WeeklySelectionStore: WorkoutProgrammeSelectionPersisting {
    var selected: WorkoutProgrammeID?
    func loadSelectedID() -> WorkoutProgrammeID? { selected }
    func saveSelectedID(_ id: WorkoutProgrammeID) { selected = id }
}

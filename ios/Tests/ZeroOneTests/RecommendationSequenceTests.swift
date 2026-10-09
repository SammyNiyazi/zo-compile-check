import XCTest
@testable import ZeroOne

/// Sequences cross the actual revision, schedule, progression and session
/// boundaries. A displayed proposal is never a write permission.
@MainActor final class RecommendationSequenceTests: XCTestCase {
    func testAcceptedSetReductionRejectsAnOlderWeeklyOptionAndFreshReviewKeepsTheReduction() throws {
        let fixture = try RecommendationSequenceFixture()
        let weekly = try fixture.weeklyOffer()
        try fixture.easeSets()
        let reduced = try fixture.volume.effective(fixture.programme)
        XCTAssertEqual(reduced.exercisePlans.map(\.plannedSetCount), [1])
        XCTAssertThrowsError(try fixture.acceptWeekly(weekly)) {
            XCTAssertEqual($0 as? WeeklyTrainingPlanningError, .stale)
        }
        XCTAssertEqual(fixture.scheduleStore.writes, 0)
        let reopened = try fixture.weeklyOffer()
        try fixture.acceptWeekly(reopened)
        XCTAssertEqual(fixture.scheduleStore.writes, 1)
        XCTAssertEqual(fixture.coordinator.activeSchedule?.weekdays.count, 2)
        let relaunched = ProgrammeVolumeRepository(store: fixture.volumeStore)
        XCTAssertEqual(try relaunched.effective(fixture.programme), reduced)
        XCTAssertEqual(fixture.history.entries, [fixture.execution.entry])
    }

    func testAcceptedWeeklyRhythmRejectsOldVolumeExposureBeforeAnySetWrite() throws {
        let fixture = try RecommendationSequenceFixture()
        let volume = try fixture.volumeOffer(.ease)
        let weekly = try fixture.weeklyOffer()
        try fixture.acceptWeekly(weekly)
        XCTAssertThrowsError(try fixture.acceptVolume(volume)) {
            XCTAssertEqual($0 as? ProgrammeVolumeError, .stale)
        }
        XCTAssertEqual(fixture.volumeStore.writes, 0)
        XCTAssertTrue(fixture.volume.snapshot.revisions.isEmpty)
        let reopened = try fixture.volumeOffer(.ease)
        XCTAssertEqual(reopened.weeklyTrainingDays, 2)
        try fixture.acceptVolume(reopened)
        XCTAssertEqual(fixture.volumeStore.writes, 1)
        XCTAssertEqual(fixture.coordinator.activeSchedule?.weekdays, weekly.proposedWeekdays.sorted())
        XCTAssertEqual(fixture.history.entries, [fixture.execution.entry])
    }

    func testScheduleChangeWhileRestorationIsOpenKeepsAcceptedReducedSets() throws {
        let fixture = try RecommendationSequenceFixture()
        try fixture.easeSets()
        fixture.soreness = .none
        let restoration = try fixture.volumeOffer(.restore)
        fixture.soreness = .severe
        try fixture.acceptWeekly(fixture.weeklyOffer())
        fixture.soreness = .none
        XCTAssertThrowsError(try fixture.acceptVolume(restoration)) {
            XCTAssertEqual($0 as? ProgrammeVolumeError, .stale)
        }
        XCTAssertEqual(fixture.volumeStore.writes, 1)
        XCTAssertEqual(try fixture.volume.effective(fixture.programme).exercisePlans.map(\.plannedSetCount), [1])
        let reopened = try fixture.volumeOffer(.restore)
        XCTAssertEqual(reopened.weeklyTrainingDays, 2)
        try fixture.acceptVolume(reopened)
        XCTAssertEqual(fixture.volumeStore.writes, 2)
        XCTAssertTrue(fixture.volume.snapshot.revisions.isEmpty)
        XCTAssertEqual(fixture.history.entries, [fixture.execution.entry])
    }

    func testAnotherAcceptedReductionCannotBeOverwrittenUsingACapturedEmptyRevision() throws {
        let fixture = try RecommendationSequenceFixture()
        let captured = try fixture.volumeContext()
        let first = try ProgrammeVolumePlanner().proposal(change: .ease, context: captured,
            at: fixture.now, calendar: fixture.calendar)
        let second = try ProgrammeVolumePlanner().proposal(change: .ease, context: captured,
            at: fixture.now, calendar: fixture.calendar)
        try fixture.acceptVolume(first)
        let acknowledged = fixture.volumeStore.value
        XCTAssertThrowsError(try fixture.volume.accept(second, context: captured,
            at: fixture.now, calendar: fixture.calendar)) {
            XCTAssertEqual($0 as? ProgrammeVolumeError, .stale)
        }
        XCTAssertEqual(fixture.volumeStore.writes, 1)
        XCTAssertEqual(fixture.volumeStore.value, acknowledged)
        XCTAssertEqual(ProgrammeVolumeRepository(store: fixture.volumeStore).snapshot, acknowledged)
    }

    func testReturningToTheSameWeekdaysDoesNotReviveAnOlderScheduleProposal() throws {
        let fixture = try RecommendationSequenceFixture()
        let offered = try fixture.weeklyOffer()
        let original = try XCTUnwrap(fixture.coordinator.activeSchedule)
        fixture.now = fixture.now.addingTimeInterval(1)
        try fixture.acceptWeekly(offered)
        let reduced = try XCTUnwrap(fixture.coordinator.activeSchedule)
        fixture.now = fixture.now.addingTimeInterval(1)
        try fixture.coordinator.confirmSchedule(for: fixture.programme.id, weekdays: Set(original.weekdays),
            replacing: reduced, at: fixture.now)
        XCTAssertEqual(fixture.coordinator.activeSchedule?.weekdays, original.weekdays)
        XCTAssertNotEqual(fixture.coordinator.activeSchedule, original)
        XCTAssertThrowsError(try fixture.acceptWeekly(offered)) {
            XCTAssertEqual($0 as? WeeklyTrainingPlanningError, .stale)
        }
        XCTAssertEqual(fixture.scheduleStore.writes, 2)
        XCTAssertEqual(fixture.history.entries, [fixture.execution.entry])
    }

    func testFutureSetReductionInvalidatesEarnedLoadEvenAfterRecoveryImproves() throws {
        let fixture = try RecommendationSequenceFixture()
        fixture.soreness = .none
        XCTAssertTrue(fixture.chooseIncrease())
        let acknowledged = fixture.choiceStore.value
        fixture.soreness = .severe
        try fixture.easeSets()
        fixture.soreness = .none
        XCTAssertFalse(fixture.assessment().holdsAutomaticProgression,
            "The changed prescription, rather than a remaining recovery hold, invalidates the old offer")
        XCTAssertFalse(fixture.authority.validate(fixture.upgrade, sourceSessionID: fixture.execution.entry.id,
            at: fixture.now))
        XCTAssertFalse(fixture.chooseIncrease())
        XCTAssertEqual(fixture.choiceStore.writes, 1)
        XCTAssertEqual(fixture.choiceStore.value, acknowledged)
        let session = try fixture.futureSession()
        XCTAssertEqual(session.exercises.map { $0.plan.plannedSetCount }, [1])
        XCTAssertEqual(session.exercises.map { $0.plan.targetLoad }, [Load(40)])
        XCTAssertEqual(fixture.history.entries, [fixture.execution.entry])
    }

    func testExplicitRestorationRequalifiesTheExactPriorChoiceWithoutChangingPerformedHistory() throws {
        let fixture = try RecommendationSequenceFixture()
        fixture.soreness = .none
        XCTAssertTrue(fixture.chooseIncrease())
        XCTAssertEqual(try fixture.futureSession().exercises.first?.plan.targetLoad, Load(42.5))
        fixture.soreness = .severe
        try fixture.easeSets()
        fixture.soreness = .none
        XCTAssertEqual(try fixture.futureSession().exercises.first?.plan.targetLoad, Load(40))
        try fixture.acceptVolume(fixture.volumeOffer(.restore))
        let restored = try fixture.futureSession()
        XCTAssertEqual(restored.exercises.map { $0.plan.plannedSetCount }, [2])
        XCTAssertEqual(restored.exercises.first?.plan.targetLoad, Load(42.5))
        XCTAssertEqual(fixture.choiceStore.writes, 1, "No displayed/requalified option creates a new acceptance")
        XCTAssertEqual(fixture.history.entries, [fixture.execution.entry])
        XCTAssertEqual(fixture.execution.entry.exercises?.first?.completedSets.map(\.load), [Load(40), Load(40)])
    }

    func testStartingAnActualSessionRejectsOpenFutureProposalsAndPreservesManualInputs() throws {
        let fixture = try RecommendationSequenceFixture()
        let volume = try fixture.volumeOffer(.ease)
        let weekly = try fixture.weeklyOffer()
        let active = try XCTUnwrap(fixture.coordinator.startSelectedProgramme(
            effectiveProgramme: fixture.programme, previousHistory: fixture.history.entries,
            progressionAllowed: false, asOf: fixture.now))
        let model = WorkoutViewModel(session: active)
        model.selectLoad(Load(41))
        let before = model.session
        let input = model.substitutionInput
        XCTAssertThrowsError(try fixture.acceptVolume(volume)) {
            XCTAssertEqual($0 as? ProgrammeVolumeError, .active)
        }
        XCTAssertThrowsError(try fixture.acceptWeekly(weekly)) {
            XCTAssertEqual($0 as? WeeklyTrainingPlanningError, .activeWorkout)
        }
        XCTAssertEqual(fixture.volumeStore.writes, 0)
        XCTAssertEqual(fixture.scheduleStore.writes, 0)
        XCTAssertEqual(model.session, before)
        XCTAssertEqual(model.substitutionInput, input)
        XCTAssertEqual(fixture.history.entries, [fixture.execution.entry])
    }
}

@MainActor private final class RecommendationSequenceFixture {
    var now = ISO8601DateFormatter().date(from: "2026-10-03T15:00:00Z")!
    var soreness: RecoverySoreness = .severe
    let calendar: Calendar
    let execution: WorkoutProgressionTestFixture
    let upgrade: WorkoutCompletionUpgrade
    let programme: WorkoutProgramme
    let coordinator: WorkoutProgrammeCoordinator
    let scheduleStore: RecommendationSequenceScheduleStore
    let volumeStore = RecommendationSequenceVolumeStore()
    let volume: ProgrammeVolumeRepository
    let history: WorkoutHistoryRepository
    let authority: WorkoutProgressionAuthority
    let choiceStore = RecommendationSequenceChoiceStore()
    let choices: WorkoutLoadChoiceRepository

    init() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        execution = try WorkoutProgressionTestFixture(at: now)
        upgrade = try XCTUnwrap(execution.upgrade)
        let workingPlan = execution.plan
        let template = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneBuild))
        let selectedProgramme = WorkoutProgramme(id: template.id, title: template.title, summary: template.summary,
            durationMinutes: template.durationMinutes, equipmentContext: template.equipmentContext,
            experienceBand: template.experienceBand, goalSupport: template.goalSupport, schedule: template.schedule,
            durationWeeks: template.durationWeeks, rules: template.rules, evidenceReferenceKeys: template.evidenceReferenceKeys,
            sessions: (0 ..< 3).map { .init(id: "replay-\($0)", title: "Replay \($0)", exercisePlans: [workingPlan]) })
        programme = selectedProgramme
        scheduleStore = try RecommendationSequenceScheduleStore(.init(programme: programme, weekdays: [2, 3, 4], confirmedAt: now))
        let presets = WorkoutProgrammeLibrary.all.map { $0.id == selectedProgramme.id ? selectedProgramme : $0 }
        coordinator = WorkoutProgrammeCoordinator(programmes: presets,
            selectionStore: RecommendationSequenceSelectionStore(programme.id), scheduleStore: scheduleStore)
        coordinator.showDetail(for: programme.id)
        volume = ProgrammeVolumeRepository(store: volumeStore)
        history = WorkoutHistoryRepository(store: ProgressionHistoryTestStore([execution.entry]))
        authority = WorkoutProgressionAuthority(history: history,
            reviews: WorkoutProgressionReviewRepository(store: ProgressionReviewTestStore([execution.review])))
        choices = WorkoutLoadChoiceRepository(store: choiceStore)
        authority.install(currentPlans: { [unowned self] _ in
            (try? self.volume.effective(self.programme))?.exercisePlans ?? []
        }, refreshCurrentPlans: { [unowned self] _ in self.volume.reload(at: self.now) },
            increaseAllowed: { [unowned self] in !self.assessment().holdsAutomaticProgression })
        choices.setProgressionValidator { [unowned self] candidate, source in
            self.authority.validate(candidate, sourceSessionID: source, requireIncrease: false, at: self.now)
        }
        choices.setProgressionPolicy { [unowned self] in !self.assessment().holdsAutomaticProgression }
    }

    func recovery() -> RecoveryCheckIn {
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
            day: calendar.startOfDay(for: now), timeZoneID: calendar.timeZone.identifier, reportedAt: now,
            energy: .usual, soreness: soreness, sleepHours: 7, hasNewOrWorseningPain: false,
            feelsUnwell: false, feelsUnusuallyHungry: false, feelsThirsty: false)
    }
    func assessment() -> WellbeingAssessment {
        WellbeingRecommendationEngine().assess(.init(asOf: now, calendar: calendar,
            strengthHistory: history.entries, outdoorHistory: [], recoveryCheckIns: [recovery()], meals: [],
            nutritionReviews: [], chosenFoodGoal: nil, hydration: nil, healthSleep: nil))
    }
    func volumeContext() throws -> ProgrammeVolumeContext {
        guard volume.reload(at: now) else { throw ProgrammeVolumeError.unavailable }
        return .init(programme: programme, revision: try volume.revision(for: programme.id),
            calendarEvidence: coordinator.programmeVolumeCalendarEvidence(at: now), assessment: assessment(),
            recovery: recovery(), hasUnfinishedWorkout: coordinator.route.isActive)
    }
    func volumeOffer(_ change: ProgrammeVolumeChange) throws -> ProgrammeVolumeProposal {
        try ProgrammeVolumePlanner().proposal(change: change, context: volumeContext(), at: now, calendar: calendar)
    }
    func acceptVolume(_ presented: ProgrammeVolumeProposal) throws {
        try volume.accept(presented, context: volumeContext(), at: now, calendar: calendar)
    }
    func easeSets() throws { try acceptVolume(volumeOffer(.ease)) }
    func weeklyContext() throws -> WeeklyTrainingContext {
        guard coordinator.reloadSchedule(at: now), let schedule = coordinator.activeSchedule,
              volume.reload(at: now) else { throw WeeklyTrainingPlanningError.unavailable }
        return .init(programme: try volume.effective(programme), schedule: schedule, assessment: assessment(),
            hasUnfinishedWorkout: coordinator.route.isActive, appointments: [])
    }
    func weeklyOffer() throws -> WeeklyTrainingProposal {
        try WeeklyTrainingPlanner().proposal(change: .fewerDays,
            availability: .init(weekdays: [2, 3, 4], confirmedAt: now, timeZoneID: calendar.timeZone.identifier),
            context: weeklyContext(), at: now, calendar: calendar)
    }
    func acceptWeekly(_ presented: WeeklyTrainingProposal) throws {
        let fresh = try WeeklyTrainingPlanner().revalidated(presented, context: weeklyContext(), at: now, calendar: calendar)
        try coordinator.confirmSchedule(for: programme.id, weekdays: fresh.proposedWeekdays,
            replacing: fresh.originalSchedule, at: now)
    }
    func chooseIncrease() -> Bool { choices.choose(.tryNext, for: upgrade, sourceSessionID: execution.entry.id) }
    func futureSession() throws -> WorkoutSession {
        try volume.effective(programme).makeSession(previousHistory: history.entries, loadChoices: choices.choices,
            progressionAllowed: !assessment().holdsAutomaticProgression,
            progressionReviews: [execution.review], asOf: now)
    }
}

private final class RecommendationSequenceVolumeStore: ProgrammeVolumePersisting {
    var value = ProgrammeVolumeSnapshot.empty
    private(set) var writes = 0
    func load() throws -> ProgrammeVolumeSnapshot { value }
    func save(_ value: ProgrammeVolumeSnapshot) throws { self.value = value; writes += 1 }
}
private final class RecommendationSequenceScheduleStore: WorkoutProgrammeSchedulePersisting {
    var value: WorkoutProgrammeSchedule
    private(set) var writes = 0
    init(_ value: WorkoutProgrammeSchedule) { self.value = value }
    func load() throws -> WorkoutProgrammeSchedule? { value }
    func save(_ value: WorkoutProgrammeSchedule) throws { self.value = value; writes += 1 }
}
private final class RecommendationSequenceSelectionStore: WorkoutProgrammeSelectionPersisting {
    var value: WorkoutProgrammeID
    init(_ value: WorkoutProgrammeID) { self.value = value }
    func loadSelectedID() -> WorkoutProgrammeID? { value }
    func saveSelectedID(_ value: WorkoutProgrammeID) { self.value = value }
}
private final class RecommendationSequenceChoiceStore: WorkoutLoadChoicePersisting {
    var value: [WorkoutLoadChoice] = []
    private(set) var writes = 0
    func load() throws -> [WorkoutLoadChoice] { value }
    func save(_ value: [WorkoutLoadChoice]) throws { self.value = value; writes += 1 }
}

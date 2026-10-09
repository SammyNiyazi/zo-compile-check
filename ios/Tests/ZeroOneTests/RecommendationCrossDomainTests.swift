import XCTest
@testable import ZeroOne

/// Replays actual source/authority/repository boundaries. A changed Boolean
/// adapter alone cannot prove that missing source data keeps an increase held.
@MainActor final class RecommendationCrossDomainTests: XCTestCase {
    func testVerifiedAbsentOutdoorHistoryAllowsAnEarnedChoiceWithoutCreatingDirectories() async throws {
        let fixture = try CrossDomainFixture()
        defer { fixture.cleanUp() }
        await fixture.outdoor.refresh(using: fixture.outdoorRepository)
        XCTAssertEqual(fixture.outdoor.records, [])
        XCTAssertTrue(fixture.permitsIncrease())
        XCTAssertTrue(fixture.chooseIncrease())
        XCTAssertEqual(fixture.choiceStore.writes, 1)
        XCTAssertEqual(WorkoutLoadChoiceRepository(store: fixture.choiceStore).choices, fixture.choices.choices)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        XCTAssertEqual(fixture.history.entries, [fixture.execution.entry])
    }

    func testNewRunsAfterAnOfferRejectAnIncreaseBeforeRefreshAndRetainTheRecoveryHoldAfterRefresh() async throws {
        let fixture = try CrossDomainFixture(energy: .low)
        defer { fixture.cleanUp() }
        await fixture.outdoor.refresh(using: fixture.outdoorRepository)
        XCTAssertTrue(fixture.permitsIncrease(), "An isolated fatigue report is not a diagnosis")
        XCTAssertTrue(fixture.authority.validate(plan: fixture.execution.plan, opportunity: fixture.upgrade.opportunity,
            at: fixture.now))
        try fixture.writeRuns([-1, -2])
        XCTAssertFalse(fixture.chooseIncrease(), "New persisted activity cannot be absent from write authority")
        XCTAssertNil(fixture.outdoor.records)
        XCTAssertEqual(fixture.choiceStore.writes, 0)
        await fixture.outdoor.refresh(using: fixture.outdoorRepository)
        let assessment = fixture.assessment()
        XCTAssertEqual(assessment.recordedTrainingDays, 3)
        XCTAssertTrue(assessment.recommendations.contains { $0.kind == .recovery && $0.demand == .easeTraining })
        XCTAssertFalse(fixture.chooseIncrease())
        XCTAssertEqual(fixture.choiceStore.writes, 0)
        XCTAssertTrue(fixture.choices.choose(.repeatPrevious, for: fixture.upgrade,
            sourceSessionID: fixture.execution.entry.id), "Repeating still needs exact history/review evidence")
        XCTAssertEqual(fixture.history.entries, [fixture.execution.entry])
    }

    func testAReadInFlightCannotReleaseAnIncreaseOrOverwriteAManualDraft() async throws {
        let fixture = try CrossDomainFixture()
        defer { fixture.cleanUp() }
        await fixture.outdoor.refresh(using: fixture.outdoorRepository)
        XCTAssertTrue(fixture.permitsIncrease())
        let observation = try await fixture.outdoorRepository.loadRecommendationObservation()
        let loader = CrossDomainControlledOutdoorLoader()
        let task = Task { await fixture.outdoor.refresh(using: loader) }
        await loader.waitUntilRequested()
        XCTAssertNil(fixture.outdoor.records)
        XCTAssertFalse(fixture.chooseIncrease())
        let model = WorkoutViewModel(session: .init(title: "Next", exercises: [WorkoutExercise(plan: fixture.execution.plan)]),
            progressionValidator: { plan, opportunity in
                fixture.authority.validate(plan: plan, opportunity: opportunity, at: fixture.now)
            })
        model.selectLoad(Load(41))
        model.selectProgressionOffer(.tryNext, opportunity: fixture.upgrade.opportunity)
        XCTAssertEqual(model.enteredLoadValue, 41)
        XCTAssertTrue(model.progressionOfferSelections.isEmpty)
        XCTAssertEqual(fixture.choiceStore.writes, 0)
        await loader.finish(observation)
        await task.value
        XCTAssertTrue(fixture.permitsIncrease())
    }

    func testSupersededAsyncObservationCannotReplaceNewerTrainingEvidence() async throws {
        let fixture = try CrossDomainFixture(energy: .low)
        defer { fixture.cleanUp() }
        let old = try await fixture.outdoorRepository.loadRecommendationObservation()
        let loader = CrossDomainControlledOutdoorLoader()
        let task = Task { await fixture.outdoor.refresh(using: loader) }
        await loader.waitUntilRequested()
        try fixture.writeRuns([-1, -2])
        await fixture.outdoor.refresh(using: fixture.outdoorRepository)
        let current = fixture.outdoor.records
        await loader.finish(old)
        await task.value
        XCTAssertEqual(fixture.outdoor.records, current)
        XCTAssertEqual(fixture.assessment().recordedTrainingDays, 3)
        XCTAssertFalse(fixture.chooseIncrease())
        XCTAssertEqual(fixture.choiceStore.writes, 0)
    }

    func testFailedRefreshAndMalformedFileCannotBecomeVerifiedEmptyHistory() async throws {
        let fixture = try CrossDomainFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRuns([-1])
        await fixture.outdoor.refresh(using: fixture.outdoorRepository)
        XCTAssertTrue(fixture.permitsIncrease())
        let raw = Data("{\"future\":true}".utf8)
        try raw.write(to: fixture.historyURL, options: .atomic)
        XCTAssertFalse(fixture.chooseIncrease())
        await fixture.outdoor.refresh(using: fixture.outdoorRepository)
        XCTAssertNil(fixture.outdoor.records)
        XCTAssertFalse(fixture.chooseIncrease())
        XCTAssertEqual(try Data(contentsOf: fixture.historyURL), raw)
        XCTAssertEqual(fixture.choiceStore.writes, 0)
        try fixture.writeRuns([])
        XCTAssertFalse(fixture.permitsIncrease(), "A repaired file still needs an acknowledged observation")
        await fixture.outdoor.refresh(using: fixture.outdoorRepository)
        XCTAssertTrue(fixture.permitsIncrease())
    }

    func testDeletedFileRequiresFreshAbsenceObservationBeforeAnIncrease() async throws {
        let fixture = try CrossDomainFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRuns([-1])
        await fixture.outdoor.refresh(using: fixture.outdoorRepository)
        XCTAssertTrue(fixture.permitsIncrease())
        try FileManager.default.removeItem(at: fixture.historyURL)
        XCTAssertFalse(fixture.chooseIncrease())
        XCTAssertEqual(fixture.choiceStore.writes, 0)
        await fixture.outdoor.refresh(using: fixture.outdoorRepository)
        XCTAssertEqual(fixture.outdoor.records, [])
        XCTAssertTrue(fixture.permitsIncrease())
    }

    func testPainThenUnreadableRecoveryBecomesRecordReviewInsteadOfTrainingPressure() async throws {
        let fixture = try CrossDomainFixture(pain: true)
        defer { fixture.cleanUp() }
        await fixture.outdoor.refresh(using: fixture.outdoorRepository)
        let original = fixture.assessment()
        XCTAssertEqual(original.recommendations.first?.kind, .symptoms)
        XCTAssertFalse(fixture.chooseIncrease())
        let saved = fixture.recoveryStore.value
        fixture.recoveryStore.failRead = true
        fixture.recovery.reload()
        XCTAssertFalse(fixture.recovery.isAvailable)
        let unreadable = fixture.assessment()
        XCTAssertEqual(unreadable.unavailableSources, [.recovery])
        XCTAssertTrue(unreadable.holdsAutomaticProgression)
        XCTAssertFalse(unreadable.recommendations.contains { $0.kind == .symptoms },
            "An old report is not a newly verified symptom")
        for active in [false, true] {
            let response = ContextualAssistantPolicy().currentStateResponse(
                for: fixture.assistantContext(unreadable, active: active), at: fixture.now, calendar: fixture.calendar)
            XCTAssertEqual(response.title, "Check your records")
            XCTAssertEqual(response.action, .reviewWellbeing)
        }
        let explicitResume = ContextualAssistantPolicy().response(for: .continueWorkout,
            context: fixture.assistantContext(unreadable, active: true))
        XCTAssertEqual(explicitResume.action, .continueWorkout, "Manual execution stays available")
        XCTAssertEqual(fixture.recoveryStore.value, saved)
        XCTAssertEqual(fixture.choiceStore.writes, 0)
    }

    func testUnavailableSourceSuppressesPromptAndNotificationWithoutInventingAConcern() async throws {
        let fixture = try CrossDomainFixture()
        defer { fixture.cleanUp() }
        await fixture.outdoor.refresh(using: fixture.outdoorRepository)
        fixture.foodStore.isAvailable = false
        XCTAssertFalse(fixture.permitsIncrease())
        let unreadable = fixture.assessment()
        XCTAssertEqual(unreadable.unavailableSources, [.foodLog])
        XCTAssertTrue(unreadable.holdsAutomaticProgression)
        XCTAssertFalse(unreadable.recommendations.contains { $0.kind == .fuelling })
        XCTAssertEqual(RecommendationArbiter().focus(at: fixture.now, calendar: fixture.calendar,
            workout: .ready, wellbeing: unreadable), .sourceUnavailable)
        XCTAssertTrue(LocalSmartPromptService().prompts(for: .init(date: fixture.now,
            workoutStatus: .ready, wellbeing: unreadable)).isEmpty)
        XCTAssertNil(LocalZeroOneNotificationSelector().bestNotification(for: .init(date: fixture.now,
            workoutStatus: .ready, wellbeing: unreadable)))
        fixture.foodStore.isAvailable = true
        XCTAssertTrue(fixture.permitsIncrease())
    }

    func testKnownCurrentPainRetainsPriorityWhenAnotherSourceIsUnavailable() {
        let fixture = try? CrossDomainFixture(pain: true)
        guard let fixture else { return XCTFail("Fixture failed") }
        defer { fixture.cleanUp() }
        let assessment = fixture.assessment() // No outdoor observation yet.
        XCTAssertEqual(assessment.unavailableSources, [.outdoorHistory])
        XCTAssertEqual(RecommendationArbiter().focus(at: fixture.now, calendar: fixture.calendar,
            workout: .active, wellbeing: assessment), .wellbeing(assessment.recommendations[0]))
        XCTAssertEqual(ContextualAssistantPolicy().currentStateResponse(
            for: fixture.assistantContext(assessment, active: true), at: fixture.now, calendar: fixture.calendar).action, .reviewWellbeing)
    }
}

@MainActor private final class CrossDomainFixture {
    let now = ISO8601DateFormatter().date(from: "2026-10-03T15:00:00Z")!
    let calendar: Calendar
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("01-cross-domain-" + UUID().uuidString)
    var historyURL: URL { directory.appendingPathComponent("outdoor-history.json") }
    let outdoorRepository: OutdoorActivityRepository
    let outdoor = WellbeingOutdoorEvidence()
    let execution: WorkoutProgressionTestFixture
    let upgrade: WorkoutCompletionUpgrade
    let history: WorkoutHistoryRepository
    let recoveryStore: CrossDomainRecoveryStore
    let recovery: WellbeingCheckInRepository
    let foodStore = CrossDomainFoodStore()
    let nutrition: NutritionRepository
    let goals = DailyGoalsRepository(store: CrossDomainGoalsStore())
    let water: HydrationViewModel
    let health = HealthConnectionRepository(service: CrossDomainHealthService(), preferenceStore: CrossDomainHealthPreference())
    let authority: WorkoutProgressionAuthority
    let choiceStore = CrossDomainChoiceStore()
    let choices: WorkoutLoadChoiceRepository

    init(energy: RecoveryEnergy = .usual, pain: Bool = false) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        outdoorRepository = OutdoorActivityRepository(directory: directory)
        execution = try WorkoutProgressionTestFixture(at: now)
        upgrade = try XCTUnwrap(execution.upgrade)
        history = WorkoutHistoryRepository(store: ProgressionHistoryTestStore([execution.entry]))
        recoveryStore = CrossDomainRecoveryStore(.init(recovery: [.init(id: UUID(), day: calendar.startOfDay(for: now),
            timeZoneID: calendar.timeZone.identifier, reportedAt: now, energy: energy, soreness: .none, sleepHours: 7,
            hasNewOrWorseningPain: pain, feelsUnwell: false, feelsUnusuallyHungry: false, feelsThirsty: false)]))
        recovery = WellbeingCheckInRepository(store: recoveryStore)
        nutrition = NutritionRepository(store: foodStore, calendar: calendar)
        let clock = now
        water = HydrationViewModel(calendar: calendar, currentDate: { clock })
        authority = WorkoutProgressionAuthority(history: history,
            reviews: WorkoutProgressionReviewRepository(store: ProgressionReviewTestStore([execution.review])))
        choices = WorkoutLoadChoiceRepository(store: choiceStore)
        authority.install(currentPlans: { [execution] _ in [execution.plan] }, refreshCurrentPlans: { _ in true },
            increaseAllowed: { [unowned self] in self.permitsIncrease() })
        choices.setProgressionValidator { [unowned self] upgrade, source in
            self.authority.validate(upgrade, sourceSessionID: source, requireIncrease: false, at: self.now)
        }
        choices.setProgressionPolicy { [unowned self] in self.permitsIncrease() }
    }

    func permitsIncrease() -> Bool {
        WellbeingAssessmentSource.permitsAutomaticProgression(history: history, recovery: recovery, nutrition: nutrition,
            goals: goals, water: water, health: health, outdoor: outdoor, outdoorRepository: outdoorRepository,
            at: now, calendar: calendar)
    }
    func assessment() -> WellbeingAssessment {
        WellbeingAssessmentSource.assess(history: history, recovery: recovery, nutrition: nutrition,
            goals: goals, water: water, health: health, outdoor: outdoor, at: now, calendar: calendar)
    }
    func chooseIncrease() -> Bool { choices.choose(.tryNext, for: upgrade, sourceSessionID: execution.entry.id) }
    func writeRuns(_ offsets: [Int]) throws {
        let records = offsets.map { offset in
            let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!.addingTimeInterval(3_600)
            let end = start.addingTimeInterval(1_200)
            return OutdoorActivityRecord(checkpoint: .init(kind: .run, trackingMode: .timerOnly,
                startedAt: start, checkpointedAt: end, confirmedActiveSeconds: 1_200,
                phase: .readyToSave, finishedAt: end), finishedAt: end)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: historyURL, options: .atomic)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    func assistantContext(_ assessment: WellbeingAssessment, active: Bool) -> AssistantContext {
        .init(profile: .init(trainingGoal: nil, trainingExperience: nil, weeklyAvailability: nil,
                equipmentAccess: nil, trainingConstraint: nil),
            workout: active ? .inProgress(title: "Next", canAdaptToThirtyMinutes: true) : .none,
            today: .ready(workoutTitle: "Next"),
            hydration: .init(consumedMilliliters: 0, goalMilliliters: 2_500, isAvailable: true),
            nutrition: .init(entryCountToday: 0, isAvailable: nutrition.availability == .available),
            health: .init(isConnected: false, hasLocalContext: false), wellbeing: assessment)
    }
}

private final class CrossDomainRecoveryStore: WellbeingCheckInPersisting {
    var value: WellbeingCheckInSnapshot
    var failRead = false
    init(_ value: WellbeingCheckInSnapshot) { self.value = value }
    func load() throws -> WellbeingCheckInSnapshot {
        if failRead { throw WellbeingCheckInError.unavailable }; return value
    }
    func save(_ value: WellbeingCheckInSnapshot) throws { self.value = value }
}
private final class CrossDomainFoodStore: NutritionPersisting {
    var isAvailable = true
    var entries: [NutritionEntry] = []
    func load() -> [NutritionEntry] { entries }
    func save(_ entries: [NutritionEntry]) { self.entries = entries }
}
private struct CrossDomainGoalsStore: DailyGoalsPersisting {
    func load() throws -> DailyGoals { .empty }
    func save(_ value: DailyGoals) throws {}
}
@MainActor private struct CrossDomainHealthService: HealthKitServicing {
    var isHealthDataAvailable: Bool { false }
    func requestAuthorization(for scope: HealthAuthorizationScope) async -> HealthAuthorizationOutcome { .unavailable }
    func readContext(at date: Date) async throws -> HealthContext { .empty(refreshedAt: date) }
}
private struct CrossDomainHealthPreference: HealthConnectionPreferencePersisting {
    var hasCompletedHealthSetup: Bool { false }
    func setHasCompletedHealthSetup(_ value: Bool) {}
}
private final class CrossDomainChoiceStore: WorkoutLoadChoicePersisting {
    var choices: [WorkoutLoadChoice] = []
    private(set) var writes = 0
    func load() throws -> [WorkoutLoadChoice] { choices }
    func save(_ choices: [WorkoutLoadChoice]) throws { self.choices = choices; writes += 1 }
}
private actor CrossDomainControlledOutdoorLoader: OutdoorRecommendationLoading {
    private var continuation: CheckedContinuation<OutdoorRecommendationObservation, Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    func loadRecommendationObservation() async throws -> OutdoorRecommendationObservation {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            waiter?.resume(); waiter = nil
        }
    }
    func waitUntilRequested() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ observation: OutdoorRecommendationObservation) {
        continuation?.resume(returning: observation); continuation = nil
    }
}

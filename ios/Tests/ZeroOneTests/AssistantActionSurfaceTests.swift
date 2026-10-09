import XCTest
@testable import ZeroOne

@MainActor
final class AssistantActionSurfaceTests: XCTestCase {
    private let policy = AssistantActionPolicy()

    func testActionAvailabilityChangesWithWorkoutContext() {
        let inactive = AssistantActionContext(
            workout: .inactive,
            hydrationIsAvailable: true
        )
        let active = AssistantActionContext(
            workout: .activeEligible,
            hydrationIsAvailable: true
        )

        XCTAssertTrue(policy.options(for: inactive).contains { $0.id == .openWorkoutLibrary })
        XCTAssertFalse(policy.options(for: active).contains { $0.id == .openWorkoutLibrary })
        XCTAssertTrue(policy.options(for: active).contains { $0.id == .shortenWorkout })
    }

    func testEligibleWorkoutResolvesToExistingAdaptationProposal() {
        let context = AssistantActionContext(
            workout: .activeEligible,
            hydrationIsAvailable: true
        )

        let result = policy.resolution(for: .shortenWorkout, context: context)

        XCTAssertEqual(
            result,
            .proposeThirtyMinuteWorkout(
                AssistantActionFeedback(
                    message: "30-minute proposal ready to review.",
                    kind: .information
                )
            )
        )
    }

    func testInactiveWorkoutRoutesToLibraryWithExplicitFeedback() {
        let context = AssistantActionContext(
            workout: .inactive,
            hydrationIsAvailable: true
        )

        let result = policy.resolution(for: .shortenWorkout, context: context)

        guard case let .route(route, feedback) = result else {
            return XCTFail("Expected a Workout Library route.")
        }
        XCTAssertEqual(route, .workoutLibrary)
        XCTAssertEqual(feedback.kind, .information)
        XCTAssertFalse(feedback.message.isEmpty)
    }

    func testAddWaterResolutionMutatesSharedHydrationAndConfirms() {
        let context = AssistantActionContext(
            workout: .inactive,
            hydrationIsAvailable: true
        )
        let hydration = HydrationViewModel(
            state: HydrationState(currentMilliliters: 750, goalMilliliters: 2_500)
        )

        let result = policy.resolution(for: .addWater, context: context)

        guard case let .addWater(milliliters, feedback) = result else {
            return XCTFail("Expected a hydration mutation.")
        }
        hydration.addWater(milliliters: milliliters)
        XCTAssertEqual(hydration.state.currentMilliliters, 1_000)
        XCTAssertEqual(feedback.kind, .success)
        XCTAssertEqual(feedback.message, "+250 ml added to hydration.")
        XCTAssertEqual(
            feedback.accessibilityAnnouncement,
            "250 milliliters added to hydration."
        )
    }

    func testUnsupportedActiveStateReturnsUsefulCurrentWorkoutRoute() {
        let context = AssistantActionContext(
            workout: .activeIneligible("This workout has started."),
            hydrationIsAvailable: true
        )

        let result = policy.resolution(for: .shortenWorkout, context: context)

        guard case let .unsupported(feedback, route) = result else {
            return XCTFail("Expected an unsupported result.")
        }
        XCTAssertEqual(feedback.kind, .unavailable)
        XCTAssertEqual(route, .currentWorkout)
    }

    func testOpenNutritionRoutesDirectly() {
        let context = AssistantActionContext(
            workout: .inactive,
            hydrationIsAvailable: true
        )

        let result = policy.resolution(for: .openNutrition, context: context)

        guard case let .route(route, feedback) = result else {
            return XCTFail("Expected a nutrition route.")
        }
        XCTAssertEqual(route, .nutrition)
        XCTAssertEqual(feedback.message, "Nutrition is open.")
        XCTAssertNil(feedback.accessibilityAnnouncement)
    }

    func testTrainTodayRoutesToRecommendedWorkout() {
        let result = policy.resolution(
            for: .trainToday,
            context: AssistantActionContext(workout: .inactive, hydrationIsAvailable: true)
        )

        guard case let .route(route, _) = result else {
            return XCTFail("Expected the recommended workout route.")
        }
        XCTAssertEqual(route, .recommendedWorkout)
    }

    func testContinueWorkoutUsesCurrentActiveWorkoutOnly() {
        let active = policy.resolution(
            for: .continueWorkout,
            context: AssistantActionContext(workout: .activeEligible, hydrationIsAvailable: true)
        )
        let inactive = policy.resolution(
            for: .continueWorkout,
            context: AssistantActionContext(workout: .inactive, hydrationIsAvailable: true)
        )

        guard case let .route(activeRoute, _) = active,
              case let .route(inactiveRoute, _) = inactive else {
            return XCTFail("Expected deterministic routes.")
        }
        XCTAssertEqual(activeRoute, .currentWorkout)
        XCTAssertEqual(inactiveRoute, .workoutLibrary)
    }
}

@MainActor
final class MainActionStudy12Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let available: Set<MainActionID> = Set(MainActionID.allCases)

    private func makeStore() -> (MainActionStore, UserDefaults, String) {
        let suite = "MainActionStudy12Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (MainActionStore(defaults: defaults), defaults, suite)
    }

    func testFourteenDayWindowAndPersistentCounts() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.recordUse(.water, at: now.addingTimeInterval(-13 * 86_400))
        store.recordUse(.water, at: now)
        store.recordUse(.meal, at: now.addingTimeInterval(-15 * 86_400))

        let restored = MainActionStore(defaults: defaults)
        XCTAssertEqual(restored.count(for: .water, at: now), 2)
        XCTAssertEqual(restored.count(for: .meal, at: now), 0)
        XCTAssertEqual(restored.preview(available: available, active: nil, at: now).top.first, .water)
    }

    func testLiveActionPinsAndOrderOff() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<5 { store.recordUse(.water, at: now) }
        XCTAssertTrue(store.togglePin(.meal))
        XCTAssertTrue(store.togglePin(.assistant))
        XCTAssertTrue(store.togglePin(.steps))
        XCTAssertFalse(store.togglePin(.music))
        XCTAssertEqual(store.preview(available: available, active: .walk, at: now).top, [.walk, .meal, .assistant])

        store.setOrderByUse(false)
        XCTAssertEqual(store.preview(available: available, active: nil, at: now).top, [.meal, .assistant, .steps])
        XCTAssertEqual(store.preview(available: available, active: nil, at: now).heading, "Pinned")
    }

    func testUnavailableActionsNeverEnterPromotedPositions() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<8 { store.recordUse(.music, at: now) }
        for _ in 0..<2 { store.recordUse(.water, at: now) }
        XCTAssertTrue(store.togglePin(.music))
        XCTAssertEqual(
            store.preview(available: [.workout, .water, .meal, .assistant], active: nil, at: now).top,
            [.water, .workout, .meal]
        )
    }

    func testNewcomerNeedsTwoMoreUsesAndOrderFreezesPerOpen() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<5 { store.recordUse(.water, at: now) }
        for _ in 0..<4 { store.recordUse(.meal, at: now) }
        for _ in 0..<2 { store.recordUse(.assistant, at: now) }
        let first = store.beginOpen(available: available, active: nil, at: now)
        XCTAssertEqual(first.top, [.water, .meal, .assistant])

        for _ in 0..<3 { store.recordUse(.workout, at: now) }
        XCTAssertEqual(first.top, [.water, .meal, .assistant])
        XCTAssertEqual(store.beginOpen(available: available, active: nil, at: now).top, [.water, .meal, .assistant])
        store.recordUse(.workout, at: now)
        // Meal and workout both have 4 uses; Study 12: "Ties keep the fixed order" (workout before meal).
        XCTAssertEqual(store.beginOpen(available: available, active: nil, at: now).top, [.water, .workout, .meal])
    }

    func testResetUndoAndFirstUse() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(store.preview(available: available, active: nil, at: now).isFirstUse)
        store.recordUse(.water, at: now)
        XCTAssertFalse(store.preview(available: available, active: nil, at: now).isFirstUse)
        let backup = store.resetUses()
        XCTAssertEqual(store.count(for: .water, at: now), 0)
        store.restoreUses(backup, at: now)
        XCTAssertEqual(store.count(for: .water, at: now), 1)
    }

    func testUndoOneConfirmedWaterUseKeepsEarlierUses() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.recordUse(.water, at: now)
        let latest = store.recordUse(.water, at: now)
        store.undoUse(latest)
        XCTAssertEqual(store.count(for: .water, at: now), 1)
    }

    func testHoldChoiceAndAssistantNoteImpressionCap() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessionID = UUID()
        let first = store.beginOpen(
            available: available, active: .workout,
            assistantNoteSessionID: sessionID, supportsHold: true, at: now
        )
        let second = store.beginOpen(
            available: available, active: .workout,
            assistantNoteSessionID: sessionID, supportsHold: true, at: now
        )
        let third = store.beginOpen(
            available: available, active: .workout,
            assistantNoteSessionID: sessionID, supportsHold: true, at: now
        )
        XCTAssertTrue(first.showsAssistantNote)
        XCTAssertTrue(second.showsAssistantNote)
        XCTAssertFalse(third.showsAssistantNote)
        XCTAssertTrue(third.showsHoldChoice)
        XCTAssertFalse(store.beginOpen(available: available, active: nil, supportsHold: true, at: now).showsHoldChoice)
        store.setHoldEnabled(true)
        XCTAssertTrue(store.holdEnabled)
        XCTAssertTrue(store.holdChoiceMade)
    }

    func testResetUndoKeepsUsesRecordedAfterResetAndDoesNotDuplicateOnRetry() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.recordUse(.water, at: now.addingTimeInterval(-60))
        XCTAssertTrue(store.togglePin(.music))
        store.setOrderByUse(false)
        let backup = store.resetUses()
        store.recordUse(.meal, at: now)

        store.restoreUses(backup, at: now)
        store.restoreUses(backup, at: now)

        XCTAssertEqual(store.count(for: .water, at: now), 1)
        XCTAssertEqual(store.count(for: .meal, at: now), 1)
        XCTAssertEqual(store.pins, [.music])
        XCTAssertFalse(store.orderByUse)
    }

    func testEditedPreviewDoesNotConsumeAnotherOpeningOrNoteImpression() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessionID = UUID()
        _ = store.beginOpen(
            available: available, active: nil,
            assistantNoteSessionID: sessionID, supportsHold: true, at: now
        )
        XCTAssertTrue(store.togglePin(.music))
        for _ in 0..<5 {
            let preview = store.preview(
                available: available, active: nil,
                assistantNoteSessionID: sessionID, supportsHold: true, at: now
            )
            XCTAssertEqual(preview.top.first, .music)
            XCTAssertTrue(preview.showsAssistantNote)
        }
        XCTAssertTrue(store.beginOpen(
            available: available, active: nil,
            assistantNoteSessionID: sessionID, supportsHold: true, at: now
        ).showsAssistantNote)
        XCTAssertFalse(store.beginOpen(
            available: available, active: nil,
            assistantNoteSessionID: sessionID, supportsHold: true, at: now
        ).showsAssistantNote)
    }

    func testFutureDatedAndExpiredUsesDoNotPromoteAnAction() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.recordUse(.music, at: now.addingTimeInterval(-15 * 86_400))
        store.recordUse(.music, at: now.addingTimeInterval(60))
        store.recordUse(.music, at: now.addingTimeInterval(120))
        XCTAssertEqual(store.count(for: .music, at: now), 0)
        XCTAssertEqual(store.preview(available: available, active: nil, at: now).top, [.workout, .water, .meal])
    }

    func testLearnedTiesUseFixedGridOrderInsteadOfFirstUseDefaults() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<2 {
            store.recordUse(.water, at: now)
            store.recordUse(.walk, at: now)
        }
        XCTAssertEqual(store.preview(available: available, active: nil, at: now).top, [.walk, .water, .workout])
    }

    func testConfirmedWaterReceiptsCountOnceAcrossSurfacesAndUndoOnlyTheirOwnUse() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = HydrationQuickLogReceipt(date: now, previousMilliliters: 0, savedMilliliters: 250)
        let second = HydrationQuickLogReceipt(date: now, previousMilliliters: 250, savedMilliliters: 500)
        XCTAssertEqual(store.recordConfirmedWaterUse(first), store.recordConfirmedWaterUse(first))
        store.recordConfirmedWaterUse(second)
        XCTAssertEqual(store.count(for: .water, at: now), 2)
        store.undoConfirmedWaterUse(second)
        store.undoConfirmedWaterUse(second)
        XCTAssertEqual(store.count(for: .water, at: now), 1)
    }

    func testUsualWaterAmountLearnsFromConfirmedReceiptsPersistsAndRespondsToUndo() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(store.usualWaterMilliliters(at: now), 250)
        let small = HydrationQuickLogReceipt(date: now, previousMilliliters: 0, savedMilliliters: 250)
        let large = HydrationQuickLogReceipt(date: now, previousMilliliters: 250, savedMilliliters: 750)
        let anotherLarge = HydrationQuickLogReceipt(date: now, previousMilliliters: 750, savedMilliliters: 1_250)
        store.recordConfirmedWaterUse(small)
        store.recordConfirmedWaterUse(large)
        XCTAssertEqual(store.usualWaterMilliliters(at: now), 250)
        store.recordConfirmedWaterUse(anotherLarge)
        XCTAssertEqual(store.usualWaterMilliliters(at: now), 500)
        XCTAssertEqual(MainActionStore(defaults: defaults).usualWaterMilliliters(at: now), 500)
        store.undoConfirmedWaterUse(anotherLarge)
        XCTAssertEqual(store.usualWaterMilliliters(at: now), 250)
        XCTAssertEqual(store.usualWaterMilliliters(at: now.addingTimeInterval(15 * 86_400)), 250)
    }

    func testLegacyUseWithoutWaterAmountStillDecodes() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id.uuidString)\",\"action\":\"water\",\"date\":0}".utf8)
        let event = try JSONDecoder().decode(MainActionUseEvent.self, from: data)
        XCTAssertEqual(event.id, id)
        XCTAssertNil(event.waterMilliliters)
    }

    func testUndoResetDoesNotResurrectASeparatelyUndoneWaterAddition() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let receipt = HydrationQuickLogReceipt(date: now, previousMilliliters: 0, savedMilliliters: 500)
        store.recordConfirmedWaterUse(receipt)
        let backup = store.resetUses()
        store.undoConfirmedWaterUse(receipt)
        store.restoreUses(backup, at: now)
        XCTAssertEqual(store.count(for: .water, at: now), 0)
        XCTAssertEqual(store.usualWaterMilliliters(at: now), 250)
    }

    func testConfirmedMealUseIsIdempotentAndCanBeRemovedAfterRelaunch() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let meal = NutritionEntry(
            id: UUID(), title: "Lunch", calories: 500,
            proteinGrams: nil, carbohydrateGrams: nil, fatGrams: nil,
            loggedAt: now.addingTimeInterval(-30 * 86_400)
        )
        store.recordConfirmedMealUse(meal, at: now)
        store.recordConfirmedMealUse(meal, at: now)
        XCTAssertEqual(store.count(for: .meal, at: now), 1, "Count the actual save action, not a backdated meal's date.")
        let restored = MainActionStore(defaults: defaults)
        restored.undoUse(meal.id)
        XCTAssertEqual(restored.count(for: .meal, at: now), 0)
    }

    func testResetUndoCannotResurrectDeletedMealUse() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let meal = NutritionEntry(
            id: UUID(), title: "Lunch", calories: 500,
            proteinGrams: nil, carbohydrateGrams: nil, fatGrams: nil, loggedAt: now
        )
        store.recordConfirmedMealUse(meal, at: now)
        let backup = store.resetUses()
        store.undoUse(meal.id)
        store.recordConfirmedMealUse(meal, at: now)
        store.restoreUses(backup, at: now)
        XCTAssertEqual(store.count(for: .meal, at: now), 0)
    }
}

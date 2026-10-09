import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class SharedSurfaceLocalizationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    func testLegacyAbsentLanguageDecodesWithoutAddingFactsOrChangingVersion() throws {
        let original = snapshot()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DailyWidgetSnapshot.self, from: data)
        XCTAssertNil(decoded.displayLanguageIdentifier)
        XCTAssertEqual(decoded.displayLanguage, .english)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(decoded.version, 1)
        let state = activityState()
        let decodedState = try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self,
                                                   from: JSONEncoder().encode(state))
        XCTAssertNil(decodedState.displayLanguageIdentifier)
        XCTAssertEqual(decodedState.displayLanguage, .english)
        XCTAssertEqual(decodedState, state)
    }

    func testUnknownAndMalformedLanguageNeverDiscardValidWidgetMetrics() throws {
        for raw: Any in ["future-language", true, 7, ["future"], NSNull()] {
            let decoded = try JSONDecoder().decode(DailyWidgetSnapshot.self,
                from: replacingLanguage(in: snapshot(), with: raw))
            XCTAssertEqual(decoded.displayLanguage, .english)
            XCTAssertTrue(decoded.isValid)
            XCTAssertEqual(try factBytes(decoded), try factBytes(snapshot()))
            if let raw = raw as? String { XCTAssertEqual(decoded.displayLanguageIdentifier, raw) }
        }
    }

    func testUnknownAndMalformedLanguageNeverDiscardActivityFacts() throws {
        let original = activityState()
        for raw: Any in ["future-language", false, 4, ["future"], NSNull()] {
            let decoded = try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self,
                from: replacingLanguage(in: original, with: raw))
            XCTAssertEqual(decoded.displayLanguage, .english)
            XCTAssertEqual(try factBytes(decoded), try factBytes(original))
            if let raw = raw as? String { XCTAssertEqual(decoded.displayLanguageIdentifier, raw) }
        }
    }

    func testNewLanguageMetadataRoundTripsAndOnlyItsEncodedFieldChanges() throws {
        let original = snapshot()
        for language in [AppLanguage.english, .bulgarian] {
            let localized = original.usingLanguage(language)
            XCTAssertEqual(localized.displayLanguage, language)
            XCTAssertEqual(try factBytes(localized), try factBytes(original))
            XCTAssertEqual(try JSONDecoder().decode(DailyWidgetSnapshot.self,
                from: JSONEncoder().encode(localized)), localized)
            XCTAssertEqual(localized.latestWalk?.distanceMeters, 3750.125)
            XCTAssertEqual(localized.latestWalk?.activeSeconds, 3661.75)
            XCTAssertEqual(localized.steps.asOf, original.steps.asOf)
            XCTAssertTrue(localized.steps.isStale)
            XCTAssertEqual(localized.isCurrent(on: now, calendar: calendar), original.isCurrent(on: now, calendar: calendar))
            XCTAssertFalse(localized.isCurrent(on: now.addingTimeInterval(86400), calendar: calendar))
        }
    }

    func testLanguageOnlyActivityProjectionUpdatesSameActivityAndPreservesDeadline() throws {
        let original = WorkoutActivityProjection(sessionID: UUID(), workoutTitle: "Workout 50% %@",
            state: activityState()).usingLanguage(.english)
        let localized = original.usingLanguage(.bulgarian)
        XCTAssertEqual(localized.sessionID, original.sessionID)
        XCTAssertEqual(localized.workoutTitle, original.workoutTitle)
        XCTAssertEqual(localized.staleDate, original.staleDate)
        XCTAssertEqual(try factBytes(localized.state), try factBytes(original.state))
        XCTAssertEqual(localized.state.exerciseName, "Set saved 50% %@ %2$lld")
        XCTAssertEqual(WorkoutActivityDecision.decide(desired: localized,
            existingSessionID: original.sessionID, existingState: original.state), .update)
        XCTAssertEqual(WorkoutActivityDecision.decide(desired: localized,
            existingSessionID: localized.sessionID, existingState: localized.state), .unchanged)
    }

    func testInputsLanguageChangeDoesNotChangeHealthOrHydrationProjectionRules() throws {
        let start = calendar.startOfDay(for: now)
        let inputs = DailyWidgetInputs(steps: nil, stepsStatus: .notConnected, stepsFailed: false,
            health: nil, healthStatus: .notConnected, healthIsStale: true, meals: [],
            nutritionAvailable: true, water: HydrationState(currentMilliliters: 750, goalMilliliters: 2500),
            waterDayStart: start, hydrationAvailable: true)
        let english = inputs.usingLanguage(.english).snapshot(at: now, calendar: calendar)
        let bulgarian = inputs.usingLanguage(.bulgarian).snapshot(at: now, calendar: calendar)
        XCTAssertEqual(try factBytes(english), try factBytes(bulgarian))
        XCTAssertEqual(bulgarian.steps.state, .needsConnection)
        XCTAssertNil(bulgarian.steps.value)
        XCTAssertEqual(bulgarian.eatenKilocalories.value, 0)
        XCTAssertEqual(bulgarian.waterMilliliters.value, 750)
        XCTAssertEqual(bulgarian.displayLanguage, .bulgarian)
        XCTAssertNil(inputs.language)
    }

    func testLanguagePublishReloadsOnceAndFreshStoreRetainsMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDailyWidgetSnapshotStore(directory: directory)
        var reloads = 0
        let publisher = DailyWidgetPublisher(store: store, reload: { reloads += 1 })
        let english = snapshot().usingLanguage(.english)
        let bulgarian = english.usingLanguage(.bulgarian)
        XCTAssertTrue(publisher.publish(english))
        XCTAssertTrue(publisher.publish(bulgarian))
        XCTAssertTrue(publisher.publish(bulgarian))
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(try FileDailyWidgetSnapshotStore(directory: directory).load(), bulgarian)
    }

    func testLanguageRestorationAfterWaterOverlayDoesNotReviveExpiredMetricsOrAlterTransaction() throws {
        let base = snapshot().usingLanguage(.bulgarian)
        let transaction = HydrationTransactionState(state: .init(date: now, currentMilliliters: 750,
            goalMilliliters: 2500, dayStart: calendar.startOfDay(for: now)))
        let nextDay = now.addingTimeInterval(86400)
        let water = try XCTUnwrap(DailyWidgetWaterState(transaction: transaction, at: nextDay, calendar: calendar))
        let before = try factBytes(transaction)
        let expired = water.displaySnapshot(base: base, at: nextDay, calendar: calendar)
            .usingLanguage(base.displayLanguage)
        XCTAssertEqual(expired.displayLanguage, .bulgarian)
        XCTAssertNil(expired.steps.value)
        XCTAssertNil(expired.burnedKilocalories.value)
        XCTAssertEqual(expired.waterMilliliters.value, 0)
        XCTAssertEqual(try factBytes(transaction), before)
        XCTAssertNil(water.undo)
        let unavailable = DailyWidgetWaterState.unavailableSnapshot(base: base, at: nextDay, calendar: calendar)
            .usingLanguage(base.displayLanguage)
        XCTAssertNil(unavailable.waterMilliliters.value)
        XCTAssertEqual(unavailable.displayLanguage, .bulgarian)
    }

    func testActualExtensionBundleResourcesAndSafeTypedCounts() throws {
        // Hosted native XCTest fails if generation/embedding omitted extension catalogs.
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let extensionBundle = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("ZeroOneLiveActivity.appex")))
        for language in [AppLanguage.english, .bulgarian] {
            let folder = try XCTUnwrap(extensionBundle.url(forResource: language.rawValue, withExtension: "lproj"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Localizable.strings").path))
        }
        let english = SharedSurfaceLocalization(language: .english, bundle: extensionBundle)
        let bulgarian = SharedSurfaceLocalization(language: .bulgarian, bundle: extensionBundle)
        XCTAssertEqual(english.seconds(0), "0 seconds")
        XCTAssertEqual(english.seconds(1), "1 second")
        XCTAssertEqual(english.seconds(2), "2 seconds")
        XCTAssertEqual(bulgarian.seconds(0), "0 секунди")
        XCTAssertEqual(bulgarian.seconds(1), "1 секунда")
        XCTAssertEqual(bulgarian.seconds(2), "2 секунди")
        XCTAssertEqual(bulgarian.seconds(Int.max), "\(Int.max) секунди")
        XCTAssertEqual(bulgarian.localization.string("Log your set"), "Запиши серията си")
        XCTAssertEqual(bulgarian.localization.format("Next: %1$@", .text("Set saved %@ 50%")), "Следващо: Set saved %@ 50%")
    }

    func testKnownPhasesAndMetricStatesUseTranslatedDisplayWithoutProcessLookup() {
        let english = AppLocalization(language: .english)
        let bulgarian = AppLocalization(language: .bulgarian)
        for (phase, title) in [(WorkoutActivityAttributes.ContentState.Phase.warmUp, "Първо загрей"),
            (.active, "Запиши серията си"), (.rest, "Почивка"), (.paused, "На пауза"),
            (.awaitingNextSet, "Серията е записана"), (.readyToFinish, "Всички серии са завършени"),
            (.saving, "Тренировката се записва")] {
            XCTAssertEqual(activityState(phase: phase).usingLanguage(.bulgarian).phaseTitle, title)
        }
        XCTAssertEqual(DailyWidgetFormatting.stateText(.missing(.noData), localization: bulgarian), "Няма достъпни данни")
        XCTAssertEqual(DailyWidgetFormatting.stateText(.missing(.needsConnection), localization: bulgarian), "Свържи в 01")
        XCTAssertEqual(DailyWidgetFormatting.stateText(.reading(0, at: now, isStale: true), localization: bulgarian), "Нужно е обновяване")
        XCTAssertNil(DailyWidgetFormatting.stateText(.reading(0, at: now), localization: bulgarian))
        XCTAssertEqual(DailyWidgetFormatting.value(.reading(0, at: now), localization: english), "0")
        XCTAssertEqual(DailyWidgetFormatting.value(.missing(.noData), localization: bulgarian), "—")
    }

    func testWalkDisplayRetainsUnitChoiceTotalsAndTimeInsteadOfParsingLocalizedText() throws {
        let walk = try XCTUnwrap(snapshot().latestWalk)
        let before = try factBytes(walk)
        let english = AppLocalization(language: .english), bulgarian = AppLocalization(language: .bulgarian)
        XCTAssertEqual(walk.durationText(using: english), "1 h 1 min")
        XCTAssertEqual(walk.durationText(using: bulgarian), "1 ч 1 мин")
        XCTAssertTrue(walk.distanceText(using: bulgarian).hasSuffix(" км"))
        XCTAssertTrue(walk.usingMiles(true).distanceText(using: english).hasSuffix(" mi"))
        XCTAssertTrue(walk.usingMiles(true).distanceText(using: bulgarian).hasSuffix(" ми"))
        XCTAssertEqual(try factBytes(walk), before)
        let short = DailyWidgetSnapshot.Walk(finishedAt: now, activeSeconds: 59.9,
            distanceMeters: nil, distanceIncomplete: true)
        XCTAssertEqual(short.durationText(using: bulgarian), "Под 1 мин")
        XCTAssertEqual(short.distanceText(using: english), "Distance unavailable")
    }

    func testRealWidgetAndPreviewQuickAddLabelUsesTypedAmount() {
        XCTAssertEqual(DailyWidgetActionLabel(waterAmount: 250, language: .english).title, "+250 ml")
        XCTAssertEqual(DailyWidgetActionLabel(waterAmount: 250, language: .bulgarian).title, "+250 мл")
        XCTAssertEqual(DailyWidgetActionLabel(waterAmount: 500, prominent: false, language: .bulgarian).title, "+500 мл")
    }

    private func snapshot() -> DailyWidgetSnapshot {
        DailyWidgetSnapshot(generatedAt: now, dayStart: calendar.startOfDay(for: now),
            steps: .reading(1234, at: now.addingTimeInterval(-60), isStale: true),
            eatenKilocalories: .reading(800, at: now), burnedKilocalories: .reading(350, at: now.addingTimeInterval(-60)),
            waterMilliliters: .reading(750, at: now), waterGoalMilliliters: 2500,
            latestWalk: .init(finishedAt: now.addingTimeInterval(-30), activeSeconds: 3661.75,
                distanceMeters: 3750.125, distanceIncomplete: true), stepGoal: 8000, foodGoalKilocalories: 2200, accent: .pink)
    }
    private func activityState(phase: WorkoutActivityAttributes.ContentState.Phase = .rest) -> WorkoutActivityAttributes.ContentState {
        .init(exerciseName: "Set saved 50% %@ %2$lld", currentSet: 2, plannedSetsForExercise: 3,
            completedSets: 1, totalSets: 12, phase: phase, restEndsAt: now.addingTimeInterval(63),
            pausedRestSeconds: 63, accentPreference: "pink")
    }
    private func replacingLanguage<T: Encodable>(in value: T, with language: Any) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object["displayLanguageIdentifier"] = language
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func factBytes<T: Encodable>(_ value: T) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object.removeValue(forKey: "displayLanguageIdentifier")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

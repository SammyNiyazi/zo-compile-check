import Foundation
import XCTest
@testable import ZeroOne

final class AssistantResponseCopyTests: XCTestCase {
    private let policy = ContextualAssistantPolicy()
    private let bulgarian = AppLocalization(language: .bulgarian)
    private let titles = ["Train today", "Continue Add water", "50% %@ %1$@ %1$lld %%", "Сила 🏋️ 東京 e\u{301}", "Make X 30 minutes\nNUTRITION"]

    func testContinueAndAdaptPreserveAdversarialWorkoutNamesInBothLanguages() {
        for title in titles {
            let context = makeContext(workout: .inProgress(title: title, canAdaptToThirtyMinutes: true))
            for (intent, english, bg, action) in [
                (ContextualAssistantIntent.continueWorkout, "Continue \(title)", "Продължи \(title)", AssistantActionID.continueWorkout),
                (.adaptToThirtyMinutes, "Make \(title) 30 minutes", "Съкрати \(title) до 30 минути", .shortenWorkout)
            ] {
                let source = policy.response(for: intent, context: context)
                XCTAssertEqual(copy(source, context, .english).title, english)
                XCTAssertEqual(copy(source, context, bulgarian).title, bg)
                XCTAssertEqual(copy(source, context, bulgarian).action, action)
                XCTAssertEqual(source.title, english)
            }
        }
    }

    func testReadyAndCompletedPreserveNamesIncludingKeysAndPercentTokens() {
        for title in titles {
            let ready = makeContext(today: .ready(workoutTitle: title))
            let readyResponse = policy.currentStateResponse(for: ready)
            XCTAssertEqual(copy(readyResponse, ready, bulgarian).detail, "\(title) е готова от локалната ти програма.")
            XCTAssertEqual(copy(readyResponse, ready, .english).detail, "\(title) is ready from your local programme.")
            XCTAssertEqual(copy(readyResponse, ready, bulgarian).action, .trainToday)
            let completed = makeContext(today: .completed(workoutTitle: title))
            let completedResponse = policy.currentStateResponse(for: completed)
            XCTAssertEqual(copy(completedResponse, completed, bulgarian).detail, "\(title) е записана локално за днес.")
            XCTAssertEqual(copy(completedResponse, completed, .english).detail, "\(title) is recorded locally for today.")
            XCTAssertEqual(copy(completedResponse, completed, bulgarian).action, .openNutrition)
        }
    }

    func testHydrationAndMealCountsUseExactTypedValuesWithoutChangingFacts() {
        for count in [0, 7, 750, Int.max] {
            let context = makeContext(water: count, meals: count)
            let water = policy.response(for: .addWater, context: context)
            let meals = policy.response(for: .openNutrition, context: context)
            XCTAssertEqual(copy(water, context, bulgarian).detail, "Текущото ти локално количество е \(count) мл.")
            XCTAssertEqual(copy(meals, context, bulgarian).detail, "Имаш \(count) локални записа днес.")
            XCTAssertEqual(copy(water, context, .english).detail, water.detail)
            XCTAssertEqual(copy(meals, context, .english).detail, meals.detail)
            XCTAssertEqual(copy(water, context, bulgarian).action, .addWater)
            XCTAssertEqual(copy(meals, context, bulgarian).action, .openNutrition)
            XCTAssertEqual(context.hydration.consumedMilliliters, count)
            XCTAssertEqual(context.nutrition.entryCountToday, count)
        }
    }

    func testKnownStaticCopyAndEyebrowsUseSelectedLanguageAndSentenceCase() {
        let context = makeContext(today: .ready(workoutTitle: "My workout"))
        let source = policy.currentStateResponse(for: context)
        let en = copy(source, context, .english)
        let bg = copy(source, context, bulgarian)
        XCTAssertEqual(en.eyebrow, "Next action")
        XCTAssertEqual(bg.eyebrow, "Следващо действие")
        XCTAssertEqual(bg.title, "Тренирай днес")
        XCTAssertEqual(bg.actionTitle, "Прегледай тренировката")
        XCTAssertEqual(source.eyebrow, "NEXT ACTION")
        XCTAssertEqual(source.title, "Train today")
        XCTAssertEqual(source.action, bg.action)
    }

    func testAllSupportedPolicyResponsesPreserveTheirOriginalAction() {
        let contexts = [makeContext(), makeContext(today: .ready(workoutTitle: "Upper A")),
                        makeContext(today: .completed(workoutTitle: "Upper A")),
                        makeContext(workout: .inProgress(title: "Upper A", canAdaptToThirtyMinutes: true)),
                        makeContext(workout: .inProgress(title: "Upper A", canAdaptToThirtyMinutes: false)),
                        makeContext(hydrationAvailable: false, nutritionAvailable: false)]
        let intents: [ContextualAssistantIntent] = [.whatShouldIDoNow, .adaptToThirtyMinutes, .addWater,
                                                   .openNutrition, .chooseWorkout, .continueWorkout, .unknown]
        for context in contexts {
            for intent in intents {
                let source = policy.response(for: intent, context: context)
                for language in [AppLocalization.english, bulgarian] {
                    XCTAssertEqual(copy(source, context, language).action, source.action)
                }
            }
        }
    }

    func testUnsupportedAndUnavailableCopyRetainsPolicyFallbackAuthority() {
        let context = makeContext(today: .ready(workoutTitle: "Upper A"), hydrationAvailable: false,
                                  nutritionAvailable: false)
        let unknown = policy.response(for: .unknown, context: context)
        let unavailableWater = policy.response(for: .addWater, context: context)
        let nutrition = policy.response(for: .openNutrition, context: context)
        XCTAssertEqual(copy(unknown, context, bulgarian).title, "Това още не се поддържа")
        XCTAssertEqual(copy(unknown, context, bulgarian).action, .trainToday)
        XCTAssertEqual(copy(unavailableWater, context, bulgarian).detail, "Локалните записи за вода не са достъпни в момента.")
        XCTAssertEqual(copy(unavailableWater, context, bulgarian).action, .trainToday)
        XCTAssertEqual(copy(nutrition, context, bulgarian).detail,
                       "Хранилището за хранене не е достъпно, но можеш да прегледаш екрана.")
        XCTAssertEqual(copy(nutrition, context, bulgarian).action, .openNutrition)
    }

    func testContinueAndAdaptNeedMatchingActiveContextAndActionCase() {
        let active = makeContext(workout: .inProgress(title: "Train today %1$@", canAdaptToThirtyMinutes: true))
        let stale = makeContext(workout: .inProgress(title: "Different", canAdaptToThirtyMinutes: true))
        let ineligible = makeContext(workout: .inProgress(title: "Train today %1$@", canAdaptToThirtyMinutes: false))
        for intent in [ContextualAssistantIntent.continueWorkout, .adaptToThirtyMinutes] {
            let source = policy.response(for: intent, context: active)
            for missing in [makeContext(), stale] {
                XCTAssertEqual(copy(source, missing, bulgarian).title, source.title)
            }
            XCTAssertEqual(copy(replace(source, action: .addWater), active, bulgarian).title, source.title)
            XCTAssertEqual(copy(replace(source, eyebrow: "GENERATED"), active, bulgarian).title, source.title)
            let altered = replace(source, title: source.title + " ")
            XCTAssertEqual(copy(altered, active, bulgarian).title, altered.title)
        }
        let shorten = policy.response(for: .adaptToThirtyMinutes, context: active)
        XCTAssertEqual(copy(shorten, ineligible, bulgarian).title, shorten.title)
    }

    func testReadyAndCompletedDetailsNeedMatchingTodayCaseNameAndResponseCase() {
        for state in [AssistantTodayState.ready(workoutTitle: "Train today %1$lld"), .completed(workoutTitle: "Train today %1$lld")] {
            let context = makeContext(today: state)
            let source = policy.currentStateResponse(for: context)
            for stale in [makeContext(), makeContext(today: .ready(workoutTitle: "Other")),
                          makeContext(today: .completed(workoutTitle: "Other"))] {
                XCTAssertEqual(copy(source, stale, bulgarian).detail, source.detail)
            }
            for changed in [replace(source, action: .addWater), replace(source, eyebrow: "GENERATED"),
                            replace(source, title: "Generated title"), replace(source, detail: source.detail + " ")] {
                XCTAssertEqual(copy(changed, context, bulgarian).detail, changed.detail)
            }
        }
    }

    func testNumericTemplatesRejectMismatchedMissingAndUnmatchedFacts() {
        let context = makeContext(water: 750, meals: 3)
        let absent = makeContext(water: 750, meals: 3, hydrationAvailable: false, nutritionAvailable: false)
        let stale = makeContext(water: 500, meals: 4)
        for intent in [ContextualAssistantIntent.addWater, .openNutrition] {
            let source = policy.response(for: intent, context: context)
            for missing in [absent, stale] {
                XCTAssertEqual(copy(source, missing, bulgarian).detail, source.detail)
            }
            for altered in [replace(source, action: .openWorkoutLibrary), replace(source, eyebrow: "GENERATED"),
                            replace(source, title: "Generated title"), replace(source, detail: source.detail + " %1$lld")] {
                XCTAssertEqual(copy(altered, context, bulgarian).detail, altered.detail)
            }
        }
    }

    func testUnknownFieldsAndUnmatchedTemplatesRemainVerbatim() {
        let context = makeContext()
        for title in titles {
            let response = ContextualAssistantResponse(eyebrow: "NUTRITION \(title)", title: title,
                detail: "Your current local total is 001 ml. \(title)", actionTitle: "Choose \(title)", action: .reviewWellbeing)
            let display = copy(response, context, bulgarian)
            XCTAssertEqual(display.eyebrow, response.eyebrow)
            XCTAssertEqual(display.title, title)
            XCTAssertEqual(display.detail, response.detail)
            XCTAssertEqual(display.actionTitle, response.actionTitle)
            XCTAssertEqual(display.action, response.action)
        }
        let keyCollision = ContextualAssistantResponse(eyebrow: "Generated", title: "Train today",
            detail: "Your active workout state is stored locally.", actionTitle: "Add water", action: .addWater)
        let collisionCopy = copy(keyCollision, context, bulgarian)
        XCTAssertEqual(collisionCopy.title, keyCollision.title)
        XCTAssertEqual(collisionCopy.detail, keyCollision.detail)
        XCTAssertEqual(collisionCopy.actionTitle, keyCollision.actionTitle)
        let unmatched = ContextualAssistantResponse(eyebrow: "READY TO CONFIRM", title: "Add 250 ml",
            detail: "Your current local total is 0750 ml.", actionTitle: "Add water", action: .addWater)
        XCTAssertEqual(copy(unmatched, makeContext(water: 750), bulgarian).detail, unmatched.detail)
    }

    func testKnownWellbeingKeysResolveWithoutRecalculatingRecommendation() {
        let source = ContextualAssistantResponse(eyebrow: "RECOVERY AND FUELLING", title: "How are you feeling?",
            detail: "A short check-in helps 01 connect training, recovery and food without guessing from missing logs.",
            actionTitle: "Review check-in", action: .reviewWellbeing)
        let display = copy(source, makeContext(), bulgarian)
        XCTAssertEqual(display.eyebrow, bulgarian.string("Recovery and fuelling"))
        XCTAssertNotEqual(display.title, source.title)
        XCTAssertNotEqual(display.detail, source.detail)
        XCTAssertEqual(display.actionTitle, "Прегледай проверката")
        XCTAssertEqual(display.action, .reviewWellbeing)
    }

    func testMissingLanguageResourcesFallBackToSourceTemplatesWithoutLosingMetadata() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AssistantResponseCopy-\(UUID()).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "app.the01.assistant-copy-test",
            "CFBundlePackageType": "BNDL", "CFBundleDevelopmentRegion": "en"], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: url))
        let localization = AppLocalization(language: .bulgarian, bundle: bundle)
        let context = makeContext(workout: .inProgress(title: titles[2], canAdaptToThirtyMinutes: true))
        let source = policy.response(for: .continueWorkout, context: context)
        let display = copy(source, context, localization)
        XCTAssertEqual(display.title, source.title)
        XCTAssertEqual(display.detail, source.detail)
        XCTAssertEqual(display.eyebrow, "In progress")
        XCTAssertEqual(display.action, source.action)
    }

    private func copy(_ response: ContextualAssistantResponse, _ context: AssistantContext,
                      _ localization: AppLocalization) -> AssistantResponseCopy {
        AssistantResponseCopy(response: response, context: context, localization: localization)
    }

    private func replace(_ source: ContextualAssistantResponse, eyebrow: String? = nil, title: String? = nil,
                         detail: String? = nil, action: AssistantActionID? = nil) -> ContextualAssistantResponse {
        ContextualAssistantResponse(eyebrow: eyebrow ?? source.eyebrow, title: title ?? source.title,
            detail: detail ?? source.detail, actionTitle: source.actionTitle, action: action ?? source.action)
    }

    private func makeContext(workout: AssistantWorkoutState = .none, today: AssistantTodayState = .noWorkoutReady,
                             water: Int = 0, meals: Int = 0, hydrationAvailable: Bool = true,
                             nutritionAvailable: Bool = true) -> AssistantContext {
        AssistantContext(profile: AssistantProfileContext(trainingGoal: nil, trainingExperience: nil,
            weeklyAvailability: nil, equipmentAccess: nil, trainingConstraint: nil), workout: workout, today: today,
            hydration: AssistantHydrationContext(consumedMilliliters: water, goalMilliliters: 2_000, isAvailable: hydrationAvailable),
            nutrition: AssistantNutritionContext(entryCountToday: meals, isAvailable: nutritionAvailable),
            health: AssistantHealthContextAvailability(isConnected: false, hasLocalContext: false))
    }
}

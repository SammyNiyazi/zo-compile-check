import Foundation
import XCTest
@testable import ZeroOne

final class OnboardingProgressTests: XCTestCase {
    func testFreshSetupStartsAtWelcomeAndResumesSavedPage() throws {
        let suite = "OnboardingProgressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsZeroOneOnboardingProgressStore(defaults: defaults, key: "page")

        XCTAssertNil(store.loadStep())
        store.saveStep(-1)
        XCTAssertEqual(store.loadStep(), -1)
        store.saveStep(3)
        XCTAssertEqual(store.loadStep(), 3)
        store.saveStep(5)
        XCTAssertEqual(store.loadStep(), 5)
        store.saveStep(6)
        XCTAssertEqual(store.loadStep(), 6)
        XCTAssertEqual(
            UserDefaultsZeroOneOnboardingProgressStore(defaults: defaults, key: "page").loadStep(),
            6
        )
        store.clear()
        XCTAssertNil(store.loadStep())
    }

    func testLanguagePageResumesAndDoesNotRenumberExistingWelcomeOrQuestions() throws {
        let suite = "OnboardingProgressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsZeroOneOnboardingProgressStore(defaults: defaults, key: "page")
        store.saveStep(-2)
        XCTAssertEqual(UserDefaultsZeroOneOnboardingProgressStore(defaults: defaults, key: "page").loadStep(), -2)
        for priorStep in -1...6 {
            store.saveStep(priorStep)
            XCTAssertEqual(UserDefaultsZeroOneOnboardingProgressStore(defaults: defaults, key: "page").loadStep(), priorStep)
        }
        store.saveStep(-3)
        XCTAssertEqual(store.loadStep(), 6)
    }

    func testFinalTenStepRouteHasMatchingForwardBackAndProgress() {
        let expected = [-1, 0, 1, 3, 2, 7, 4, 8, 9, 6]
        XCTAssertEqual(ZeroOneOnboardingFlow.pages, expected)
        XCTAssertEqual(ZeroOneOnboardingFlow.next(after: -2), -1)
        for (index, page) in expected.enumerated() {
            XCTAssertEqual(ZeroOneOnboardingFlow.progress(for: page)?.current, index + 1)
            XCTAssertEqual(ZeroOneOnboardingFlow.progress(for: page)?.total, 10)
            XCTAssertEqual(ZeroOneOnboardingFlow.previous(before: page), index == 0 ? nil : expected[index - 1])
            XCTAssertEqual(ZeroOneOnboardingFlow.next(after: page), index == 9 ? nil : expected[index + 1])
        }
        XCTAssertEqual(ZeroOneOnboardingFlow.next(after: 5), 6)
        XCTAssertEqual(ZeroOneOnboardingFlow.previous(before: 5), 4)
        XCTAssertNil(ZeroOneOnboardingFlow.progress(for: 5))
    }

    func testNewPermissionAndGoalPagesResumeWithoutChangingLegacyPages() throws {
        let suite = "OnboardingProgressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsZeroOneOnboardingProgressStore(defaults: defaults, key: "page")
        for page in -2...9 {
            store.saveStep(page)
            XCTAssertEqual(UserDefaultsZeroOneOnboardingProgressStore(defaults: defaults, key: "page").loadStep(), page)
        }
    }

    func testInvalidSavedPageCannotTrapFirstRun() throws {
        let suite = "OnboardingProgressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsZeroOneOnboardingProgressStore(defaults: defaults, key: "page")

        store.saveStep(10)
        XCTAssertNil(store.loadStep())

        defaults.set(99, forKey: "page")
        XCTAssertNil(store.loadStep())
    }
}

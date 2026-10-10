import XCTest
@testable import ZeroOne

final class SplashBrandRevealTests: XCTestCase {
    func testProcessGatePreventsLaunchReplayWhenAnotherSceneIsCreated() {
        let gate = ZeroOneLaunchProcessState()
        XCTAssertFalse(gate.hasPresented)

        gate.markPresented()

        XCTAssertTrue(gate.hasPresented)
    }

    func testFirstRevealAndColdLaunchUseDistinctHolds() {
        XCTAssertEqual(
            ZeroOneLaunchExperienceTiming.holdDuration(
                presentation: .firstReveal
            ),
            .milliseconds(720)
        )
        XCTAssertEqual(
            ZeroOneLaunchExperienceTiming.holdDuration(
                presentation: .coldLaunch
            ),
            .milliseconds(120)
        )
    }

    func testFirstRevealUsesCounterweightOnlyWhenMotionAndDestinationAreAvailable() {
        XCTAssertEqual(
            ZeroOneLaunchExperienceTiming.content(
                presentation: .firstReveal,
                usesReducedMotion: false,
                hasDestinationAnchors: true
            ),
            .counterweight
        )
        XCTAssertEqual(
            ZeroOneLaunchExperienceTiming.content(
                presentation: .firstReveal,
                usesReducedMotion: true,
                hasDestinationAnchors: true
            ),
            .staticFullLockup
        )
        XCTAssertEqual(
            ZeroOneLaunchExperienceTiming.content(
                presentation: .firstReveal,
                usesReducedMotion: false,
                hasDestinationAnchors: false
            ),
            .staticFullLockup
        )
    }

    func testColdLaunchUsesMarkWithoutLegacySplashVideo() {
        XCTAssertEqual(
            ZeroOneLaunchExperienceTiming.content(
                presentation: .coldLaunch,
                usesReducedMotion: false,
                hasDestinationAnchors: true
            ),
            .staticMark
        )
        XCTAssertEqual(
            ZeroOneLaunchExperienceTiming.content(
                presentation: .coldLaunch,
                usesReducedMotion: true,
                hasDestinationAnchors: false
            ),
            .staticMark
        )
    }

    func testFreshInstallUsesFirstRevealUntilItCompletes() {
        let store = InMemoryLaunchRevealStore()
        let state = ZeroOneLaunchRevealState(store: store)

        XCTAssertEqual(state.presentation, .firstReveal)

        let interruptedState = ZeroOneLaunchRevealState(store: store)
        XCTAssertEqual(interruptedState.presentation, .firstReveal)

        state.recordCompletedPresentation(.firstReveal)

        XCTAssertEqual(ZeroOneLaunchRevealState(store: store).presentation, .coldLaunch)
    }

    func testCompletingColdLaunchDoesNotAlterFirstRevealPersistence() {
        let store = InMemoryLaunchRevealStore()
        let state = ZeroOneLaunchRevealState(store: store)

        state.recordCompletedPresentation(.coldLaunch)

        XCTAssertEqual(ZeroOneLaunchRevealState(store: store).presentation, .firstReveal)
    }

    func testOrdinaryRelaunchUsesColdLaunchPresentation() {
        let store = InMemoryLaunchRevealStore(hasCompletedFirstReveal: true)

        XCTAssertEqual(ZeroOneLaunchRevealState(store: store).presentation, .coldLaunch)
    }

    func testFreshInstallIsEligibleUntilRevealCompletes() {
        let store = InMemoryLaunchRevealStore()
        let state = ZeroOneLaunchRevealState(store: store)

        XCTAssertTrue(state.shouldPresentFirstReveal)

        let interruptedState = ZeroOneLaunchRevealState(store: store)
        XCTAssertTrue(interruptedState.shouldPresentFirstReveal)

        state.recordCompletedPresentation(.firstReveal)

        XCTAssertFalse(ZeroOneLaunchRevealState(store: store).shouldPresentFirstReveal)
    }

    func testOrdinaryRelaunchBypassesFirstReveal() {
        let store = InMemoryLaunchRevealStore(hasCompletedFirstReveal: true)

        XCTAssertFalse(ZeroOneLaunchRevealState(store: store).shouldPresentFirstReveal)
    }

    func testDebugResetRestoresFirstRevealEligibility() {
        let store = InMemoryLaunchRevealStore(hasCompletedFirstReveal: true)
        let state = ZeroOneLaunchRevealState(store: store)

        XCTAssertFalse(state.shouldPresentFirstReveal)

        state.reset()

        XCTAssertTrue(ZeroOneLaunchRevealState(store: store).shouldPresentFirstReveal)
    }

    func testUserDefaultsStorePersistsCompletionAcrossInstances() throws {
        let suiteName = "SplashBrandRevealTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = "first-reveal"
        UserDefaultsZeroOneLaunchRevealStore(defaults: defaults, key: key).markFirstRevealCompleted()

        XCTAssertTrue(
            UserDefaultsZeroOneLaunchRevealStore(defaults: defaults, key: key).hasCompletedFirstReveal
        )
    }

    func testDebugResetFlagIsExplicit() {
        XCTAssertFalse(ZeroOneLaunchDebugOptions.shouldResetFirstReveal(environment: [:]))
        XCTAssertFalse(
            ZeroOneLaunchDebugOptions.shouldResetFirstReveal(
                environment: ["ZERO_ONE_SPLASH_RESET_FIRST_REVEAL": "0"]
            )
        )
        XCTAssertTrue(
            ZeroOneLaunchDebugOptions.shouldResetFirstReveal(
                environment: ["ZERO_ONE_SPLASH_RESET_FIRST_REVEAL": "1"]
            )
        )
    }
}

private final class InMemoryLaunchRevealStore: ZeroOneLaunchRevealPersisting {
    var hasCompletedFirstReveal: Bool

    init(hasCompletedFirstReveal: Bool = false) {
        self.hasCompletedFirstReveal = hasCompletedFirstReveal
    }

    func markFirstRevealCompleted() {
        hasCompletedFirstReveal = true
    }

    func resetFirstReveal() {
        hasCompletedFirstReveal = false
    }
}


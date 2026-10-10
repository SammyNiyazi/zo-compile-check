import Foundation

enum ZeroOneLaunchPresentation: Equatable {
    case firstReveal
    case coldLaunch
}

protocol ZeroOneLaunchRevealPersisting {
    var hasCompletedFirstReveal: Bool { get }

    func markFirstRevealCompleted()
    func resetFirstReveal()
}

struct UserDefaultsZeroOneLaunchRevealStore: ZeroOneLaunchRevealPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "slick.hasCompletedFirstBrandReveal"
    ) {
        self.defaults = defaults
        self.key = key
    }

    var hasCompletedFirstReveal: Bool {
        defaults.bool(forKey: key)
    }

    func markFirstRevealCompleted() {
        defaults.set(true, forKey: key)
    }

    func resetFirstReveal() {
        defaults.removeObject(forKey: key)
    }
}

struct ZeroOneLaunchRevealState {
    private let store: any ZeroOneLaunchRevealPersisting

    init(store: any ZeroOneLaunchRevealPersisting = UserDefaultsZeroOneLaunchRevealStore()) {
        self.store = store
    }

    var shouldPresentFirstReveal: Bool {
        !store.hasCompletedFirstReveal
    }

    var presentation: ZeroOneLaunchPresentation {
        shouldPresentFirstReveal ? .firstReveal : .coldLaunch
    }

    func recordCompletedPresentation(_ presentation: ZeroOneLaunchPresentation) {
        guard presentation == .firstReveal else { return }
        store.markFirstRevealCompleted()
    }

    func reset() {
        store.resetFirstReveal()
    }
}

enum ZeroOneLaunchDebugOptions {
    static func shouldResetFirstReveal(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["ZERO_ONE_SPLASH_RESET_FIRST_REVEAL"] == "1"
    }
}

import Foundation

protocol ZeroOneOnboardingProgressPersisting {
    func loadStep() -> Int?
    func saveStep(_ step: Int)
    func clear()
}

/// The profile already persists each answer. This stores only the page to resume
/// after an interrupted first run, without replacing or duplicating those answers.
struct UserDefaultsZeroOneOnboardingProgressStore: ZeroOneOnboardingProgressPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "01.onboarding.currentStep"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func loadStep() -> Int? {
        guard defaults.object(forKey: key) != nil else { return nil }
        let step = defaults.integer(forKey: key)
        guard (-2...9).contains(step) else { return nil }
        return step
    }

    func saveStep(_ step: Int) {
        guard (-2...9).contains(step) else { return }
        defaults.set(step, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// Storage IDs retain the meaning of all pre-migration pages. Page 5 remains
/// readable for an interrupted legacy walkthrough but is not part of new setup.
enum ZeroOneOnboardingFlow {
    static let pages = [-1, 0, 1, 3, 2, 7, 4, 8, 9, 6]

    static func progress(for page: Int) -> ZeroOneSetupProgress? {
        guard let index = pages.firstIndex(of: page) else { return nil }
        return ZeroOneSetupProgress(current: index + 1, total: pages.count)
    }

    static func next(after page: Int) -> Int? {
        if page == -2 { return -1 }
        if page == 5 { return 6 }
        guard let index = pages.firstIndex(of: page), index + 1 < pages.count else { return nil }
        return pages[index + 1]
    }

    static func previous(before page: Int) -> Int? {
        if page == 5 { return 4 }
        guard let index = pages.firstIndex(of: page), index > 0 else { return nil }
        return pages[index - 1]
    }
}

import Combine
import Foundation

/// This device's visual preference only. Never writes the profile, membership,
/// account, shared theme or a public/social card record.
protocol ProfileSettingsYouEditionPersisting {
    func load() throws -> String?
    func save(_ rawValue: String) throws
}

struct UserDefaultsProfileSettingsYouEditionStore: ProfileSettingsYouEditionPersisting {
    let defaults: UserDefaults
    let key: String
    init(defaults: UserDefaults = .standard, key: String = "01.you.cardEdition.v1") {
        self.defaults = defaults
        self.key = key
    }
    func load() throws -> String? {
        guard let value = defaults.object(forKey: key) else { return nil }
        guard let raw = value as? String else { throw CocoaError(.fileReadCorruptFile) }
        return raw
    }
    func save(_ rawValue: String) throws { defaults.set(rawValue, forKey: key) }
}

@MainActor
final class ProfileSettingsYouEditionStore: ObservableObject {
    @Published private(set) var selected: ProfileSettingsYouEdition?
    @Published private(set) var isAvailable = false
    @Published private(set) var saveFailed = false
    private let persistence: any ProfileSettingsYouEditionPersisting

    init(persistence: any ProfileSettingsYouEditionPersisting = UserDefaultsProfileSettingsYouEditionStore()) {
        self.persistence = persistence
        reload()
    }
    func resolved(fallback: ProfileSettingsYouEdition) -> ProfileSettingsYouEdition { selected ?? fallback }

    func reload() {
        do {
            let raw = try persistence.load()
            guard raw == nil || raw.flatMap(ProfileSettingsYouEdition.init(rawValue:)) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            selected = raw.flatMap(ProfileSettingsYouEdition.init(rawValue:))
            isAvailable = true
            saveFailed = false
        } catch {
            selected = nil
            isAvailable = false
            saveFailed = true
        }
    }

    @discardableResult
    func select(_ edition: ProfileSettingsYouEdition) -> Bool {
        guard isAvailable else { return false }
        // Re-read before writing so a changed/corrupt/future value is preserved.
        do {
            let current = try persistence.load()
            guard current == selected?.rawValue else {
                reload()
                return false
            }
            try persistence.save(edition.rawValue)
            guard try persistence.load() == edition.rawValue else {
                saveFailed = true
                return false
            }
            selected = edition
            saveFailed = false
            return true
        } catch {
            saveFailed = true
            return false
        }
    }
}

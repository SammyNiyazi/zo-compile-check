import Foundation

/// UI language only. Never use these display choices as stored workout or content IDs.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case bulgarian = "bg"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    var nativeName: String {
        switch self {
        case .english: "English"
        case .bulgarian: "Български"
        }
    }

    static func supportedLanguage(identifier: String) -> Self? {
        let code = Locale(identifier: identifier).language.languageCode?.identifier.lowercased()
        return code.flatMap(Self.init(rawValue:))
    }
}

enum AppLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case bulgarian

    static let storageKey = "zeroone.languagePreference"
    var id: String { rawValue }

    static func storedValue(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .system
    }

    /// The first device/app preferred language wins. Unsupported first choices
    /// resolve to English rather than silently choosing a lower-priority language.
    func resolvedLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch self {
        case .english: .english
        case .bulgarian: .bulgarian
        case .system: preferredLanguages.first.flatMap(AppLanguage.supportedLanguage(identifier:)) ?? .english
        }
    }
}

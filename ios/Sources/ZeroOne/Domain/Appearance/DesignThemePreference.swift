import Foundation

/// The final design families use their own preference. Legacy theme identifiers
/// remain intact and are not reinterpreted as a different design selection.
enum DesignThemePreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case core
    case retro
    case freak
    case princess

    static let storageKey = "01.designThemePreference"

    static func storedValue(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .core
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .core: "01"
        case .retro: "Retro"
        case .freak: "Freak"
        case .princess: "Princess"
        }
    }

    var designTheme: ZOTheme {
        switch self {
        case .core: .core
        case .retro: .retro
        case .freak: .freak
        case .princess: .princess
        }
    }
}

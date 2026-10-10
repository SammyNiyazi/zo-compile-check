import UIKit

/// Matching app icons (study 30 themes, README decision 35): picking Retro,
/// Freak or Princess also switches to that theme's icon, unless the person turns
/// "Matching app icon" off. iOS shows its own notice when the icon changes.
/// The artwork is the study 30 drawing; Sammy approves the final art (decision 42).
extension DesignThemePreference {
    static let matchingIconKey = "01.matchingAppIcon"

    /// Asset catalog names; listed in ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES.
    var alternateIconName: String? {
        switch self {
        case .core: nil
        case .retro: "AppIcon-Retro"
        case .freak: "AppIcon-Freak"
        case .princess: "AppIcon-Princess"
        }
    }
}

@MainActor
enum ThemeAppIcon {
    static func iconName(for preference: DesignThemePreference, matching: Bool) -> String? {
        matching ? preference.alternateIconName : nil
    }

    /// Sets the icon only when it differs, so iOS never shows its notice for nothing.
    static func apply(_ preference: DesignThemePreference, matching: Bool) async {
        let application = UIApplication.shared
        guard application.supportsAlternateIcons else { return }
        let target = iconName(for: preference, matching: matching)
        guard application.alternateIconName != target else { return }
        try? await application.setAlternateIconName(target)
    }
}

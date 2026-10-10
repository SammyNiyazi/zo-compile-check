import SwiftUI

/// Screen 51 "What's new, after an update": once per version, never on a first
/// install, three changes and a line from Sammy, then "Let's go".
struct WhatsNewItem: Equatable, Identifiable, Sendable {
    let icon: String
    let title: String
    let detail: String
    var id: String { title }
}

struct WhatsNewPresentation: Identifiable {
    let version: String
    let items: [WhatsNewItem]
    var id: String { version }
}

enum WhatsNewCatalog {
    /// Keyed by the marketing version. Add one entry per release that changes
    /// something people will notice; a version without an entry shows nothing.
    static let releases: [String: [WhatsNewItem]] = [
        "0.1.0": [
            WhatsNewItem(icon: "barcode.viewfinder", title: "Log food in seconds",
                detail: "Scan a barcode, search basic foods or photo a label"),
            WhatsNewItem(icon: "person.2", title: "The 01 Club",
                detail: "Your member number, people you follow and Respect"),
            WhatsNewItem(icon: "trophy", title: "New bests, celebrated",
                detail: "Beat every earlier set and 01 marks it")
        ]
    ]

    static func items(for version: String) -> [WhatsNewItem]? { releases[version] }
}

struct WhatsNewPolicy {
    static let lastSeenKey = "01.whatsNew.lastSeenVersion"
    /// Written when setup finishes, so its presence means this is not a first launch.
    static let existingUserKey = "slick.health.setupCompleted"

    /// Whether setup was already finished when this launch began. Captured in
    /// ZeroOneApp.init, before onboarding can write the flag on a fresh install.
    private(set) static var setUpAtLaunch: Bool?

    static func captureLaunchState(defaults: UserDefaults = .standard) {
        setUpAtLaunch = defaults.object(forKey: existingUserKey) != nil
    }

    private let defaults: UserDefaults
    private let version: String
    private let wasSetUpAtLaunch: Bool

    init(defaults: UserDefaults = .standard,
         version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         wasSetUpAtLaunch: Bool? = nil) {
        self.defaults = defaults
        self.version = version
        self.wasSetUpAtLaunch = wasSetUpAtLaunch ?? Self.setUpAtLaunch ?? false
    }

    /// The items to show now, or nil. A first install only records the version.
    func pending() -> (version: String, items: [WhatsNewItem])? {
        let lastSeen = defaults.string(forKey: Self.lastSeenKey)
        guard lastSeen != version else { return nil }
        let isExistingUser = lastSeen != nil || wasSetUpAtLaunch
        guard isExistingUser, let items = WhatsNewCatalog.items(for: version), !items.isEmpty else {
            if !isExistingUser { markSeen() }
            return nil
        }
        return (version, items)
    }

    func markSeen() { defaults.set(version, forKey: Self.lastSeenKey) }
}

struct WhatsNewView: View {
    let version: String
    let items: [WhatsNewItem]
    let onDone: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    Text(localization.format("01, VERSION %1$@", .text(version)))
                        .zoText(.mini).foregroundStyle(theme.textSecondary)
                    Text("What's new").zoThemeHeading(.display, context: .headRowDisplay)
                        .accessibilityAddTraits(.isHeader)
                }
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: ZOSpace.m) {
                            Image(systemName: item.icon).zoIcon(ZOIcon.inline)
                                .frame(width: 32, height: 32)
                                .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ZORadius.small))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(localization.string(item.title)).zoText(.section)
                                Text(localization.string(item.detail)).zoText(.caption).foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, ZOSpace.m)
                        .accessibilityElement(children: .combine)
                        if item.id != items.last?.id { Divider().overlay(theme.strokeSubtle) }
                    }
                }
                HStack(alignment: .top, spacing: ZOSpace.m) {
                    // Sammy's supplied founder portrait (study 30 v1.7): founder notes only, never a card.
                    Image("SammyFounder")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: ZOSpace.xs) {
                        Text("Most of this came from your messages. Keep them coming.").zoText(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        (Text(verbatim: "Sammy").fontWeight(.semibold) + Text(verbatim: " · ") + Text("Founder of 01"))
                            .zoText(.caption).foregroundStyle(theme.textSecondary)
                    }
                }
                .padding(.top, ZOSpace.s)
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, ZOSpace.xl)
        }
        .scrollIndicators(.hidden)
        .background(theme.surfacePrimary)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Let's go", action: onDone)
                .buttonStyle(ZOButtonStyle(.primary))
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.vertical, ZOSpace.m)
                .background(theme.surfacePrimary)
                .accessibilityIdentifier("whatsNew.done")
        }
    }
}

import Foundation

/// Display facts only. No provider, plan, cloud state or version is inferred.
enum ProfileSettingsPresentation {
    static func canDelete(presented: ZeroOneAccountIdentity,
                          current: ZeroOneAccountIdentity?, isBusy: Bool) -> Bool {
        !isBusy && current == presented
    }

    static func matchesSearch(query: String, fields: [String], locale: Locale) -> Bool {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .split(whereSeparator: \.isWhitespace)
        let searchable = fields.joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        return words.allSatisfy { searchable.contains($0) }
    }

    static func accountStatus(hasIdentity: Bool, needsVerification: Bool) -> String {
        guard hasIdentity else { return "No account" }
        return needsVerification ? "Reconnect to verify your session." : "Signed in"
    }

    static func version(version: String?, build: String?) -> String? {
        func resolved(_ input: String?) -> String? {
            guard let value = input?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, !value.contains("$("),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            return value
        }
        guard let version = resolved(version) else { return nil }
        return resolved(build).map { "\(version) (\($0))" } ?? version
    }

    static func membershipStatus(isBeta: Bool, access: MembershipAccess) -> String {
        guard !isBeta else { return "Not available in this beta" }
        switch access {
        case .checking: return "Checking membership"
        case .none: return "No active membership"
        case .trial: return "Trial active"
        case .member: return "Membership active"
        case .gracePeriod, .billingRetry: return "Payment issue"
        case .expired: return "Membership ended"
        case .revoked: return "Membership revoked"
        case .unknown: return "Membership unavailable"
        }
    }
}

enum ProfileSettingsHelpLink: String, CaseIterable, Identifiable {
    case founder, support
    var id: Self { self }
    var title: String { self == .founder ? "Write to Sammy" : "Contact support" }
    var address: String { self == .founder ? "sammy@the01.app" : "hello@the01.app" }
    var url: URL { URL(string: "mailto:\(address)")! }
    var keywords: String { self == .founder ? "help feedback founder sammy email" : "help support email" }
}

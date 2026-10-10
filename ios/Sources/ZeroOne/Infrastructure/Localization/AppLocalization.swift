import Foundation

/// Explicit display lookup for Foundation strings and known static String values.
/// SwiftUI literals use the locale environment and the main bundle's same tables.
/// Do not pass user-entered titles, names, identifiers or persisted facts to this API.
struct AppLocalization: Equatable {
    static let english = AppLocalization(language: .english)
    let language: AppLanguage
    private let sourceBundle: Bundle
    private let selectedBundle: Bundle?
    private let englishBundle: Bundle?

    init(language: AppLanguage, bundle: Bundle = .main) {
        self.language = language
        sourceBundle = bundle
        selectedBundle = Self.languageBundle(language, in: bundle)
        englishBundle = Self.languageBundle(.english, in: bundle)
    }

    var locale: Locale { language.locale }

    enum Argument {
        case text(String)
        case integer(Int)
    }

    /// Positional, typed substitution, never a C vararg format operation. User
    /// arguments remain verbatim even when they contain percent tokens. A bad
    /// translation signature falls back to English; no parameters are logged.
    func format(_ key: String, _ arguments: Argument...) -> String {
        let source = Self.lookup(key, table: "Localizable", in: englishBundle) ?? key
        let translated = string(key)
        let sourceTokens = Self.formatTokens(source)
        if let sourceTokens, let translatedTokens = Self.formatTokens(translated),
           Self.signature(sourceTokens) == Self.signature(translatedTokens),
           let result = Self.render(translated, tokens: translatedTokens, arguments: arguments) {
            return result
        }
        guard let sourceTokens,
              let fallback = Self.render(source, tokens: sourceTokens, arguments: arguments) else { return source }
        return fallback
    }

    private struct FormatToken {
        let range: NSRange
        let position: Int?
        let type: String
    }

    private static func formatTokens(_ format: String) -> [FormatToken]? {
        guard let pattern = try? NSRegularExpression(pattern: #"%(?:([1-9][0-9]*)\$(lld|@)|%)"#) else { return nil }
        let text = format as NSString
        let matches = pattern.matches(in: format, range: NSRange(location: 0, length: text.length))
        var end = 0
        var tokens: [FormatToken] = []
        for match in matches {
            guard !text.substring(with: NSRange(location: end, length: match.range.location - end)).contains("%") else { return nil }
            if match.range(at: 1).location == NSNotFound {
                tokens.append(FormatToken(range: match.range, position: nil, type: "%"))
            } else {
                guard let position = Int(text.substring(with: match.range(at: 1))) else { return nil }
                tokens.append(FormatToken(range: match.range, position: position, type: text.substring(with: match.range(at: 2))))
            }
            end = NSMaxRange(match.range)
        }
        guard !text.substring(from: end).contains("%") else { return nil }
        return tokens
    }

    private static func signature(_ tokens: [FormatToken]) -> [String] {
        tokens.compactMap { token in token.position.map { "\($0):\(token.type)" } }.sorted()
    }

    private static func render(_ format: String, tokens: [FormatToken], arguments: [Argument]) -> String? {
        let positions = Set(tokens.compactMap(\.position))
        guard positions == Set(arguments.indices.map { $0 + 1 }) else { return nil }
        let text = format as NSString
        var end = 0
        var result = ""
        for token in tokens {
            result += text.substring(with: NSRange(location: end, length: token.range.location - end))
            if let position = token.position {
                switch (token.type, arguments[position - 1]) {
                case let ("@", .text(value)): result += value
                case let ("lld", .integer(value)): result += NSNumber(value: value).stringValue
                default: return nil
                }
            } else { result += "%" }
            end = NSMaxRange(token.range)
        }
        return result + text.substring(from: end)
    }

    /// Missing translated keys use English, then the supplied source fallback/key.
    /// Lookup never delegates to the process's unrelated preferred bundle language.
    func string(_ key: String, table: String = "Localizable", fallback: String? = nil) -> String {
        Self.lookup(key, table: table, in: selectedBundle)
            ?? Self.lookup(key, table: table, in: englishBundle)
            ?? fallback ?? key
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.language == rhs.language && lhs.sourceBundle.bundleURL == rhs.sourceBundle.bundleURL
    }

    private static func languageBundle(_ language: AppLanguage, in bundle: Bundle) -> Bundle? {
        guard let url = bundle.url(forResource: language.rawValue, withExtension: "lproj") else { return nil }
        return Bundle(url: url)
    }

    private static func lookup(_ key: String, table: String, in bundle: Bundle?) -> String? {
        guard let bundle else { return nil }
        let missing = "\u{E000}01.localization.missing\u{E001}" // private-use sentinel; Swift rejects noncharacters
        let value = bundle.localizedString(forKey: key, value: missing, table: table)
        return value == missing ? nil : value
    }
}

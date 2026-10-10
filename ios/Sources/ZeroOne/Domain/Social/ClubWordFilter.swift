import Foundation

/// Proof 50, App Review 1.2: a public line with clearly abusive words is held
/// before it is posted. The person can edit it. Nothing is silently changed or
/// deleted, and ordinary training talk ("killer workout", "brutal legs") passes.
/// English and Bulgarian, with simple leetspeak and stretched letters folded.
enum ClubWordFilter {
    /// Matched as the start of a word: "fuck" also catches "fucking".
    private static let stems = [
        "fuck", "motherfuck", "cunt", "bitch", "whore", "slut", "asshole", "dickhead", "bastard",
        "retard", "faggot", "nigger", "nigga", "wanker", "twat", "tranny",
        "путк", "курв", "педераст", "шибан", "копеле", "ебан", "ебах", "мамицат",
        "pederast", "shiban", "kopele"
    ]
    /// Whole words only, because they are short or start ordinary words.
    private static let words: Set<String> = [
        "fag", "kike", "spic", "chink", "prick", "kys",
        "еба", "еби", "eba", "ebi", "kurva", "kurvi", "putka", "putki"
    ]
    private static let phrases = [
        "kill yourself", "мамка ти", "да ти еба", "майка ти да еба", "mamka ti"
    ]
    private static let leet: [Character: Character] = [
        "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "!": "i", "|": "i"
    ]

    /// Lowercase, accents folded, leetspeak mapped, separators inside a word removed.
    static func normalize(_ token: String) -> String {
        let folded = token.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        return String(folded.compactMap { character -> Character? in
            if let mapped = leet[character] { return mapped }
            return character.isLetter ? character : nil
        })
    }

    /// "fuuuuck" → "fuck", "asssshole" → "ashole" (compared both ways).
    private static func squeezed(_ value: String) -> String {
        var result = ""
        for character in value where result.last != character { result.append(character) }
        return result
    }

    static func isAbusive(token: String) -> Bool {
        let word = normalize(token)
        guard word.count >= 2 else { return false }
        let short = squeezed(word)
        if words.contains(word) || words.contains(short) { return true }
        return stems.contains { word.hasPrefix($0) || short.hasPrefix(squeezed($0)) }
    }

    /// The ranges of the words that hold a line, in the original text.
    static func flaggedRanges(in text: String) -> [Range<String.Index>] {
        guard let pattern = try? NSRegularExpression(pattern: #"[^\s,.;:?"'()]+"#) else { return [] }
        let all = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: all).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return isAbusive(token: String(text[range])) ? range : nil
        }
    }

    static func isClean(_ text: String) -> Bool {
        guard flaggedRanges(in: text).isEmpty else { return false }
        let line = " " + text.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }
            .filter { !$0.isEmpty }.joined(separator: " ") + " "
        return !phrases.contains { line.contains(" " + $0 + " ") }
    }

    /// The held line as the proof shows it: abusive words become ****.
    static func masked(_ text: String) -> String {
        var result = text
        for range in flaggedRanges(in: text).reversed() {
            result.replaceSubrange(range, with: String(repeating: "*", count: 4))
        }
        return result
    }
}

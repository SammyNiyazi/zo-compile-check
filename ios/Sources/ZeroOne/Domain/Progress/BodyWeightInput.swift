import Foundation

/// Whole-input decimal parsing for manual readings, never a numeric prefix.
/// Dot/comma (and Arabic decimal separator) are decimals, not group separators.
enum BodyWeightInput {
    static func number(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else { return nil }
        var normalized = ""
        var hasSeparator = false
        var digits = 0
        for character in trimmed {
            if character == "." || character == "," || character == "٫" {
                guard !hasSeparator else { return nil }
                hasSeparator = true
                normalized += normalized.isEmpty ? "0." : "."
            } else {
                guard character.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }),
                      let digit = character.wholeNumberValue, (0...9).contains(digit) else { return nil }
                normalized += String(digit)
                digits += 1
            }
        }
        guard digits > 0, normalized.last != ".",
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              NSDecimalNumber(decimal: value).doubleValue.isFinite else { return nil }
        return value
    }

    static func kilograms(_ text: String, unit: BodyWeightUnit) -> Decimal? {
        guard let value = number(text) else { return nil }
        let kilograms = unit.kilograms(from: value)
        let numeric = NSDecimalNumber(decimal: kilograms).doubleValue
        return numeric.isFinite && (0.5...1_000).contains(numeric) ? kilograms : nil
    }
}

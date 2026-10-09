import Foundation

struct BodyHeightMeasurement: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case manual, appleHealth }
    let centimeters: Double
    let recordedAt: Date
    let source: Source

    var isValid: Bool {
        centimeters.isFinite && (20...300).contains(centimeters)
            && recordedAt.timeIntervalSinceReferenceDate.isFinite
    }

    static func centimeters(from input: String, imperial: Bool) -> Double? {
        guard let decimal = BodyWeightInput.number(input) else { return nil }
        let displayed = NSDecimalNumber(decimal: decimal).doubleValue
        let centimeters = imperial ? displayed * 30.48 : displayed
        guard centimeters.isFinite, (20...300).contains(centimeters) else { return nil }
        return centimeters
    }

    /// Imperial height is entered the way people say it: whole feet plus
    /// inches below 12. Either field may be blank (read as zero), not both.
    static func centimeters(feet: String, inches: String) -> Double? {
        let feet = feet.trimmingCharacters(in: .whitespacesAndNewlines)
        let inches = inches.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feet.isEmpty || !inches.isEmpty else { return nil }
        func parsed(_ text: String) -> Double? {
            if text.isEmpty { return 0 }
            guard let decimal = BodyWeightInput.number(text) else { return nil }
            return NSDecimalNumber(decimal: decimal).doubleValue
        }
        guard let wholeFeet = parsed(feet), wholeFeet == wholeFeet.rounded(),
              let inchPart = parsed(inches), inchPart >= 0, inchPart < 12 else { return nil }
        let centimeters = (wholeFeet * 12 + inchPart) * 2.54
        guard centimeters.isFinite, (20...300).contains(centimeters) else { return nil }
        return centimeters
    }

    /// Nearest whole inch, split into feet and inches (5 ft 10 in, never 5 ft 12 in).
    var feetAndInches: (feet: Int, inches: Int) {
        let totalInches = Int((centimeters / 2.54).rounded())
        return (totalInches / 12, totalInches % 12)
    }

    func displayValue(imperial: Bool) -> String {
        String(format: imperial ? "%.3f" : "%.1f", imperial ? centimeters / 30.48 : centimeters)
    }
}

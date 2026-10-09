import Foundation

struct LocalAssistantIntentParser: AssistantIntentParser {
    func parse(_ transcript: String, now: Date = .now) -> AssistantParseResult {
        let normalized = normalizedTranscript(transcript)
        guard !normalized.isEmpty else { return .unknown }

        if let workoutSet = parseWorkoutSet(normalized, source: transcript) {
            return .intent(workoutSet)
        }

        if let hydration = parseHydration(normalized, source: transcript, now: now) {
            return hydration
        }

        if let availableTime = parseAvailableTime(normalized, source: transcript) {
            return .intent(availableTime)
        }

        if let sleep = parseSleep(normalized, source: transcript, now: now) {
            return .intent(sleep)
        }

        if normalized.contains("shoulder") && containsAny(normalized, ["off", "sore", "hurts", "pain"]) {
            return .intent(
                ParsedAssistantIntent(
                    action: .reportSoreness(area: "shoulder", severity: .mild, date: now),
                    confidence: 0.78,
                    sourceTranscript: transcript
                )
            )
        }

        if containsAny(normalized, ["skipping the gym", "skip the gym", "not training today"]) {
            return .intent(
                ParsedAssistantIntent(
                    action: .skipWorkout(date: now),
                    confidence: 0.94,
                    sourceTranscript: transcript
                )
            )
        }

        if containsAny(normalized, ["start my workout", "start workout"]) {
            return .intent(
                ParsedAssistantIntent(
                    action: .startWorkout,
                    confidence: 0.97,
                    sourceTranscript: transcript
                )
            )
        }

        return .unknown
    }

    private func parseHydration(
        _ transcript: String,
        source: String,
        now: Date
    ) -> AssistantParseResult? {
        let hydrationWords = ["drink", "drank", "water", "hydration", "litre", "liter", "millilitre", "milliliter", " ml"]
        guard containsAny(transcript, hydrationWords) else { return nil }

        let unitPattern = #"([0-9]+(?:\.[0-9]+)?)\s*(litres?|liters?|l|millilitres?|milliliters?|ml)\b"#
        guard let match = firstMatch(in: transcript, pattern: unitPattern),
              let amount = Double(match[1]) else {
            if firstMatch(in: transcript, pattern: #"\b[0-9]+(?:\.[0-9]+)?\b"#) != nil {
                return .clarification(question: "Glasses or litres?")
            }
            return .clarification(question: "How much water?")
        }

        let unit = match[2]
        let milliliters = unit.hasPrefix("l") && unit != "ml"
            ? Int((amount * 1_000).rounded())
            : Int(amount.rounded())
        let isSet = containsAny(transcript, ["set hydration", "set water", "total today", "had in total"])
        let action: AssistantAction = isSet
            ? .setHydration(milliliters: milliliters, date: now)
            : .addHydration(milliliters: milliliters, date: now)

        return .intent(
            ParsedAssistantIntent(
                action: action,
                confidence: 0.98,
                sourceTranscript: source
            )
        )
    }

    private func parseAvailableTime(_ transcript: String, source: String) -> ParsedAssistantIntent? {
        guard containsAny(transcript, ["train", "workout", "gym"]),
              let match = firstMatch(
                in: transcript,
                pattern: #"([0-9]+)\s*(minutes?|mins?)\b"#
              ),
              let minutes = Int(match[1]) else {
            return nil
        }

        return ParsedAssistantIntent(
            action: .updateAvailableTime(minutes: minutes),
            confidence: 0.96,
            sourceTranscript: source
        )
    }

    private func parseWorkoutSet(_ transcript: String, source: String) -> ParsedAssistantIntent? {
        guard let loadMatch = firstMatch(
            in: transcript,
            pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(kilograms?|kilos?|kg|pounds?|lbs?)\b"#
        ),
        let loadValue = Double(loadMatch[1]),
        let repsMatch = firstMatch(in: transcript, pattern: #"([0-9]+)\s*reps?\b"#),
        let reps = Int(repsMatch[1]) else {
            return nil
        }

        let unit: LoadUnit = loadMatch[2].hasPrefix("p") || loadMatch[2].hasPrefix("lb")
            ? .pounds
            : .kilograms
        let rirMatch = firstMatch(
            in: transcript,
            pattern: #"(?:rir\s*([0-9]+)|([0-9]+)\s*rir|([0-9]+)\s*reps?\s*(?:in reserve|left))"#
        )
        let rir = rirMatch.flatMap { groups in
            groups.dropFirst().compactMap(Int.init).first
        }

        return ParsedAssistantIntent(
            action: .logWorkoutSet(
                load: Load(loadValue, unit: unit),
                reps: reps,
                rir: rir
            ),
            confidence: 0.96,
            sourceTranscript: source
        )
    }

    private func parseSleep(_ transcript: String, source: String, now: Date) -> ParsedAssistantIntent? {
        guard containsAny(transcript, ["slept", "sleep"]),
              let match = firstMatch(
                in: transcript,
                pattern: #"([0-9]+(?:\.[0-9]+)?)\s*hours?\b"#
              ),
              let hours = Double(match[1]) else {
            return nil
        }

        return ParsedAssistantIntent(
            action: .reportSleep(hours: hours, date: now),
            confidence: 0.92,
            sourceTranscript: source
        )
    }

    private func normalizedTranscript(_ transcript: String) -> String {
        let replacements = [
            "a litre": "1 litre",
            "a liter": "1 liter",
            "one": "1",
            "two": "2",
            "three": "3",
            "four": "4",
            "five": "5",
            "six": "6",
            "seven": "7",
            "eight": "8",
            "nine": "9",
            "ten": "10"
        ]

        return replacements.reduce(
            transcript.lowercased().replacingOccurrences(of: ",", with: ".")
        ) { partial, replacement in
            partial.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: replacement.key))\\b",
                with: replacement.value,
                options: .regularExpression
            )
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.contains($0) }
    }

    private func firstMatch(in value: String, pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = expression.firstMatch(in: value, range: range) else { return nil }

        return (0 ..< match.numberOfRanges).map { index in
            let matchRange = match.range(at: index)
            guard matchRange.location != NSNotFound,
                  let range = Range(matchRange, in: value) else { return "" }
            return String(value[range])
        }
    }
}

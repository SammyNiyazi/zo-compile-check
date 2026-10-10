import Foundation

/// Proof 26 "Let go anywhere else: it acts". Only clear, local requests act at
/// once: adding water (with Undo), starting today's workout, or opening a place.
/// Anything else opens the options sheet with the words already in it.
enum VoiceQuickIntent: Equatable {
    enum Destination: Equatable { case diets, logFood, workoutLibrary, steps, history, music, walk }

    case addWater(milliliters: Int)
    case startWorkout
    case open(Destination)

    static func match(_ transcript: String, now: Date = .now) -> VoiceQuickIntent? {
        let text = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if case let .intent(intent) = LocalAssistantIntentParser().parse(transcript, now: now), intent.confidence >= 0.85 {
            switch intent.action {
            case let .addHydration(milliliters, _) where (50 ... 2_000).contains(milliliters):
                return .addWater(milliliters: milliliters)
            case .startWorkout:
                return .startWorkout
            default:
                break
            }
        }
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        let opening = has(["open", "show", "go to", "take me to", "отвори", "покажи"])
        if has(["log food", "log a meal", "log my meal", "add food", "add a meal", "scan a barcode", "запиши храна", "добави храна"]) {
            return .open(.logFood)
        }
        if opening, has(["diet", "nutrition", "meals", "food", "храни", "диет"]) { return .open(.diets) }
        if opening, has(["workout library", "my workouts", "plans", "тренировки"]) { return .open(.workoutLibrary) }
        if opening, has(["steps", "крачки"]) { return .open(.steps) }
        if opening, has(["history", "история"]) { return .open(.history) }
        if opening || has(["play music", "put on music"]), has(["music", "музика"]) { return .open(.music) }
        if has(["start a walk", "start walk", "go for a walk", "start a run", "start run", "go for a run", "разходка", "бягане"]) {
            return .open(.walk)
        }
        return nil
    }
}

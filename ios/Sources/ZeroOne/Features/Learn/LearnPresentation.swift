import Foundation

/// When Learn has a lesson for the moment around a workout. This is the rule
/// Today already applied, moved here unchanged so Today and Learn home agree:
/// a warm-up lesson before a planned workout, a progression lesson after a
/// saved one, and nothing during a workout. It reads only the workout state
/// 01 already has; no Health, location or other app data.
enum LearnWorkoutMoment: Equatable {
    case beforeWorkout
    case afterWorkout

    static func current(hasPlannedWorkout: Bool, workoutCompleted: Bool,
                        workoutInProgress: Bool) -> LearnWorkoutMoment? {
        if workoutInProgress { return nil }
        if workoutCompleted { return .afterWorkout }
        if hasPlannedWorkout { return .beforeWorkout }
        return nil
    }

    /// The bundled lesson for this moment, as before.
    var lessonID: String {
        switch self {
        case .beforeWorkout: "warmup-basics"
        case .afterWorkout: "progression-basics"
        }
    }

    /// The card's eyebrow. The proof's "Before Thursday's workout" needs a
    /// scheduled day this view does not have, so it names the moment only.
    var eyebrow: String {
        switch self {
        case .beforeWorkout: "Before your next workout"
        case .afterWorkout: "After your saved workout"
        }
    }
}

/// Proof 44's four-segment evidence meter. The bundled lessons carry an
/// evidence *kind* (public guidance, research summary, how 01 works), not a
/// graded certainty, so no kind draws a numeric meter: it shows "not graded"
/// rather than inventing how sure a source is. A future graded level would
/// map here explicitly.
enum LearnEvidenceMeter {
    static let segmentCount = 4

    /// Ungraded is a separate display state, not a grade of zero.
    enum Presentation: Equatable {
        case ungraded
        case graded(filledSegments: Int)
    }

    static func presentation(for evidence: LearnEvidence) -> Presentation {
        filledSegments(for: evidence).map { .graded(filledSegments: $0) } ?? .ungraded
    }

    /// Used by the standalone meter and the row's overriding VoiceOver label.
    static func accessibilityDescription(for evidence: LearnEvidence, localization: AppLocalization) -> String {
        switch presentation(for: evidence) {
        case .ungraded:
            localization.string("Evidence strength not graded")
        case let .graded(filled):
            localization.format("Evidence %1$lld of %2$lld", .integer(filled), .integer(segmentCount))
        }
    }

    /// Filled segments for a known grade, or nil when the strength is not
    /// graded. Every current kind is explicitly ungraded.
    static func filledSegments(for evidence: LearnEvidence) -> Int? {
        switch evidence {
        case .publicGuidance: nil
        case .researchSummary: nil
        case .how01Works: nil
        }
    }
}

/// Lesson row and header facts.
enum LearnLessonPresentation {
    /// "Warm-up · 2 min", the proof's topic and time line.
    static func topicLine(topic: String, minutes: String) -> String {
        "\(topic) · \(minutes)"
    }

    /// The lessons a filter shows: saved ones only, one topic, a search, or all.
    /// Unchanged from Learn home's existing filter.
    static func lessons(_ lessons: [LearnLesson], topic: LearnTopic?, savedOnly: Bool,
                        savedIDs: Set<String>, search: String) -> [LearnLesson] {
        lessons.filter { lesson in
            (!savedOnly || savedIDs.contains(lesson.id))
                && (topic == nil || topic == lesson.topic)
                && (search.isEmpty || "\(lesson.title) \(lesson.dek) \(lesson.topic.title)".localizedStandardContains(search))
        }
    }
}

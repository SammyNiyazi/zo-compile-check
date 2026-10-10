import Foundation
import Observation

enum LearnTopic: String, CaseIterable, Codable, Hashable, Identifiable {
    case technique, warmup, recovery, progression, habits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .technique: "Strength technique"
        case .warmup: "Warm-up"
        case .recovery: "Recovery"
        case .progression: "Progression"
        case .habits: "Safe habits"
        }
    }

    var subtitle: String {
        switch self {
        case .technique: "Set-up and control"
        case .warmup: "Getting ready to lift"
        case .recovery: "Room between sessions"
        case .progression: "Building a repeatable plan"
        case .habits: "Starting and stopping safely"
        }
    }

    var symbol: String {
        switch self {
        case .technique: "figure.strengthtraining.traditional"
        case .warmup: "figure.walk"
        case .recovery: "moon.stars"
        case .progression: "chart.line.uptrend.xyaxis"
        case .habits: "shield.lefthalf.filled"
        }
    }
}

enum LearnEvidence: String, Codable {
    case publicGuidance, researchSummary, how01Works

    var title: String {
        switch self {
        case .publicGuidance: "Public health guidance"
        case .researchSummary: "Research summary"
        case .how01Works: "How 01 works"
        }
    }

    var explanation: String {
        switch self {
        case .publicGuidance:
            "This lesson summarizes guidance from a named public health body. The source is linked below. 01 has not commissioned an independent clinical review."
        case .researchSummary:
            "This lesson summarizes a named research body. The source is linked below. It has not been independently reviewed for 01."
        case .how01Works:
            "This describes a rule or choice in 01. It is a product explanation, not a claim that a study recommends this exact action."
        }
    }
}

struct LearnSource: Identifiable {
    let title: String
    let organization: String
    let url: URL
    let supports: String
    var id: String { url.absoluteString }
}

struct LearnQuestion: Identifiable {
    let id: String
    let title: String
    let answer: String
}

struct LearnStep: Identifiable {
    let id: String
    let title: String
    let detail: String
}

struct LearnLesson: Identifiable {
    let id: String
    let topic: LearnTopic
    let title: String
    let dek: String
    let minutes: Int
    let evidence: LearnEvidence
    let shortVersion: String
    let steps: [LearnStep]
    let questions: [LearnQuestion]
    let settled: String
    let open: String
    let safety: String
    let sources: [LearnSource]

    var isValid: Bool {
        !id.isEmpty && !title.isEmpty && !dek.isEmpty && minutes > 0
            && !shortVersion.isEmpty && !steps.isEmpty && !questions.isEmpty
            && !settled.isEmpty && !open.isEmpty && !safety.isEmpty
            && !sources.isEmpty && sources.allSatisfy {
                $0.url.scheme == "https" && !$0.title.isEmpty && !$0.supports.isEmpty
            }
    }
}

enum LearnCatalog {
    // Source pages checked on 27 September 2026. These are attributed summaries,
    // not the fictional authored/reviewed articles in Study 27's visual prototype.
    static let lessons: [LearnLesson] = [
        LearnLesson(
            id: "warmup-basics", topic: .warmup,
            title: "Give your workout a gentle start",
            dek: "A short warm-up prepares you for harder activity.", minutes: 2,
            evidence: .publicGuidance,
            shortVersion: "Begin with easy movement before the harder part of your session. Use the warm-up already in your workout plan, and choose the shorter option when time is tight.",
            steps: [
                .init(id: "move", title: "Move easily first", detail: "Walk, cycle gently or use another comfortable movement. The aim is to begin gradually."),
                .init(id: "plan", title: "Check your workout's warm-up", detail: "01 keeps preparation separate from working sets. You can mark its steps done or skip them in the workout."),
                .init(id: "start", title: "Start when ready", detail: "A warm-up is preparation, not a performance test.")
            ],
            questions: [
                .init(id: "why", title: "Why warm up?", answer: "NHS guidance recommends warming up before more rigorous exercise and says it can reduce injury risk."),
                .init(id: "exact", title: "Does the source prescribe 01's exact steps?", answer: "No. The NHS source supports warming up in general. The steps shown in your workout are 01's training plan, not a prescribed NHS protocol.")
            ],
            settled: "The NHS recommends a warm-up before more rigorous exercise.",
            open: "The linked guidance does not establish one exact warm-up for every lift or person.",
            safety: "If you have an injury, health condition or symptoms, ask a qualified professional what is suitable. Stop if exercise causes pain or you feel unwell.",
            sources: [.init(title: "Body warm-up video", organization: "NHS", url: URL(string: "https://www.nhs.uk/live-well/exercise/strength-and-resistance/body-blast-warm-up/")!, supports: "Warming up before rigorous exercise and when to seek advice")]
        ),
        LearnLesson(
            id: "strength-week", topic: .habits,
            title: "Make strength work a regular part of your week",
            dek: "Public guidance is about a pattern across the week, not one perfect session.", minutes: 2,
            evidence: .publicGuidance,
            shortVersion: "Adults are advised to do muscle-strengthening activities for the major muscle groups on at least two days each week. Your plan can spread those days in a way you can repeat.",
            steps: [
                .init(id: "see", title: "See your planned days", detail: "Look at your week in 01 before adding another session."),
                .init(id: "cover", title: "Think across the body", detail: "The guidance covers the major muscle groups, not only the lift you enjoy most."),
                .init(id: "repeat", title: "Prefer a repeatable rhythm", detail: "A smaller plan you can keep is a useful place to begin.")
            ],
            questions: [.init(id: "two", title: "Must the days be consecutive?", answer: "The WHO guidance gives a weekly frequency. It does not require consecutive days in the source linked here.")],
            settled: "WHO guidance recommends muscle-strengthening activity for major muscle groups on two or more days per week for adults.",
            open: "The best schedule and exercise selection depend on your circumstances.",
            safety: "This is general adult guidance. If you have a condition or limitation, seek individualized advice from a qualified professional.",
            sources: [.init(title: "Physical activity", organization: "World Health Organization", url: URL(string: "https://www.who.int/europe/news-room/fact-sheets/item/physical-activity")!, supports: "Adult muscle-strengthening frequency and major muscle groups")]
        ),
        LearnLesson(
            id: "progression-basics", topic: .progression,
            title: "Consistency comes before fine-tuning",
            dek: "A useful plan starts with showing up and practicing the movements.", minutes: 3,
            evidence: .researchSummary,
            shortVersion: "ACSM's 2026 resistance-training summary puts regular participation and a plan you can sustain ahead of complicated optimization. 01 shows load changes as choices rather than automatic jumps.",
            steps: [
                .init(id: "review", title: "Review the last session", detail: "Look at the recorded reps and loads before deciding what to do next."),
                .init(id: "choose", title: "Choose a manageable next step", detail: "Keep or change the suggested load in the workout. The choice remains yours."),
                .init(id: "record", title: "Record what happened", detail: "Your next decision should use the actual session, including any lighter or missed sets.")
            ],
            questions: [.init(id: "auto", title: "Will Learn change my load?", answer: "No. Learn never changes your target load. Review any workout suggestion in the workout itself before accepting it.")],
            settled: "Resistance training improves strength and physical performance; ACSM emphasizes participating consistently.",
            open: "The right load increment for one person cannot be inferred from this summary alone.",
            safety: "Do not increase a load just to satisfy a target if the movement or effort no longer feels manageable.",
            sources: [.init(title: "ACSM publishes updated resistance training guidelines", organization: "American College of Sports Medicine", url: URL(string: "https://acsm.org/resistance-training-guidelines-update-2026/")!, supports: "2026 position stand summary and practical emphasis on consistency")]
        ),
        LearnLesson(
            id: "technique-basics", topic: .technique,
            title: "Use the first set to check control",
            dek: "Technique is a repeatable setup and movement you can manage.", minutes: 2,
            evidence: .how01Works,
            shortVersion: "01 keeps exercise instructions next to the active workout. Use the exercise detail before starting a set, then adjust or stop if the movement does not feel manageable.",
            steps: [
                .init(id: "open", title: "Open exercise detail", detail: "Check the instructions attached to the exercise you are about to do."),
                .init(id: "rehearse", title: "Try a lighter rehearsal", detail: "Use your workout's warm-up if one is planned."),
                .init(id: "decide", title: "Choose the working load", detail: "The workout lets you adjust load and reps before logging the set.")
            ],
            questions: [.init(id: "video", title: "Is every exercise video available?", answer: "No. Some exercises may show a still image or text. Media availability does not change your workout record.")],
            settled: "01 separates preparation from working-set History and lets you adjust the set before completion.",
            open: "An app cannot judge your form or diagnose the reason for pain.",
            safety: "If a movement hurts or you feel unwell, stop. Seek qualified advice for symptoms or an injury.",
            sources: [.init(title: "Exercise and your health: a guide to getting started", organization: "Newcastle Hospitals NHS Foundation Trust", url: URL(string: "https://www.newcastle-hospitals.nhs.uk/services/newcastle-occupational-health-service/information-for-staff/physiotherapy/self-help-leaflets/exercise-and-your-health-a-guide-to-getting-started/")!, supports: "General preparation and adjusting exercise to ability")]
        ),
        LearnLesson(
            id: "recovery-rhythm", topic: .recovery,
            title: "Recovery belongs in the weekly plan",
            dek: "Your week includes the spaces between strength sessions.", minutes: 2,
            evidence: .how01Works,
            shortVersion: "Use your weekly plan to see training days together. 01 does not count a planned day without a workout as a failed session.",
            steps: [
                .init(id: "week", title: "Look at the whole week", detail: "Check which days already have strength sessions."),
                .init(id: "space", title: "Leave room for the rest of life", detail: "Adjust your schedule when time or energy changes."),
                .init(id: "return", title: "Return to the next session", detail: "A missed day does not erase what you have already completed.")
            ],
            questions: [.init(id: "rest", title: "Does 01 prescribe a fixed rest day?", answer: "No. The weekly guidance names a frequency for strength work; it does not prescribe a specific rest day for you.")],
            settled: "The public guideline describes strength activity across the week.",
            open: "This lesson cannot determine your personal recovery needs.",
            safety: "Persistent fatigue, pain or other concerning symptoms deserve individual professional advice.",
            sources: [.init(title: "Adult activity: an overview", organization: "US Centers for Disease Control and Prevention", url: URL(string: "https://www.cdc.gov/physical-activity-basics/guidelines/adults.html")!, supports: "Weekly muscle-strengthening guidance")]
        )
    ].filter(\.isValid)

    static func lesson(_ id: String) -> LearnLesson? { lessons.first { $0.id == id } }
}

struct LearnUserState: Codable {
    var savedIDs: Set<String> = []
    var hiddenCardDay: String? = nil
    var deliveredCardDay: String? = nil
    var deliveredCardID: String? = nil
    var cardsOnToday = true
    var fewerTopics: Set<LearnTopic> = []
    var answeredQuestionIDs: Set<String> = []
    var helpfulLessonIDs: Set<String> = []
}

@MainActor @Observable
final class LearnRepository {
    private(set) var state: LearnUserState
    private(set) var errorMessage: String? = nil
    private(set) var loadFailed = false
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let resolvedURL = base.appendingPathComponent("01-learn-state.json")
        fileURL = resolvedURL
        if FileManager.default.fileExists(atPath: resolvedURL.path) {
            do {
                state = try JSONDecoder().decode(LearnUserState.self, from: Data(contentsOf: resolvedURL))
            } catch {
                state = LearnUserState()
                loadFailed = true
                errorMessage = "Your Learn choices could not be loaded. Changes are unavailable until this is resolved."
            }
        } else {
            state = LearnUserState()
        }
    }

    var canChange: Bool { !loadFailed && errorMessage == nil }

    func clearError() { errorMessage = nil }

    func update(_ transform: (inout LearnUserState) -> Void) {
        guard canChange else { return }
        var next = state
        transform(&next)
        do {
            let data = try JSONEncoder().encode(next)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            state = next
        } catch {
            errorMessage = "Learn could not save this change. Try again after device storage is available."
        }
    }

    func isSaved(_ lesson: LearnLesson) -> Bool { state.savedIDs.contains(lesson.id) }

    func toggleSaved(_ lesson: LearnLesson) {
        update { if !$0.savedIDs.insert(lesson.id).inserted { $0.savedIDs.remove(lesson.id) } }
    }

    func hideCardForToday(now: Date = .now) {
        let day = Self.dayKey(now)
        update { $0.hiddenCardDay = day }
    }

    func undoHideCard() { update { $0.hiddenCardDay = nil } }

    func claimCard(_ lesson: LearnLesson, now: Date = .now) {
        guard state.cardsOnToday, !state.fewerTopics.contains(lesson.topic) else { return }
        let day = Self.dayKey(now)
        guard state.deliveredCardDay != day else { return }
        update {
            $0.deliveredCardDay = day
            $0.deliveredCardID = lesson.id
        }
    }

    func cardIsVisible(_ lesson: LearnLesson, now: Date = .now) -> Bool {
        state.cardsOnToday && !state.fewerTopics.contains(lesson.topic)
            && state.deliveredCardDay == Self.dayKey(now)
            && state.deliveredCardID == lesson.id
            && state.hiddenCardDay != Self.dayKey(now)
    }

    func cardIsHiddenToday(now: Date = .now) -> Bool {
        state.hiddenCardDay == Self.dayKey(now)
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}

import Foundation

/// Value-only presentation boundary. The root supplies current, acknowledged facts.
/// A successful initializer validates shape; it does not verify a provider or grant access.
enum ProfileSettingsYouEdition: String, CaseIterable, Identifiable, Sendable {
    case onyx, pink, chrome, neon
    var id: Self { self }
    var title: String {
        switch self {
        case .onyx: "Onyx"
        case .pink: "Pink pearl"
        case .chrome: "Black chrome"
        case .neon: "Neon"
        }
    }
    var themeTitle: String {
        switch self {
        case .onyx: "Default"
        case .pink: "Princess theme"
        case .chrome: "Freak theme"
        case .neon: "Retro theme"
        }
    }
}

struct ProfileSettingsYouVerifiedCard: Equatable, Sendable {
    enum Recognition: Equatable, Sendable {
        case founder, foundingMember, partner(tier: Int)
    }
    let number: String
    let holderName: String
    let since: Date?
    let crew: String?
    let workouts: Int?
    let consecutiveWeeks: Int?
    let personalBests: Int?
    let recognition: Recognition?
    let hasFounderSticker: Bool

    init?(number: String, holderName: String, since: Date? = nil, crew: String? = nil,
          workouts: Int? = nil, consecutiveWeeks: Int? = nil, personalBests: Int? = nil,
          recognition: Recognition? = nil, hasFounderSticker: Bool = false) {
        guard !number.isEmpty, number.count <= 8,
              number.utf8.allSatisfy({ (48...57).contains($0) }),
              let numeric = Int(number), (1...0xFFFFFF).contains(numeric),
              let name = ProfileSettingsYouPresentation.cleanText(holderName),
              since.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else { return nil }
        // Labels are independent verified inputs, never inferred from the number/name.
        switch recognition {
        case .founder: guard numeric == 1 else { return nil }
        case .foundingMember: guard (2...1001).contains(numeric) else { return nil }
        case let .partner(tier): guard (1...4).contains(tier) else { return nil }
        case nil: break
        }
        guard !hasFounderSticker || (numeric == 1 && recognition == .founder) else { return nil }
        self.number = number
        self.holderName = name
        self.since = since
        self.crew = ProfileSettingsYouPresentation.cleanText(crew)
        self.workouts = ProfileSettingsYouPresentation.nonnegative(workouts)
        self.consecutiveWeeks = ProfileSettingsYouPresentation.nonnegative(consecutiveWeeks)
        self.personalBests = ProfileSettingsYouPresentation.nonnegative(personalBests)
        self.recognition = recognition
        self.hasFounderSticker = hasFounderSticker
    }
}

struct ProfileSettingsYouMonth: Equatable, Sendable {
    enum Scope: Equatable, Sendable { case recordedHistory, verifiedMemberActivity }
    struct Goal: Equatable, Sendable {
        let completed: Int
        let target: Int
        init?(completed: Int, target: Int) {
            guard completed >= 0, target > 0 else { return nil }
            self.completed = completed
            self.target = target
        }
    }
    let start: Date
    let end: Date
    let asOf: Date
    let calendar: Calendar
    let scope: Scope
    let workouts: Int?
    let respectsReceived: Int?
    let newBests: Int?
    let goal: Goal?

    init?(start: Date, end: Date, asOf: Date, calendar: Calendar, scope: Scope, workouts: Int? = nil,
          respectsReceived: Int? = nil, newBests: Int? = nil, goal: Goal? = nil) {
        guard [start, end, asOf].allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }),
              start < end, asOf >= start, asOf < end,
              let month = calendar.dateInterval(of: .month, for: asOf),
              start == month.start, end == month.end else { return nil }
        self.start = start
        self.end = end
        self.asOf = asOf
        self.calendar = calendar
        self.scope = scope
        self.workouts = ProfileSettingsYouPresentation.nonnegative(workouts)
        // An incomplete local workout history establishes neither social respects nor bests.
        self.respectsReceived = scope == .verifiedMemberActivity
            ? ProfileSettingsYouPresentation.nonnegative(respectsReceived) : nil
        self.newBests = scope == .verifiedMemberActivity
            ? ProfileSettingsYouPresentation.nonnegative(newBests) : nil
        self.goal = goal
    }

    var hasVisibleFacts: Bool {
        workouts != nil || respectsReceived != nil || newBests != nil || goal != nil
    }
    /// Calendar position only, never an earned streak or a planned-workout claim.
    var calendarWeek: (current: Int, total: Int)? {
        guard let range = calendar.range(of: .weekOfMonth, in: .month, for: asOf) else { return nil }
        let current = calendar.component(.weekOfMonth, from: asOf)
        guard range.contains(current), !range.isEmpty else { return nil }
        return (current - range.lowerBound + 1, range.count)
    }
}

struct ProfileSettingsYouWeight: Equatable, Sendable {
    enum Unit: String, Sendable { case kilograms = "kg", pounds = "lb" }
    let value: Double
    let unit: Unit
    init?(value: Double, unit: Unit) {
        guard value.isFinite, value > 0 else { return nil }
        self.value = value
        self.unit = unit
    }
}

struct ProfileSettingsYouSnapshot: Equatable, Sendable {
    let asOf: Date
    let displayName: String?
    let card: ProfileSettingsYouVerifiedCard?
    let month: ProfileSettingsYouMonth?
    let bodyWeight: ProfileSettingsYouWeight?
    let edition: ProfileSettingsYouEdition
    init(asOf: Date, displayName: String? = nil, card: ProfileSettingsYouVerifiedCard? = nil,
         month: ProfileSettingsYouMonth? = nil, bodyWeight: ProfileSettingsYouWeight? = nil,
         edition: ProfileSettingsYouEdition = .onyx) {
        self.asOf = asOf
        self.displayName = ProfileSettingsYouPresentation.cleanText(displayName)
        let validClock = asOf.timeIntervalSinceReferenceDate.isFinite
        self.card = validClock && (card?.since.map { $0 <= asOf } ?? true) ? card : nil
        self.month = validClock && month?.asOf == asOf && month?.hasVisibleFacts == true ? month : nil
        self.bodyWeight = validClock ? bodyWeight : nil
        self.edition = edition
    }
}

enum ProfileSettingsYouPresentation {
    /// Pass only the root's full acknowledged saved-history reread. Nil means unreadable;
    /// the display surface may be filtered and must not be substituted for this input.
    static func recordedMonth(history: [WorkoutHistoryEntry]?, asOf: Date,
                              calendar: Calendar) -> ProfileSettingsYouMonth? {
        guard let history, asOf.timeIntervalSinceReferenceDate.isFinite,
              let month = calendar.dateInterval(of: .month, for: asOf),
              Set(history.map(\.id)).count == history.count,
              history.allSatisfy({
                  $0.completedAt.timeIntervalSinceReferenceDate.isFinite && $0.completedAt <= asOf
                      && $0.completedSetCount >= 0 && $0.plannedSetCount >= $0.completedSetCount
                      && $0.executionCompleteness != .inconsistent
              }) else { return nil }
        let count = history.filter { $0.completedAt >= month.start && $0.completedAt < month.end }.count
        return .init(start: month.start, end: month.end, asOf: asOf, calendar: calendar,
                     scope: .recordedHistory, workouts: count)
    }
    static func cleanText(_ input: String?) -> String? {
        guard let text = input?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 120,
              !text.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      || CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0)
              }) else { return nil }
        return text
    }
    static func nonnegative(_ value: Int?) -> Int? { value.flatMap { $0 >= 0 ? $0 : nil } }
    static func boundedTilt(_ value: Double) -> Double { value.isFinite ? min(6, max(-6, value)) : 0 }
    /// Source CSS/motion settles at 62%, superseding the tokens' older prose (60%).
    static let settledSheen = 0.62
    static func sheenPosition(tilt: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? settledSheen : settledSheen + boundedTilt(tilt) / 6 * 0.28
    }
    /// Fifteen design segments summarize an explicitly supplied, acknowledged goal.
    static func rail(goal: ProfileSettingsYouMonth.Goal) -> [RailState] {
        let fraction = min(1, Double(goal.completed) / Double(goal.target))
        let done = Int((fraction * 15).rounded(.down))
        return (0..<15).map { $0 < done ? .done : ($0 == done && done < 15 ? .current : .ahead) }
    }
    enum RailState: Equatable { case done, current, ahead }
}

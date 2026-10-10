import ActivityKit
import AppIntents
import Foundation
import SwiftUI

/// The app and extension share the same action accent without changing identity assets.
enum AccentPreference: String, CaseIterable, Identifiable, Sendable {
    case yellow
    case pink

    static let storageKey = "zeroone.accentPreference"
    static func storedValue(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .yellow
    }
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var swatch: ZOColor.Swatch { self == .yellow ? .yellow : .pink }
    var fill: Color { swatch.fill }
    func foreground(in scheme: ColorScheme) -> Color {
        ZOColor.resolved(ZOColor.inkPrimary, in: scheme)
    }
}

/// Cross-process display metadata, qualified by the live owner in the app.
/// No clock origin or extrapolation crosses this boundary. Dates are event metadata only.
struct WorkoutActivityFrozenElapsed: Codable, Hashable, Sendable {
    enum State: String, Codable, Hashable, Sendable { case paused, stopped }
    let version: Int
    let seconds: TimeInterval
    let observedAt: Date
    let state: State

    var wholeSeconds: Int? {
        guard version == 1, seconds.isFinite, seconds >= 0,
              seconds < Double(Int.max), observedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return Int(seconds.rounded(.down))
    }

    /// Static elapsed time, including hours instead of wrapping at sixty minutes.
    func clockText(language: AppLanguage) -> String? {
        guard let total = wholeSeconds else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 0
        func digits(_ value: Int, minimum: Int) -> String? {
            formatter.minimumIntegerDigits = minimum
            return formatter.string(from: NSNumber(value: value))
        }
        guard let seconds = digits(total % 60, minimum: 2) else { return nil }
        if total >= 3_600 {
            guard let hours = digits(total / 3_600, minimum: 1),
                  let minutes = digits((total / 60) % 60, minimum: 2) else { return nil }
            return "\(hours):\(minutes):\(seconds)"
        }
        guard let minutes = digits(total / 60, minimum: 1) else { return nil }
        return "\(minutes):\(seconds)"
    }
}

struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        let exerciseName: String
        let currentSet: Int
        let plannedSetsForExercise: Int
        let completedSets: Int
        let totalSets: Int
        let phase: Phase
        let restEndsAt: Date?
        let pausedRestSeconds: Int?
        // Optional raw value keeps existing ActivityKit payloads decodable.
        var accentPreference: String? = nil
        var accent: AccentPreference { .storedValue(accentPreference) }
        // Presentation only. Keep unknown raw identifiers for forward compatibility.
        var displayLanguageIdentifier: String? = nil
        var displayLanguage: AppLanguage { SharedSurfaceLocalization.language(displayLanguageIdentifier) }
        var localization: AppLocalization { AppLocalization(language: displayLanguage) }
        var designThemeIdentifier: String? = nil
        var displayTheme: ZOTheme { designThemeIdentifier.flatMap(ZOTheme.init(rawValue:)) ?? .core }

        // Exact current countdown target duration from the confirmed snapshot.
        // Nil preserves older payloads; this is not measured physical rest.
        var restTotalSeconds: TimeInterval? = nil

        var frozenElapsed: WorkoutActivityFrozenElapsed? = nil

        // Round 4 phase 9a: the workout coach's own sentences, rendered in the app so the
        // app and the Lock Screen never disagree. Nil on older payloads.
        var coachLine: String? = nil
        var lastTimeShort: String? = nil
        var gainText: String? = nil

        var pausedElapsed: WorkoutActivityFrozenElapsed? {
            guard phase == .paused, let frozenElapsed, frozenElapsed.state == .paused,
                  frozenElapsed.wholeSeconds != nil else { return nil }
            return frozenElapsed
        }

        /// Target display origin (end minus duration), never an observed rest start.
        var restCountdownInterval: ClosedRange<Date>? {
            guard phase == .rest,
                  let duration = restTotalSeconds, duration.isFinite, duration > 0,
                  let end = restEndsAt, end.timeIntervalSinceReferenceDate.isFinite else { return nil }
            let origin = end.addingTimeInterval(-duration)
            guard origin.timeIntervalSinceReferenceDate.isFinite, origin < end else { return nil }
            return origin ... end
        }

        private enum CodingKeys: String, CodingKey {
            case exerciseName, currentSet, plannedSetsForExercise, completedSets, totalSets
            case phase, restEndsAt, pausedRestSeconds, accentPreference, displayLanguageIdentifier, designThemeIdentifier
            case restTotalSeconds, frozenElapsed
            case coachLine, lastTimeShort, gainText
        }

        func usingLanguage(_ language: AppLanguage) -> Self {
            var copy = self
            copy.displayLanguageIdentifier = language.rawValue
            return copy
        }

        func usingDesignTheme(_ theme: ZOTheme) -> Self {
            var copy = self
            copy.designThemeIdentifier = theme.rawValue
            return copy
        }

        enum Phase: String, Codable, Hashable, Sendable {
            case warmUp
            case active
            case rest
            case paused
            case awaitingNextSet
            case readyToFinish
            case saving
        }

        var phaseTitle: String {
            let key: String = switch phase {
            case .warmUp: "Warm up first"
            case .active: "Log your set"
            case .rest: "Rest"
            case .paused: "Paused"
            case .awaitingNextSet: "Set saved"
            case .readyToFinish: "All sets done"
            case .saving: "Saving workout"
            }
            return localization.string(key)
        }
    }

    let sessionID: UUID
    let workoutTitle: String
}

// Decoder lives in an extension to retain the existing memberwise initializer.
// Optional display metadata is tolerant; existing fact decoding stays strict.
extension WorkoutActivityAttributes.ContentState {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(exerciseName: try values.decode(String.self, forKey: .exerciseName),
                  currentSet: try values.decode(Int.self, forKey: .currentSet),
                  plannedSetsForExercise: try values.decode(Int.self, forKey: .plannedSetsForExercise),
                  completedSets: try values.decode(Int.self, forKey: .completedSets),
                  totalSets: try values.decode(Int.self, forKey: .totalSets),
                  phase: try values.decode(Phase.self, forKey: .phase),
                  restEndsAt: try values.decodeIfPresent(Date.self, forKey: .restEndsAt),
                  pausedRestSeconds: try values.decodeIfPresent(Int.self, forKey: .pausedRestSeconds),
                  accentPreference: try values.decodeIfPresent(String.self, forKey: .accentPreference),
                  displayLanguageIdentifier: try? values.decode(String.self, forKey: .displayLanguageIdentifier),
                  designThemeIdentifier: try? values.decode(String.self, forKey: .designThemeIdentifier),
                  restTotalSeconds: try? values.decode(TimeInterval.self, forKey: .restTotalSeconds),
                  frozenElapsed: try? values.decode(WorkoutActivityFrozenElapsed.self, forKey: .frozenElapsed),
                  coachLine: try? values.decode(String.self, forKey: .coachLine),
                  lastTimeShort: try? values.decode(String.self, forKey: .lastTimeShort),
                  gainText: try? values.decode(String.self, forKey: .gainText))
        if let elapsed = frozenElapsed {
            let compatible = elapsed.state == .paused ? phase == .paused
                : (phase == .readyToFinish || phase == .saving)
            if elapsed.wholeSeconds == nil || !compatible { frozenElapsed = nil }
        }
        if let duration = restTotalSeconds, !duration.isFinite || duration <= 0 {
            restTotalSeconds = nil
        }
    }
}

/// Shared Foundation display helpers. Never a transaction or recorded-data parser.
struct SharedSurfaceLocalization {
    let localization: AppLocalization
    init(language: AppLanguage, bundle: Bundle = .main) {
        localization = AppLocalization(language: language, bundle: bundle)
    }
    static func language(_ identifier: String?) -> AppLanguage {
        identifier.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }
    func number(_ value: Double, fractionDigits: ClosedRange<Int> = 0 ... 0) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)).locale(localization.locale))
    }
    func seconds(_ value: Int) -> String {
        localization.format(value == 1 ? "%1$lld second" : "%1$lld seconds", .integer(value))
    }
    func remainingSeconds(_ value: Int) -> String {
        localization.format("%1$@ remaining", .text(seconds(value)))
    }
}

// MARK: - Walk and run Live Activity (study 36)

/// The walk as its own activity: time, distance and steps, never a route or a place.
struct WalkActivityAttributes: ActivityAttributes {
    let sessionID: UUID
    /// "walk" or "run"; the title follows the activity type.
    let kind: String

    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable { case finding, recording, noGPS, paused, saving, saved }
        var phase: Phase
        /// Recording: the clock counts up from here. Paused or saved: `frozenSeconds`.
        var elapsedAnchor: Date
        var frozenSeconds: Int?
        /// nil until the first usable fix, and always nil in time-only recording.
        var distanceMetres: Double?
        var steps: Int?
        var distanceIncomplete: Bool
        var designThemeIdentifier: String?
        var accentPreference: String?
        var displayLanguageIdentifier: String?

        init(phase: Phase, elapsedAnchor: Date, frozenSeconds: Int?, distanceMetres: Double?, steps: Int?,
             distanceIncomplete: Bool, designThemeIdentifier: String?, accentPreference: String?, displayLanguageIdentifier: String?) {
            self.phase = phase
            self.elapsedAnchor = elapsedAnchor
            self.frozenSeconds = frozenSeconds
            self.distanceMetres = distanceMetres
            self.steps = steps
            self.distanceIncomplete = distanceIncomplete
            self.designThemeIdentifier = designThemeIdentifier
            self.accentPreference = accentPreference
            self.displayLanguageIdentifier = displayLanguageIdentifier
        }

        /// Tolerant: a field added later never breaks an activity started by an older build.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            phase = (try? values.decode(Phase.self, forKey: .phase)) ?? .recording
            elapsedAnchor = (try? values.decode(Date.self, forKey: .elapsedAnchor)) ?? .now
            frozenSeconds = try? values.decodeIfPresent(Int.self, forKey: .frozenSeconds)
            distanceMetres = try? values.decodeIfPresent(Double.self, forKey: .distanceMetres)
            steps = try? values.decodeIfPresent(Int.self, forKey: .steps)
            distanceIncomplete = (try? values.decodeIfPresent(Bool.self, forKey: .distanceIncomplete)) ?? false
            designThemeIdentifier = try? values.decodeIfPresent(String.self, forKey: .designThemeIdentifier)
            accentPreference = try? values.decodeIfPresent(String.self, forKey: .accentPreference)
            displayLanguageIdentifier = try? values.decodeIfPresent(String.self, forKey: .displayLanguageIdentifier)
        }

        var displayLanguage: AppLanguage {
            SharedSurfaceLocalization.language(displayLanguageIdentifier)
        }
        var localization: AppLocalization { AppLocalization(language: displayLanguage) }
        var displayTheme: ZOTheme { designThemeIdentifier.flatMap(ZOTheme.init(rawValue:)) ?? .core }
        var accent: AccentPreference { AccentPreference.storedValue(accentPreference) }
        var isLive: Bool { phase == .finding || phase == .recording || phase == .noGPS }

        /// Average pace from the recorded distance only: "9:48".
        var paceText: String? {
            guard let distanceMetres, distanceMetres >= 50, let seconds = frozenSeconds ?? liveSeconds else { return nil }
            let perKm = Int((Double(seconds) / (distanceMetres / 1000)).rounded())
            guard perKm > 0, perKm < 60 * 60 else { return nil }
            return "\(perKm / 60):" + String(format: "%02d", perKm % 60)
        }
        private var liveSeconds: Int? {
            let value = Date.now.timeIntervalSince(elapsedAnchor)
            return value.isFinite && value >= 0 ? Int(value) : nil
        }
    }
}

enum WalkActivityCommand: String, Sendable { case pause, resume }

/// The app installs the handler; the intents run in the app's process.
@MainActor
enum WalkActivityControl {
    static var handler: ((WalkActivityCommand, UUID) async -> Void)?

    static func run(_ command: WalkActivityCommand, sessionID: String) async {
        guard let id = UUID(uuidString: sessionID), let handler else { return }
        await handler(command, id)
    }
}

struct PauseWalkIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause walk in 01"
    static var isDiscoverable = false
    @Parameter(title: "Session") var sessionID: String

    init() { }
    init(sessionID: UUID) { self.sessionID = sessionID.uuidString }

    func perform() async throws -> some IntentResult {
        await WalkActivityControl.run(.pause, sessionID: sessionID)
        return .result()
    }
}

struct ResumeWalkIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Resume walk in 01"
    static var isDiscoverable = false
    @Parameter(title: "Session") var sessionID: String

    init() { }
    init(sessionID: UUID) { self.sessionID = sessionID.uuidString }

    func perform() async throws -> some IntentResult {
        await WalkActivityControl.run(.resume, sessionID: sessionID)
        return .result()
    }
}

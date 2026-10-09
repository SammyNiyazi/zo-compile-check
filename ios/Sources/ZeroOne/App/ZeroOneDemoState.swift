import Foundation
import Observation

enum ZeroOneDestinationState: String, CaseIterable, Codable, Hashable, Identifiable {
    case initial
    case empty
    case unavailable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .initial: "Initial"
        case .empty: "Empty"
        case .unavailable: "Unavailable"
        }
    }
}

struct ZeroOneDemoState: Codable, Equatable {
    var today: ZeroOneDestinationState = .initial
    var workout: ZeroOneDestinationState = .initial
    var social: ZeroOneDestinationState = .initial
    var diets: ZeroOneDestinationState = .initial

    static let initial = ZeroOneDemoState()

    func state(for destination: AppTab) -> ZeroOneDestinationState {
        switch destination {
        case .today: today
        case .workout: workout
        case .social: social
        case .diets: diets
        }
    }

    mutating func set(_ state: ZeroOneDestinationState, for destination: AppTab) {
        switch destination {
        case .today: today = state
        case .workout: workout = state
        case .social: social = state
        case .diets: diets = state
        }
    }
}

protocol ZeroOneDemoStatePersisting {
    func load() -> ZeroOneDemoState?
    func save(_ state: ZeroOneDemoState)
}

struct UserDefaultsZeroOneDemoStateStore: ZeroOneDemoStatePersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "slick.demoState") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> ZeroOneDemoState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ZeroOneDemoState.self, from: data)
    }

    func save(_ state: ZeroOneDemoState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
@Observable
final class ZeroOneDemoStateModel {
    private let store: any ZeroOneDemoStatePersisting
    private(set) var value: ZeroOneDemoState

    init(
        store: any ZeroOneDemoStatePersisting = UserDefaultsZeroOneDemoStateStore(),
        fallback: ZeroOneDemoState = .initial
    ) {
        self.store = store
        value = store.load() ?? fallback
    }

    func state(for destination: AppTab) -> ZeroOneDestinationState {
        value.state(for: destination)
    }

    func set(_ state: ZeroOneDestinationState, for destination: AppTab) {
        guard value.state(for: destination) != state else { return }
        value.set(state, for: destination)
        store.save(value)
    }
}

enum ZeroOneTrainingGoal: String, CaseIterable, Codable, Identifiable, Sendable {
    case buildStrength
    case buildMuscle
    case generalFitness
    case sportPerformance
    case moveBetter
    case manageBodyWeight
    case notSure

    var id: String { rawValue }
    var title: String {
        switch self {
        case .buildStrength: "Build strength"
        case .buildMuscle: "Build muscle"
        case .generalFitness: "General fitness"
        case .sportPerformance: "Train for a sport"
        case .moveBetter: "Move better"
        case .manageBodyWeight: "Manage body weight"
        case .notSure: "Not sure yet"
        }
    }
}

enum ZeroOneTrainingExperience: String, CaseIterable, Codable, Identifiable, Sendable {
    case startingOut
    case someExperience
    case returning
    case trainingRegularly
    case experienced
    case notSure

    var id: String { rawValue }
    var title: String {
        switch self {
        case .startingOut: "Starting out"
        case .someExperience: "Some experience"
        case .returning: "Coming back"
        case .trainingRegularly: "Training regularly"
        case .experienced: "Experienced"
        case .notSure: "Not sure"
        }
    }
}

enum ZeroOneWeeklyAvailability: String, CaseIterable, Codable, Identifiable, Sendable {
    case twoDays
    case threeDays
    case fourDays
    case fiveOrMoreDays
    case notSure

    var id: String { rawValue }
    var title: String {
        switch self {
        case .twoDays: "2 days"
        case .threeDays: "3 days"
        case .fourDays: "4 days"
        case .fiveOrMoreDays: "5 or more days"
        case .notSure: "Not sure"
        }
    }
}

enum ZeroOneEquipmentAccess: String, CaseIterable, Codable, Identifiable, Sendable {
    case bodyweight
    case dumbbells
    case fullGym
    case notSure

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bodyweight: "Bodyweight only"
        case .dumbbells: "Dumbbells"
        case .fullGym: "Full gym"
        case .notSure: "Not sure"
        }
    }
}

enum ZeroOneTrainingConstraint: String, CaseIterable, Codable, Identifiable, Sendable {
    case none
    case shortSessions
    case variableSchedule
    case movementSensitivity
    case notSure

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "No current constraint"
        case .shortSessions: "Short sessions"
        case .variableSchedule: "Variable schedule"
        case .movementSensitivity: "Some movements need care"
        case .notSure: "Not sure"
        }
    }
}

struct ZeroOneUserProfile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var onboardingComplete = false
    var trainingGoal: ZeroOneTrainingGoal?
    /// Ordered choices. The first remains the primary goal for the starter plan.
    /// Older version-1 profiles retain their existing single goal.
    var trainingGoals: [ZeroOneTrainingGoal]?
    var trainingExperience: ZeroOneTrainingExperience?
    var weeklyAvailability: ZeroOneWeeklyAvailability?
    var equipmentAccess: ZeroOneEquipmentAccess?
    var trainingConstraint: ZeroOneTrainingConstraint?
    /// New selection facts are explicit; older profiles keep them unknown.
    var starterSelectionPreferences: StarterSelectionPreferences?
    /// Optional for compatibility with profiles saved before the skippable setup.
    var onboardingWasSkipped: Bool?
    /// First-run detail stays optional so older version-1 profiles decode unchanged.
    var trainingSport: ZeroOneTrainingSport?
    var availableEquipment: Set<ZeroOneEquipmentItem>?
    var preferredTrainingDays: Set<ZeroOneTrainingDay>?
    var preferredSessionMinutes: Int?
    var preferredWeightUnit: ZeroOneWeightPreference?
    var preferredDistanceUnit: ZeroOneDistancePreference?
    /// Draft value until committed into the local body-weight history.
    var startingBodyWeight: Double?
    /// Stored in centimetres, independently of the display-unit preference.
    var bodyHeight: BodyHeightMeasurement?
    var startingBodyWeightEntryID: UUID?
    var startingBodyWeightRecordedAt: Date?
    /// Stable IDs let an interrupted plan save retry without duplicate sessions.
    var firstWeekDraftWorkoutIDs: [UUID]?
    var savedFirstWeekPlan: ZeroOneSavedFirstWeekPlan?
    /// Optional local display name. Absent in earlier version-1 profiles.
    var displayName: String?
    /// Optional initials colour. Absence preserves the original theme-aware badge.
    var initialsTone: ZeroOneProfileInitialTone?

    var isCompatible: Bool {
        guard version == Self.currentVersion else { return false }
        guard bodyHeight?.isValid ?? true else { return false }
        guard starterSelectionPreferences?.isValid ?? true else { return false }
        guard let trainingGoals else { return true }
        return !trainingGoals.isEmpty && Set(trainingGoals).count == trainingGoals.count
            && trainingGoal == trainingGoals.first
            && (!trainingGoals.contains(.notSure) || trainingGoals.count == 1)
    }

    var selectedTrainingGoals: [ZeroOneTrainingGoal] {
        trainingGoals ?? trainingGoal.map { [$0] } ?? []
    }

    mutating func toggleTrainingGoal(_ goal: ZeroOneTrainingGoal) {
        var goals = selectedTrainingGoals
        if goals.contains(goal) {
            goals.removeAll { $0 == goal }
        } else if goal == .notSure {
            goals = [.notSure]
        } else {
            goals.removeAll { $0 == .notSure }
            goals.append(goal)
        }
        trainingGoal = goals.first
        trainingGoals = goals.isEmpty ? nil : goals
        if !goals.contains(.sportPerformance) { trainingSport = nil }
    }
}

protocol ZeroOneUserProfilePersisting {
    func load() -> ZeroOneUserProfile?
    func loadForExport() throws -> ZeroOneUserProfile?
    func save(_ profile: ZeroOneUserProfile)
    func clear()
    /// Moves saved bytes that can't be read as a current profile to a backup slot and empties the
    /// profile slot. Returns true only when the backup is confirmed and the slot is empty.
    func quarantineUnreadableProfile() -> Bool
}

extension ZeroOneUserProfilePersisting {
    func loadForExport() throws -> ZeroOneUserProfile? {
        let profile = load()
        guard profile?.isCompatible ?? true else { throw CocoaError(.fileReadCorruptFile) }
        return profile
    }

    /// Stores that can't keep a backup copy never discard data.
    func quarantineUnreadableProfile() -> Bool { false }
}

struct UserDefaultsZeroOneUserProfileStore: ZeroOneUserProfilePersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "slick.userProfile") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> ZeroOneUserProfile? {
        // A failed read is not authority to delete the person's saved profile.
        try? loadForExport()
    }

    /// Export must not erase an unreadable or incompatible stored profile.
    func loadForExport() throws -> ZeroOneUserProfile? {
        guard let object = defaults.object(forKey: key) else { return nil }
        guard let data = object as? Data else { throw CocoaError(.fileReadCorruptFile) }
        let profile = try JSONDecoder().decode(ZeroOneUserProfile.self, from: data)
        guard profile.isCompatible else { throw CocoaError(.fileReadCorruptFile) }
        return profile
    }

    func save(_ profile: ZeroOneUserProfile) {
        guard profile.isCompatible,
              let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    /// Keeps the unreadable bytes under a separate, never-loaded backup key, then empties the
    /// profile slot so setup can run. Nothing is removed unless the backup reads back identically.
    func quarantineUnreadableProfile() -> Bool {
        guard let object = defaults.object(forKey: key) else { return true }
        let backupKey = "\(key).unreadableBackup.\(Int(Date().timeIntervalSince1970))"
        defaults.set(object, forKey: backupKey)
        guard let backedUp = defaults.object(forKey: backupKey) as? NSObject,
              backedUp.isEqual(object) else { return false }
        defaults.removeObject(forKey: key)
        return defaults.object(forKey: key) == nil
    }
}

enum ZeroOneRootRoute: Equatable {
    case onboarding
    case appShell
}

struct ZeroOneRootRouteSelector {
    func route(for profile: ZeroOneUserProfile) -> ZeroOneRootRoute {
        profile.isCompatible && profile.onboardingComplete ? .appShell : .onboarding
    }
}

@MainActor
@Observable
final class ZeroOneUserProfileRepository {
    private let store: any ZeroOneUserProfilePersisting
    private(set) var profile: ZeroOneUserProfile
    private(set) var isAvailable = false
    private(set) var saveError: String?
    @ObservationIgnored private var lastSavedProfile: ZeroOneUserProfile?
    @ObservationIgnored private var shareRevocationRegistration: ZeroOneShareRevocationRegistration?

    init(store: any ZeroOneUserProfilePersisting = UserDefaultsZeroOneUserProfileStore()) {
        self.store = store
        profile = ZeroOneUserProfile()
        reload()
    }

    /// This capability only revokes retained exports before profile transitions.
    /// Old and distinct incoming permits close before registration identity changes.
    func installShareRevocationRegistration(_ registration: ZeroOneShareRevocationRegistration?) {
        shareRevocationRegistration?.revokeBeforeChange()
        if shareRevocationRegistration !== registration { registration?.revokeBeforeChange() }
        shareRevocationRegistration = registration
    }

    /// Parent readiness must bind the exact retained registration reference.
    func isShareRevocationRegistered(_ registration: ZeroOneShareRevocationRegistration?) -> Bool {
        guard let registration else { return false }
        return shareRevocationRegistration === registration
    }

    var rootRoute: ZeroOneRootRoute {
        ZeroOneRootRouteSelector().route(for: profile)
    }

    func profileForExport() throws -> ZeroOneUserProfile? {
        try store.loadForExport()
    }

    @discardableResult
    func reload() -> Bool {
        shareRevocationRegistration?.revokeBeforeChange()
        do {
            try loadSavedProfile()
            return true
        } catch {
            // Unreadable saved data must never trap the person in setup (which could never save).
            // When the store can keep a backup copy, it does, and setup starts fresh.
            if store.quarantineUnreadableProfile() {
                do {
                    try loadSavedProfile()
                    return true
                } catch {}
            }
            isAvailable = false
            saveError = "Your saved preferences could not be read. Existing data has been kept. Try reloading."
            return false
        }
    }

    private func loadSavedProfile() throws {
        let saved = try store.loadForExport()
        guard saved?.isCompatible ?? true else { throw CocoaError(.fileReadCorruptFile) }
        profile = saved ?? ZeroOneUserProfile()
        lastSavedProfile = saved
        isAvailable = true
        saveError = nil
    }

    @discardableResult
    func update(_ change: (inout ZeroOneUserProfile) -> Void) -> Bool {
        updateVerified(change)
    }

    /// Critical onboarding commits verify persistence before advancing the root.
    @discardableResult
    func updateVerified(_ change: (inout ZeroOneUserProfile) -> Void) -> Bool {
        shareRevocationRegistration?.revokeBeforeChange()
        guard isAvailable else {
            saveError = "Preferences are unavailable. Reload them before saving changes."
            return false
        }
        var proposed = profile
        change(&proposed)
        guard proposed.isCompatible else { return false }
        do {
            let current = try store.loadForExport()
            // Reconcile an earlier write that landed before its readback failed.
            if current == proposed {
                profile = proposed
                lastSavedProfile = current
                saveError = nil
                return true
            }
            guard current == lastSavedProfile else {
                saveError = "Your preferences changed elsewhere. Reload the saved preferences, then review your change again."
                return false
            }
            if proposed == profile { saveError = nil; return true }
            store.save(proposed)
            guard try store.loadForExport() == proposed else {
                saveError = "Saving your preferences could not be confirmed. Your previous displayed choices are unchanged. Try again."
                return false
            }
            profile = proposed
            lastSavedProfile = proposed
            saveError = nil
            return true
        } catch {
            isAvailable = false
            saveError = "Your preferences could not be read to confirm this change. Reload them before trying again."
            return false
        }
    }

    func completeOnboarding() {
        update { $0.onboardingComplete = true }
    }
}

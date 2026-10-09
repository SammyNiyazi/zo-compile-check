import Foundation

enum HydrationTransactionError: Error, LocalizedError {
    case unavailable, invalidData, invalidAmount, changed, expired, verificationFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: "Open 01 to finish setting up water logging."
        case .invalidData, .verificationFailed: "Water could not be saved. Open 01 to check your total."
        case .invalidAmount: "Choose a valid water amount."
        case .changed: "Your water total changed. Refresh and try again."
        case .expired: "This water action has expired. Refresh and try again."
        }
    }
}

struct HydrationAddition: Codable, Hashable, Sendable {
    static let quickGroupInterval: TimeInterval = 5
    let id: UUID
    let requestID: UUID
    let baseRevision: UUID
    let date: Date
    let dayStart: Date
    let previousMilliliters: Int
    let savedMilliliters: Int
    var amount: Int { savedMilliliters - previousMilliliters }
}

/// Canonical water state shared by the app and extension, not a widget display cache.
struct HydrationTransactionState: Codable, Equatable, Sendable {
    let version: Int
    let revision: UUID
    let state: HydrationStoredState
    let lastAddition: HydrationAddition?
    let lastUndoneID: UUID?

    init(state: HydrationStoredState, revision: UUID = UUID(),
         lastAddition: HydrationAddition? = nil, lastUndoneID: UUID? = nil) {
        version = 1
        self.revision = revision
        self.state = state
        self.lastAddition = lastAddition
        self.lastUndoneID = lastUndoneID
    }

    var isValid: Bool {
        guard version == 1, state.currentMilliliters >= 0, state.goalMilliliters > 0,
              state.date.timeIntervalSinceReferenceDate.isFinite else { return false }
        if let start = state.dayStart {
            guard start.timeIntervalSinceReferenceDate.isFinite, start <= state.date else { return false }
        }
        guard let receipt = lastAddition else { return true }
        return lastUndoneID == nil && receipt.id == revision && receipt.baseRevision != revision
            && receipt.date == state.date && receipt.dayStart == state.dayStart
            && receipt.previousMilliliters >= 0 && receipt.savedMilliliters > receipt.previousMilliliters
            && receipt.savedMilliliters == state.currentMilliliters
    }

    func isCurrent(at date: Date, calendar: Calendar) -> Bool {
        isValid && state.date <= date && calendar.isDate(state.date, inSameDayAs: date)
            && (state.dayStart == nil || state.dayStart == calendar.startOfDay(for: date))
    }

    /// Widget buttons carry the revision they displayed. Repeated delivery of
    /// that same add returns its receipt, never adds again after a later write.
    func adding(_ amount: Int, expectedRevision: UUID?, expectedDayStart: Date? = nil, requestID: UUID = UUID(), at date: Date, calendar: Calendar) throws -> Self {
        guard isValid, date.timeIntervalSinceReferenceDate.isFinite else { throw HydrationTransactionError.invalidData }
        guard amount > 0 else { throw HydrationTransactionError.invalidAmount }
        if expectedRevision != nil && expectedDayStart != calendar.startOfDay(for: date) {
            throw HydrationTransactionError.expired
        }
        if let expectedRevision, expectedRevision != revision {
            if let receipt = lastAddition, receipt.baseRevision == expectedRevision, receipt.requestID == requestID,
               receipt.amount == amount, isCurrent(at: date, calendar: calendar) { return self }
            throw HydrationTransactionError.changed
        }
        guard state.date <= date else { throw HydrationTransactionError.expired }
        let previous = isCurrent(at: date, calendar: calendar) ? state.currentMilliliters : 0
        guard previous <= Int.max - amount else { throw HydrationTransactionError.invalidAmount }
        let next = HydrationStoredState(date: date, currentMilliliters: previous + amount,
                                        goalMilliliters: state.goalMilliliters, dayStart: calendar.startOfDay(for: date))
        let id = UUID()
        return Self(state: next, revision: id, lastAddition: .init(id: id, requestID: requestID, baseRevision: revision,
            date: date, dayStart: calendar.startOfDay(for: date), previousMilliliters: previous, savedMilliliters: previous + amount))
    }

    /// A goal edit changes no drink, timestamp or Undo receipt. Compare the goal
    /// independently so a concurrent widget drink is retained rather than lost.
    func changingGoal(_ milliliters: Int, replacing expectedGoal: Int) throws -> Self {
        guard isValid else { throw HydrationTransactionError.invalidData }
        guard milliliters > 0 else { throw HydrationTransactionError.invalidAmount }
        guard state.goalMilliliters == expectedGoal else { throw HydrationTransactionError.changed }
        return Self(state: .init(date: state.date, currentMilliliters: state.currentMilliliters,
            goalMilliliters: milliliters, dayStart: state.dayStart), revision: revision,
            lastAddition: lastAddition, lastUndoneID: lastUndoneID)
    }

    func replacing(_ amount: Int, expectedRevision: UUID, at date: Date, calendar: Calendar) throws -> Self {
        guard isValid else { throw HydrationTransactionError.invalidData }
        guard expectedRevision == revision else { throw HydrationTransactionError.changed }
        guard amount >= 0 else { throw HydrationTransactionError.invalidAmount }
        guard date.timeIntervalSinceReferenceDate.isFinite, state.date <= date else { throw HydrationTransactionError.expired }
        return Self(state: .init(date: date, currentMilliliters: amount, goalMilliliters: state.goalMilliliters,
                                 dayStart: calendar.startOfDay(for: date)))
    }

    func undoing(_ id: UUID, at date: Date, calendar: Calendar) throws -> Self {
        guard isCurrent(at: date, calendar: calendar) else { throw HydrationTransactionError.expired }
        if lastUndoneID == id { return self }
        guard let receipt = lastAddition, receipt.id == id, revision == id else { throw HydrationTransactionError.changed }
        return Self(state: .init(date: date, currentMilliliters: receipt.previousMilliliters,
            goalMilliliters: state.goalMilliliters, dayStart: receipt.dayStart), lastUndoneID: id)
    }

    /// Undo a verified contiguous burst in one write. A widget's single Undo
    /// must not be mistaken for successful removal of the whole app burst.
    func undoingGroup(_ additions: [HydrationAddition], at date: Date, calendar: Calendar) throws -> Self {
        guard isCurrent(at: date, calendar: calendar) else { throw HydrationTransactionError.expired }
        guard let first = additions.first, let last = additions.last,
              Set(additions.map(\.id)).count == additions.count,
              lastAddition == last, revision == last.id else { throw HydrationTransactionError.changed }
        for (index, addition) in additions.enumerated() {
            guard addition.date.timeIntervalSinceReferenceDate.isFinite,
                  addition.previousMilliliters >= 0, addition.savedMilliliters > addition.previousMilliliters,
                  addition.id != addition.baseRevision,
                  addition.dayStart == calendar.startOfDay(for: date),
                  calendar.isDate(addition.date, inSameDayAs: date), addition.date <= date else {
                throw HydrationTransactionError.expired
            }
            if index > 0 {
                let previous = additions[index - 1]
                let gap = addition.date.timeIntervalSince(previous.date)
                guard addition.baseRevision == previous.id,
                      addition.previousMilliliters == previous.savedMilliliters,
                      gap >= 0, gap <= HydrationAddition.quickGroupInterval else {
                    throw HydrationTransactionError.changed
                }
            }
        }
        return Self(state: .init(date: date, currentMilliliters: first.previousMilliliters,
            goalMilliliters: state.goalMilliliters, dayStart: first.dayStart), lastUndoneID: last.id)
    }
}

protocol HydrationTransactionalPersisting: HydrationPersisting {
    func readTransaction() throws -> HydrationTransactionState
    func setGoal(_ milliliters: Int, replacing expectedGoal: Int) throws -> HydrationTransactionState
    func add(_ amount: Int, expectedRevision: UUID?, expectedDayStart: Date?, requestID: UUID, at date: Date, calendar: Calendar) throws -> HydrationTransactionState
    func replace(_ amount: Int, expectedRevision: UUID, at date: Date, calendar: Calendar) throws -> HydrationTransactionState
    func undo(_ id: UUID, at date: Date, calendar: Calendar) throws -> HydrationTransactionState
    func undoGroup(_ additions: [HydrationAddition], at date: Date, calendar: Calendar) throws -> HydrationTransactionState
}

extension HydrationTransactionalPersisting {
    func setGoal(_ milliliters: Int, replacing expectedGoal: Int) throws -> HydrationTransactionState {
        throw HydrationTransactionError.unavailable
    }
}

/// Every canonical read-modify-write is inside one cross-process coordination
/// accessor. Atomic replacement and readback complete before releasing it.
struct SharedHydrationStore: HydrationTransactionalPersisting, Sendable {
    private let directory: URL?

    init(bundle: Bundle = .main) {
        let identifier = (bundle.object(forInfoDictionaryKey: "01AppGroupIdentifier") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        directory = identifier.flatMap { $0.isEmpty ? nil : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }?
            .appendingPathComponent("HydrationShared", isDirectory: true)
    }

    init(directory: URL?) { self.directory = directory }
    var isAvailable: Bool { (try? readTransaction()) != nil }
    func load() -> HydrationStoredState? { try? readTransaction().state }

    /// Legacy blind overwrites are deliberately rejected. All production writes
    /// must use add/replace/undo and their conflict checks.
    func save(_ state: HydrationStoredState) { }

    /// Called only by the containing app. Never deletes or rewrites legacy data,
    /// and never imports again over an existing canonical file, even if corrupt.
    func migrate(from legacy: any HydrationPersisting, at date: Date) throws {
        guard let directory else { throw HydrationTransactionError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let _: HydrationTransactionState = try coordinated(write: true) { url in
            if FileManager.default.fileExists(atPath: url.path) { return try decode(url) }
            guard legacy.isAvailable else { throw HydrationTransactionError.invalidData }
            let initial = legacy.load() ?? .init(date: date, currentMilliliters: 0, goalMilliliters: 2_500,
                                                dayStart: Calendar.autoupdatingCurrent.startOfDay(for: date))
            let value = HydrationTransactionState(state: initial)
            guard value.isValid else { throw HydrationTransactionError.invalidData }
            try persist(value, at: url)
            return value
        }
    }

    func setGoal(_ milliliters: Int, replacing expectedGoal: Int) throws -> HydrationTransactionState {
        try change { try $0.changingGoal(milliliters, replacing: expectedGoal) }
    }
    func readTransaction() throws -> HydrationTransactionState {
        try coordinated(write: false) { try decode($0) }
    }
    func add(_ amount: Int, expectedRevision: UUID? = nil, expectedDayStart: Date? = nil, requestID: UUID = UUID(), at date: Date, calendar: Calendar) throws -> HydrationTransactionState {
        try change { try $0.adding(amount, expectedRevision: expectedRevision, expectedDayStart: expectedDayStart, requestID: requestID, at: date, calendar: calendar) }
    }
    func replace(_ amount: Int, expectedRevision: UUID, at date: Date, calendar: Calendar) throws -> HydrationTransactionState {
        try change { try $0.replacing(amount, expectedRevision: expectedRevision, at: date, calendar: calendar) }
    }
    func undo(_ id: UUID, at date: Date, calendar: Calendar) throws -> HydrationTransactionState {
        try change { try $0.undoing(id, at: date, calendar: calendar) }
    }
    func undoGroup(_ additions: [HydrationAddition], at date: Date, calendar: Calendar) throws -> HydrationTransactionState {
        try change { try $0.undoingGroup(additions, at: date, calendar: calendar) }
    }

    private func change(_ body: (HydrationTransactionState) throws -> HydrationTransactionState) throws -> HydrationTransactionState {
        try coordinated(write: true) { url in
            let previous = try decode(url)
            let next = try body(previous)
            if next != previous { try persist(next, at: url) }
            return next
        }
    }
    private func decode(_ url: URL) throws -> HydrationTransactionState {
        let value = try JSONDecoder().decode(HydrationTransactionState.self, from: Data(contentsOf: url))
        guard value.isValid else { throw HydrationTransactionError.invalidData }
        return value
    }
    private func persist(_ value: HydrationTransactionState, at url: URL) throws {
        guard value.isValid else { throw HydrationTransactionError.invalidData }
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard try decode(url) == value else { throw HydrationTransactionError.verificationFailed }
    }
    private func coordinated<T>(write: Bool, _ body: (URL) throws -> T) throws -> T {
        guard let directory else { throw HydrationTransactionError.unavailable }
        let url = directory.appendingPathComponent("water-v1.json")
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        if write {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
                result = Result { try body(coordinatedURL) }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                result = Result { try body(coordinatedURL) }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw HydrationTransactionError.unavailable }
        return try result.get()
    }
}

enum HydrationStoreFactory {
    static func makeAppStore(bundle: Bundle = .main) -> any HydrationPersisting {
        let legacy = UserDefaultsHydrationStore()
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            || environment.keys.contains(where: { $0.hasPrefix("ZERO_ONE_") && $0.contains("REVIEW") }) { return legacy }
        #endif
        guard bundle.object(forInfoDictionaryKey: "01AppGroupIdentifier") != nil else { return legacy }
        let shared = SharedHydrationStore(bundle: bundle)
        try? shared.migrate(from: legacy, at: .now)
        // Configured but unavailable/corrupt shared storage must never fork into
        // a second writable local store. Surface the failure and keep evidence.
        return shared
    }
}

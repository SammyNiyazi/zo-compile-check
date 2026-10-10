import Foundation
import Observation

struct HydrationQuickLogReceipt: Hashable {
    let date: Date
    let previousMilliliters: Int
    let savedMilliliters: Int
    let dayStart: Date?
    let transactionID: UUID?
    let transaction: HydrationAddition?

    init(date: Date, previousMilliliters: Int, savedMilliliters: Int, dayStart: Date? = nil, transactionID: UUID? = nil,
         transaction: HydrationAddition? = nil) {
        self.date = date
        self.previousMilliliters = previousMilliliters
        self.savedMilliliters = savedMilliliters
        self.dayStart = dayStart
        self.transactionID = transactionID
        self.transaction = transaction
    }
}

/// Consecutive confirmed taps on one surface share Undo. A pause, a new day,
/// or an intervening transaction starts a fresh group.
struct HydrationQuickLogGroup: Hashable {
    let receipts: [HydrationQuickLogReceipt]
    var first: HydrationQuickLogReceipt { receipts[0] }
    var latest: HydrationQuickLogReceipt { receipts[receipts.count - 1] }
    var addedMilliliters: Int { latest.savedMilliliters - first.previousMilliliters }

    init(_ receipt: HydrationQuickLogReceipt) { receipts = [receipt] }
    private init(receipts: [HydrationQuickLogReceipt]) { self.receipts = receipts }

    func appending(_ receipt: HydrationQuickLogReceipt) -> Self {
        let gap = receipt.date.timeIntervalSince(latest.date)
        let contiguous: Bool
        if let previous = latest.transaction, let next = receipt.transaction {
            contiguous = next.baseRevision == previous.id
        } else {
            contiguous = latest.transaction == nil && receipt.transaction == nil
        }
        guard gap >= 0, gap <= HydrationAddition.quickGroupInterval,
              receipt.dayStart == latest.dayStart,
              receipt.previousMilliliters == latest.savedMilliliters, contiguous else { return Self(receipt) }
        return Self(receipts: receipts + [receipt])
    }
}

@MainActor
@Observable
final class HydrationViewModel {
    private(set) var state: HydrationState
    private(set) var isPersistenceAvailable: Bool
    private(set) var persistenceErrorMessage: String?
    private(set) var stateDayStart: Date

    var canConfirmQuickWaterSave: Bool {
        isPersistenceAvailable && store?.isAvailable == true
    }

    private let store: (any HydrationPersisting)?
    private var observedTransactionRevision: UUID?
    private let calendar: Calendar
    private let currentDate: () -> Date
    private let onConfirmedAddition: (HydrationQuickLogReceipt) -> Void
    private let onConfirmedUndo: (HydrationQuickLogReceipt) -> Void

    init(
        state: HydrationState = HydrationState(),
        store: (any HydrationPersisting)? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        currentDate: @escaping () -> Date = { .now },
        onConfirmedAddition: @escaping (HydrationQuickLogReceipt) -> Void = { _ in },
        onConfirmedUndo: @escaping (HydrationQuickLogReceipt) -> Void = { _ in }
    ) {
        self.store = store
        self.calendar = calendar
        self.currentDate = currentDate
        self.onConfirmedAddition = onConfirmedAddition
        self.onConfirmedUndo = onConfirmedUndo
        let transaction = try? (store as? any HydrationTransactionalPersisting)?.readTransaction()
        observedTransactionRevision = transaction?.revision
        // A local value: an @Observable property can't be read before every stored property is set.
        let dayStart = calendar.startOfDay(for: currentDate())
        stateDayStart = dayStart
        isPersistenceAvailable = store?.isAvailable ?? true

        if let stored = transaction?.state ?? store?.load(),
           calendar.isDate(stored.date, inSameDayAs: currentDate()),
           stored.dayStart == nil || stored.dayStart == dayStart,
           stored.currentMilliliters >= 0,
           stored.goalMilliliters > 0 {
            self.state = HydrationState(
                currentMilliliters: stored.currentMilliliters,
                goalMilliliters: stored.goalMilliliters,
                recentHistory: state.recentHistory
            )
        } else if let stored = transaction?.state ?? store?.load(), stored.goalMilliliters > 0 {
            // The drink total belongs to its day; the chosen goal survives it.
            self.state = HydrationState(currentMilliliters: 0,
                goalMilliliters: stored.goalMilliliters, recentHistory: state.recentHistory)
        } else {
            self.state = state
        }
    }

    func addWater(milliliters: Int) {
        refreshForCurrentDay()
        guard milliliters > 0, state.currentMilliliters <= Int.max - milliliters else { return }
        if store == nil {
            state.add(milliliters)
        } else {
            _ = addWaterFromQuickAction(milliliters: milliliters)
        }
    }

    /// Read-only reconciliation on foreground/day changes. Never writes a reset or logs a drink.
    func refreshForCurrentDay() {
        let date = currentDate()
        let dayStart = calendar.startOfDay(for: date)
        if dayStart != stateDayStart {
            let history = state.recentIntake(endingOn: stateDayStart, calendar: calendar)
            state = HydrationState(currentMilliliters: 0, goalMilliliters: state.goalMilliliters, recentHistory: history)
            stateDayStart = dayStart
        }
        guard let store else { return }
        let loaded: HydrationStoredState?
        if let transactional = store as? any HydrationTransactionalPersisting {
            do {
                let result = try transactional.readTransaction()
                loaded = result.state
                observedTransactionRevision = result.revision
                isPersistenceAvailable = true
            } catch { isPersistenceAvailable = false; return }
        } else {
            isPersistenceAvailable = store.isAvailable
            loaded = store.load()
        }
        guard isPersistenceAvailable, let stored = loaded else { return }
        guard stored.currentMilliliters >= 0, stored.goalMilliliters > 0 else {
            isPersistenceAvailable = false
            return
        }
        guard calendar.isDate(stored.date, inSameDayAs: date),
              stored.dayStart == nil || stored.dayStart == dayStart else {
            state = HydrationState(currentMilliliters: state.currentMilliliters,
                goalMilliliters: stored.goalMilliliters, recentHistory: state.recentHistory)
            return
        }
        state = HydrationState(
            currentMilliliters: stored.currentMilliliters,
            goalMilliliters: stored.goalMilliliters,
            recentHistory: state.recentHistory
        )
    }

    /// Only reports success after the local store reads back the exact new total.
    /// The quick-action UI must not claim a save from an in-memory-only change.
    func addWaterFromQuickAction(milliliters: Int) -> HydrationQuickLogReceipt? {
        refreshForCurrentDay()
        guard milliliters > 0,
              isPersistenceAvailable,
              let store,
              store.isAvailable else {
            return nil
        }

        let date = currentDate()
        if let transactional = store as? any HydrationTransactionalPersisting {
            do {
                let result = try transactional.add(milliliters, expectedRevision: nil, expectedDayStart: nil, requestID: UUID(), at: date, calendar: calendar)
                guard let addition = result.lastAddition else { throw HydrationTransactionError.verificationFailed }
                accept(result)
                let receipt = HydrationQuickLogReceipt(date: addition.date, previousMilliliters: addition.previousMilliliters,
                    savedMilliliters: addition.savedMilliliters, dayStart: addition.dayStart, transactionID: addition.id,
                    transaction: addition)
                onConfirmedAddition(receipt)
                return receipt
            } catch {
                persistenceErrorMessage = error.localizedDescription
                return nil
            }
        }
        let loaded = store.load()
        let previous: Int
        if let loaded, calendar.isDate(loaded.date, inSameDayAs: date),
           loaded.dayStart == nil || loaded.dayStart == stateDayStart {
            guard loaded.currentMilliliters == state.currentMilliliters else { return nil }
            previous = loaded.currentMilliliters
        } else if loaded != nil {
            previous = 0
        } else {
            previous = state.currentMilliliters
        }
        guard previous <= Int.max - milliliters else { return nil }
        let saved = previous + milliliters
        let snapshot = HydrationStoredState(
            date: date,
            currentMilliliters: saved,
            goalMilliliters: state.goalMilliliters,
            dayStart: stateDayStart
        )
        store.save(snapshot)
        guard store.isAvailable, store.load() == snapshot else {
            persistenceErrorMessage = "Water wasn't saved. Your previous total has been kept. Try again."
            return nil
        }
        persistenceErrorMessage = nil
        state.set(saved)
        let receipt = HydrationQuickLogReceipt(
            date: date,
            previousMilliliters: previous,
            savedMilliliters: saved,
            dayStart: stateDayStart
        )
        onConfirmedAddition(receipt)
        return receipt
    }

    /// Undo is intentionally narrow: it cannot erase a newer water entry or
    /// modify a different day's total after midnight.
    func undoQuickWaterLog(_ receipt: HydrationQuickLogReceipt) -> Bool {
        refreshForCurrentDay()
        if let transactional = store as? any HydrationTransactionalPersisting {
            guard let id = receipt.transactionID else { return false }
            do {
                let result = try transactional.undo(id, at: currentDate(), calendar: calendar)
                accept(result)
                onConfirmedUndo(receipt)
                return true
            } catch { persistenceErrorMessage = error.localizedDescription; return false }
        }
        guard calendar.isDate(receipt.date, inSameDayAs: currentDate()),
              receipt.dayStart == stateDayStart,
              state.currentMilliliters == receipt.savedMilliliters,
              isPersistenceAvailable,
              let store,
              store.isAvailable,
              let current = store.load(),
              calendar.isDate(current.date, inSameDayAs: receipt.date),
              current.dayStart == nil || current.dayStart == stateDayStart,
              current.currentMilliliters == receipt.savedMilliliters,
              current.goalMilliliters == state.goalMilliliters else {
            return false
        }

        let restored = HydrationStoredState(
            date: current.date,
            currentMilliliters: receipt.previousMilliliters,
            goalMilliliters: current.goalMilliliters,
            dayStart: current.dayStart
        )
        store.save(restored)
        guard store.isAvailable, store.load() == restored else { return false }
        state.set(receipt.previousMilliliters)
        onConfirmedUndo(receipt)
        return true
    }

    func undoQuickWaterLog(_ group: HydrationQuickLogGroup) -> Bool {
        if group.receipts.count == 1 { return undoQuickWaterLog(group.latest) }
        refreshForCurrentDay()
        if let transactional = store as? any HydrationTransactionalPersisting {
            let additions = group.receipts.compactMap(\.transaction)
            guard additions.count == group.receipts.count else { return false }
            do {
                accept(try transactional.undoGroup(additions, at: currentDate(), calendar: calendar))
                group.receipts.forEach(onConfirmedUndo)
                return true
            } catch { persistenceErrorMessage = error.localizedDescription; return false }
        }
        let latest = group.latest
        guard let store, isPersistenceAvailable, store.isAvailable,
              group.receipts.allSatisfy({ $0.transaction == nil && $0.dayStart == stateDayStart
                  && calendar.isDate($0.date, inSameDayAs: currentDate()) }),
              let current = store.load(), current.date == latest.date,
              state.currentMilliliters == latest.savedMilliliters,
              current.currentMilliliters == latest.savedMilliliters,
              current.goalMilliliters == state.goalMilliliters,
              current.dayStart == stateDayStart else { return false }
        let restored = HydrationStoredState(date: currentDate(), currentMilliliters: group.first.previousMilliliters,
            goalMilliliters: current.goalMilliliters, dayStart: stateDayStart)
        store.save(restored)
        guard store.isAvailable, store.load() == restored else { return false }
        state.set(restored.currentMilliliters)
        persistenceErrorMessage = nil
        group.receipts.forEach(onConfirmedUndo)
        return true
    }

    @discardableResult
    func setWater(milliliters: Int) -> Bool {
        let expectedRevision = observedTransactionRevision
        let observedDay = stateDayStart
        refreshForCurrentDay()
        guard milliliters >= 0 else { return false }
        guard let store else { state.set(milliliters); return false }
        guard isPersistenceAvailable, store.isAvailable else { return false }
        if let transactional = store as? any HydrationTransactionalPersisting {
            do {
                // Compare the revision actually observed before reconciliation.
                guard let expectedRevision, observedDay == stateDayStart else { throw HydrationTransactionError.changed }
                accept(try transactional.replace(milliliters, expectedRevision: expectedRevision, at: currentDate(), calendar: calendar))
                return true
            } catch { persistenceErrorMessage = error.localizedDescription }
            return false
        }
        let snapshot = HydrationStoredState(
            date: currentDate(),
            currentMilliliters: milliliters,
            goalMilliliters: state.goalMilliliters,
            dayStart: stateDayStart
        )
        store.save(snapshot)
        guard store.isAvailable, store.load() == snapshot else {
            persistenceErrorMessage = "Water wasn't saved. Your previous total has been kept. Try again."
            return false
        }
        state.set(milliliters)
        persistenceErrorMessage = nil
        return true
    }

    /// Saves only the goal, preserving water additions and their Undo identity.
    @discardableResult
    func setWaterGoal(milliliters: Int, replacing expectedGoal: Int) -> Bool {
        guard milliliters > 0, let store, store.isAvailable else { return false }
        do {
            if let transactional = store as? any HydrationTransactionalPersisting {
                _ = try transactional.setGoal(milliliters, replacing: expectedGoal)
            } else {
                let previous = store.load()
                guard (previous?.goalMilliliters ?? state.goalMilliliters) == expectedGoal else {
                    throw HydrationTransactionError.changed
                }
                let proposed = HydrationStoredState(date: previous?.date ?? currentDate(),
                    currentMilliliters: previous?.currentMilliliters ?? state.currentMilliliters,
                    goalMilliliters: milliliters, dayStart: previous?.dayStart ?? stateDayStart)
                store.save(proposed)
                guard store.isAvailable, store.load() == proposed else { throw HydrationTransactionError.verificationFailed }
            }
            refreshForCurrentDay()
            guard isPersistenceAvailable, state.goalMilliliters == milliliters else { throw HydrationTransactionError.verificationFailed }
            persistenceErrorMessage = nil
            return true
        } catch {
            persistenceErrorMessage = error.localizedDescription
            return false
        }
    }

    func dismissPersistenceError() {
        persistenceErrorMessage = nil
    }

    private func accept(_ result: HydrationTransactionState) {
        observedTransactionRevision = result.revision
        state = HydrationState(currentMilliliters: result.state.currentMilliliters,
            goalMilliliters: result.state.goalMilliliters, recentHistory: state.recentHistory)
        stateDayStart = result.state.dayStart ?? calendar.startOfDay(for: result.state.date)
        isPersistenceAvailable = true
        persistenceErrorMessage = nil
    }
}

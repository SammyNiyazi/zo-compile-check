import AppIntents
import Foundation
import WidgetKit

struct AddWidgetWaterIntent: AppIntent {
    static var title: LocalizedStringResource = "Add water in 01"
    static var openAppWhenRun = false
    static var isDiscoverable = false
    @Parameter(title: "Millilitres") var amount: Int
    @Parameter(title: "Displayed revision") var revision: String
    @Parameter(title: "Displayed day") var dayStart: Date
    @Parameter(title: "Request") var request: String

    init() { }
    init(amount: Int, revision: UUID, dayStart: Date, requestID: UUID) {
        self.amount = amount
        self.revision = revision.uuidString
        self.dayStart = dayStart
        self.request = requestID.uuidString
    }

    func perform() async throws -> some IntentResult {
        do {
            guard [250, 500, 750].contains(amount), let revision = UUID(uuidString: revision),
                  let requestID = UUID(uuidString: request) else {
                throw HydrationTransactionError.invalidAmount
            }
            _ = try SharedHydrationStore().add(amount, expectedRevision: revision, expectedDayStart: dayStart, requestID: requestID,
                                               at: .now, calendar: .autoupdatingCurrent)
            WidgetWaterFeedback.write("")
        } catch {
            WidgetWaterFeedback.write("Water not added. Refresh or open 01.")
        }
        for kind in DailyWidgetSnapshot.Kind.allCases { WidgetCenter.shared.reloadTimelines(ofKind: kind.rawValue) }
        return .result()
    }
}

struct UndoWidgetWaterIntent: AppIntent {
    static var title: LocalizedStringResource = "Undo water in 01"
    static var openAppWhenRun = false
    static var isDiscoverable = false
    @Parameter(title: "Water entry") var receipt: String
    @Parameter(title: "Added at") var addedAt: Date

    init() { }
    init(receipt: HydrationAddition) {
        self.receipt = receipt.id.uuidString
        self.addedAt = receipt.date
    }

    func perform() async throws -> some IntentResult {
        do {
            let now = Date.now
            guard let id = UUID(uuidString: receipt), addedAt <= now, now.timeIntervalSince(addedAt) < 900 else {
                throw HydrationTransactionError.expired
            }
            _ = try SharedHydrationStore().undo(id, at: now, calendar: .autoupdatingCurrent)
            WidgetWaterFeedback.write("")
        } catch {
            WidgetWaterFeedback.write("Not undone. Your latest total is kept.")
        }
        for kind in DailyWidgetSnapshot.Kind.allCases { WidgetCenter.shared.reloadTimelines(ofKind: kind.rawValue) }
        return .result()
    }
}

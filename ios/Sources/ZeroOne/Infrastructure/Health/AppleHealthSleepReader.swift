import Foundation
import HealthKit

/// Reads seven nights of sleep stages from Apple Health. Uses the Sleep read access
/// the Health connection already asks for; it never asks for anything new.
struct AppleHealthSleepReader: SleepHistoryReading {
    var store = HKHealthStore()
    var calendar: Calendar = .autoupdatingCurrent

    func readSleepWeek(endingAt date: Date) async throws -> SleepWeek {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw AppleHealthKitError.unavailable
        }
        let todayStart = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .hour, value: -6 - 6 * 24, to: todayStart) ?? todayStart
        let predicate = HKQuery.predicateForSamples(withStart: start, end: date)
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: results as? [HKCategorySample] ?? [])
            }
            store.execute(query)
        }
        let segments = samples.compactMap { sample -> SleepSegment? in
            guard let stage = Self.stage(sample.value) else { return nil }
            return SleepSegment(stage: stage, start: sample.startDate, end: min(sample.endDate, date))
        }
        return SleepWeek.make(samples: segments, today: date, calendar: calendar)
    }

    /// In bed is not sleep, so it is left out.
    static func stage(_ rawValue: Int) -> SleepStage? {
        switch HKCategoryValueSleepAnalysis(rawValue: rawValue) {
        case .awake: .awake
        case .asleepCore: .core
        case .asleepDeep: .deep
        case .asleepREM: .rem
        case .asleepUnspecified: .asleep
        default: nil
        }
    }
}

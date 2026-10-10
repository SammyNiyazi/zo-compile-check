import Foundation
import HealthKit

@MainActor
final class AppleHealthKitService: HealthKitServicing, BodyWeightImporting, StepsHealthServicing {
    private let store: HKHealthStore
    private let calendar: Calendar

    init(store: HKHealthStore = HKHealthStore(), calendar: Calendar = .autoupdatingCurrent) {
        self.store = store
        self.calendar = calendar
    }

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    var isAvailable: Bool { isHealthDataAvailable }

    var isStepsAvailable: Bool { isHealthDataAvailable }

    func requestStepsAccess() async -> HealthAuthorizationOutcome {
        guard isHealthDataAvailable else { return .unavailable }
        guard let steps = HKQuantityType.quantityType(forIdentifier: .stepCount),
              let distance = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) else { return .failed }
        do {
            try await store.requestAuthorization(toShare: [], read: [steps, distance])
            return .completed
        } catch let error as HKError {
            switch error.code {
            case .errorAuthorizationDenied, .errorRequiredAuthorizationDenied: return .denied
            case .errorUserCanceled: return .cancelled
            case .errorHealthDataUnavailable: return .unavailable
            default: return .failed
            }
        } catch {
            return .failed
        }
    }

    func readStepsDay(at date: Date) async throws -> StepsDayReading {
        guard isHealthDataAvailable else { throw AppleHealthKitError.unavailable }
        guard let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount),
              let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) else {
            throw AppleHealthKitError.missingType
        }
        let start = calendar.startOfDay(for: date)
        async let steps = cumulativeQuantity(type: stepsType, unit: .count(), start: start, end: date)
        async let distance = cumulativeQuantity(type: distanceType, unit: .meter(), start: start, end: date)
        async let hours = hourlySteps(type: stepsType, start: start, end: date)
        return try await StepsDayReading(readAt: date, dayStart: start, totalSteps: steps, distanceMeters: distance, hours: hours)
    }

    private func hourlySteps(type: HKQuantityType, start: Date, end: Date) async throws -> [(Date, Double?)] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
        let healthStore = store
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type, quantitySamplePredicate: predicate,
                options: .cumulativeSum, anchorDate: start,
                intervalComponents: DateComponents(hour: 1)
            )
            query.initialResultsHandler = { query, collection, error in
                // This is a foreground snapshot, not a background observation stream.
                healthStore.stop(query)
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var values: [(Date, Double?)] = []
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    guard statistics.startDate < end, statistics.endDate > start else { return }
                    values.append((statistics.startDate, statistics.sumQuantity()?.doubleValue(for: .count())))
                }
                continuation.resume(returning: values)
            }
            healthStore.execute(query)
        }
    }

    func latestReadingAfterAuthorization() async throws -> ImportedBodyWeight? {
        guard isHealthDataAvailable else { throw BodyWeightImportError.unavailable }
        guard let bodyMass = HKQuantityType.quantityType(forIdentifier: .bodyMass) else {
            throw BodyWeightImportError.missingType
        }

        // Ask only when the person taps Fill from Apple Health, and only for body mass.
        // A successful request does not prove read access was granted.
        try await store.requestAuthorization(toShare: [], read: [bodyMass])
        return try await latestBodyWeightReading()
    }

    /// Reads the scope already requested by onboarding. Never opens another permission prompt.
    func latestBodyWeightReading() async throws -> ImportedBodyWeight? {
        guard isHealthDataAvailable else { throw BodyWeightImportError.unavailable }
        guard let bodyMass = HKQuantityType.quantityType(forIdentifier: .bodyMass) else {
            throw BodyWeightImportError.missingType
        }
        let readings: [HKQuantitySample] = try await samples(
            type: bodyMass,
            predicate: HKQuery.predicateForSamples(withStart: nil, end: Date(), options: .strictEndDate),
            limit: 1,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        )
        guard let sample = readings.first else { return nil }
        let kilograms = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
        guard let reading = ImportedBodyWeight(kilograms: kilograms, recordedAt: sample.endDate) else {
            throw BodyWeightImportError.invalidSample
        }
        return reading
    }

    /// Nil is no readable sample, not proof that the person denied access.
    func latestHeightReading() async throws -> BodyHeightMeasurement? {
        guard isHealthDataAvailable else { throw BodyWeightImportError.unavailable }
        guard let height = HKQuantityType.quantityType(forIdentifier: .height) else {
            throw BodyWeightImportError.missingType
        }
        let readings: [HKQuantitySample] = try await samples(
            type: height,
            predicate: HKQuery.predicateForSamples(withStart: nil, end: Date(), options: .strictEndDate),
            limit: 1,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        )
        guard let sample = readings.first else { return nil }
        let result = BodyHeightMeasurement(centimeters: sample.quantity.doubleValue(for: .meterUnit(with: .centi)),
            recordedAt: sample.endDate, source: .appleHealth)
        guard result.isValid else { throw BodyWeightImportError.invalidSample }
        return result
    }

    func requestAuthorization(for scope: HealthAuthorizationScope) async -> HealthAuthorizationOutcome {
        guard isHealthDataAvailable else { return .unavailable }

        let readTypes = Set(scope.readTypes.compactMap(healthKitType(for:)))
        guard readTypes.count == scope.readTypes.count else { return .failed }

        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            return .completed
        } catch let error as HKError {
            switch error.code {
            case .errorAuthorizationDenied, .errorRequiredAuthorizationDenied:
                return .denied
            case .errorUserCanceled:
                return .cancelled
            case .errorHealthDataUnavailable:
                return .unavailable
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    func readContext(at date: Date) async throws -> HealthContext {
        guard isHealthDataAvailable else { throw AppleHealthKitError.unavailable }
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount),
              let activeEnergyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
              let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw AppleHealthKitError.missingType
        }

        let startOfDay = calendar.startOfDay(for: date)
        let startOfSleepWindow = calendar.date(byAdding: .hour, value: -18, to: startOfDay) ?? startOfDay
        let endOfSleepWindow = calendar.date(byAdding: .hour, value: 12, to: startOfDay) ?? date

        async let steps = cumulativeQuantity(
            type: stepType,
            unit: .count(),
            start: startOfDay,
            end: date
        )
        async let activeEnergy = cumulativeQuantity(
            type: activeEnergyType,
            unit: .kilocalorie(),
            start: startOfDay,
            end: date
        )
        async let workout = mostRecentWorkout(before: date)
        async let sleep = sleepDuration(
            type: sleepType,
            start: startOfSleepWindow,
            end: min(date, endOfSleepWindow)
        )

        return try await HealthContext(
            todaySteps: steps,
            todayActiveEnergyKilocalories: activeEnergy,
            mostRecentWorkout: workout,
            lastNightSleepDurationSeconds: sleep,
            refreshedAt: date,
            dayStart: startOfDay
        )
    }

    private func healthKitType(for type: HealthReadDataType) -> HKObjectType? {
        switch type {
        case .stepCount:
            HKQuantityType.quantityType(forIdentifier: .stepCount)
        case .activeEnergy:
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
        case .workouts:
            HKObjectType.workoutType()
        case .sleepAnalysis:
            HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)
        case .bodyMass:
            HKQuantityType.quantityType(forIdentifier: .bodyMass)
        case .height:
            HKQuantityType.quantityType(forIdentifier: .height)
        case .distanceWalkingRunning:
            HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)
        }
    }

    private func cumulativeQuantity(
        type: HKQuantityType,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> Double? {
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: [.strictStartDate, .strictEndDate]
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func mostRecentWorkout(before date: Date) async throws -> HealthWorkoutContext? {
        let predicate = HKQuery.predicateForSamples(
            withStart: nil,
            end: date,
            options: .strictEndDate
        )
        let samples: [HKWorkout] = try await samples(
            type: .workoutType(),
            predicate: predicate,
            limit: 1,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        )
        guard let workout = samples.first else { return nil }

        return HealthWorkoutContext(
            activityName: activityName(for: workout.workoutActivityType),
            startedAt: workout.startDate,
            durationSeconds: workout.duration
        )
    }

    private func sleepDuration(
        type: HKCategoryType,
        start: Date,
        end: Date
    ) async throws -> TimeInterval? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let sleepSamples: [HKCategorySample] = try await samples(
            type: type,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        )
        let intervals = sleepSamples.compactMap { sample -> DateInterval? in
            guard isAsleep(sample.value) else { return nil }
            let clippedStart = max(sample.startDate, start)
            let clippedEnd = min(sample.endDate, end)
            guard clippedEnd > clippedStart else { return nil }
            return DateInterval(start: clippedStart, end: clippedEnd)
        }
        guard !intervals.isEmpty else { return nil }
        return mergedDuration(of: intervals)
    }

    private func samples<Sample: HKSample>(
        type: HKSampleType,
        predicate: NSPredicate?,
        limit: Int,
        sortDescriptors: [NSSortDescriptor]?
    ) async throws -> [Sample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: sortDescriptors
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples as? [Sample] ?? [])
            }
            store.execute(query)
        }
    }

    private func isAsleep(_ rawValue: Int) -> Bool {
        switch HKCategoryValueSleepAnalysis(rawValue: rawValue) {
        case .asleep, .asleepCore, .asleepDeep, .asleepREM:
            true
        default:
            false
        }
    }

    private func mergedDuration(of intervals: [DateInterval]) -> TimeInterval {
        let ordered = intervals.sorted { $0.start < $1.start }
        guard var current = ordered.first else { return 0 }
        var duration: TimeInterval = 0

        for interval in ordered.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                duration += current.duration
                current = interval
            }
        }
        return duration + current.duration
    }

    private func activityName(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .traditionalStrengthTraining: "Strength training"
        case .functionalStrengthTraining: "Functional strength training"
        case .running: "Run"
        case .walking: "Walk"
        case .cycling: "Cycling"
        case .swimming: "Swim"
        case .highIntensityIntervalTraining: "Interval training"
        case .yoga: "Yoga"
        default: "Workout"
        }
    }
}

private enum AppleHealthKitError: Error {
    case unavailable
    case missingType
}

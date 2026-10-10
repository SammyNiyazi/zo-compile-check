import Foundation
import XCTest
@testable import ZeroOne

final class WorkoutLocalizationTests: XCTestCase {
    private func copy(_ language: AppLanguage) -> WorkoutLocalization {
        WorkoutLocalization(localization: AppLocalization(language: language))
    }

    func testActualBundledZeroOneAndMultipleCountsInBothLanguages() throws {
        for language in AppLanguage.allCases {
            _ = try XCTUnwrap(Bundle.main.url(forResource: language.rawValue, withExtension: "lproj"))
        }
        for (kind, english, bulgarian) in [
            (WorkoutLocalization.Quantity.sets, ["0 sets", "1 set", "2 sets"], ["0 серии", "1 серия", "2 серии"]),
            (.reps, ["0 reps", "1 rep", "2 reps"], ["0 повторения", "1 повторение", "2 повторения"]),
            (.seconds, ["0 seconds", "1 second", "2 seconds"], ["0 секунди", "1 секунда", "2 секунди"]),
            (.exercises, ["0 exercises", "1 exercise", "2 exercises"], ["0 упражнения", "1 упражнение", "2 упражнения"])
        ] {
            for count in 0 ... 2 {
                XCTAssertEqual(copy(.english).quantity(count, kind), english[count])
                XCTAssertEqual(copy(.bulgarian).quantity(count, kind), bulgarian[count])
            }
        }
    }

    func testMaximumIntegerIsNotRoundedOrTruncated() {
        XCTAssertEqual(copy(.english).quantity(Int.max, .sets), "\(Int.max) sets")
        XCTAssertEqual(copy(.bulgarian).quantity(Int.max, .sets), "\(Int.max) серии")
    }

    func testExplicitTimeAndPerSideDoNotTurnIntoRepetitions() {
        let timed = CompletedSet(load: Load(0, unit: .kilograms), reps: 0,
                                 completedAt: Date(timeIntervalSince1970: 42), durationSeconds: 61, isPerSide: true)
        XCTAssertEqual(copy(.english).performance(timed), "61 seconds per side")
        XCTAssertEqual(copy(.bulgarian).performance(timed), "61 секунди на страна")
        XCTAssertEqual(copy(.bulgarian).duration(61), "1 минута, 1 секунда")
        XCTAssertEqual(copy(.english).duration(60), "1 minute")
        XCTAssertEqual(copy(.bulgarian).duration(0), "0 секунди")
    }

    func testLegacyUnknownSideIsNotInferredAndRIRIsNotChanged() throws {
        let set = CompletedSet(load: Load(17.125, unit: .pounds), reps: 1, rir: 3,
                               completedAt: Date(timeIntervalSince1970: 99), isPerSide: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(set)
        XCTAssertEqual(copy(.english).performance(set), "1 rep")
        XCTAssertEqual(copy(.bulgarian).performance(set), "1 повторение")
        _ = copy(.bulgarian).savedAnnouncement(setNumber: 2, set: set, restSeconds: 61)
        _ = copy(.english).setSummary(set)
        XCTAssertEqual(try encoder.encode(set), before)
        XCTAssertEqual(try JSONDecoder().decode(CompletedSet.self, from: before), set)
        XCTAssertNil(set.isPerSide)
        XCTAssertNil(set.durationSeconds)
        XCTAssertEqual(set.rir, 3)
    }

    func testRangeAndSideRemainTypedAndLossless() throws {
        let prescription = WorkingSetPrescription(unit: .seconds, lowerBound: 20, upperBound: 40, perSide: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(prescription)
        XCTAssertEqual(copy(.english).prescription(prescription), "20–40 seconds per side")
        XCTAssertEqual(copy(.bulgarian).prescription(prescription), "20–40 секунди на страна")
        XCTAssertEqual(try encoder.encode(prescription), before)
        XCTAssertEqual(copy(.bulgarian).prescription(.init(unit: .repetitions, lowerBound: 1, upperBound: 1)), "1 повторение")
    }

    func testLoadPrecisionAndRecordedUnitRoundTripInBothLocales() throws {
        for unit in [LoadUnit.kilograms, .pounds] {
            for value in [0.0, 17.125, 12345.6789012345, 0.000000125] {
                let load = Load(value, unit: unit)
                for language in AppLanguage.allCases {
                    let text = copy(language).load(load)
                    XCTAssertTrue(text.hasSuffix(" " + unit.rawValue))
                    let number = String(text.dropLast(unit.rawValue.count + 1))
                        .replacingOccurrences(of: language.locale.decimalSeparator ?? ".", with: ".")
                    XCTAssertEqual(try XCTUnwrap(Double(number)), value)
                }
                XCTAssertEqual(load.unit, unit)
                XCTAssertEqual(load.value, value)
            }
        }
    }

    func testDraftIsVerbatimAndNotParsedOrRounded() {
        XCTAssertEqual(copy(.bulgarian).draftPerformance("001,50%@", isTimed: true, perSide: true), "001,50%@ секунди на страна")
    }

    func testAuthoredNameAndPercentTokensAreVerbatimArguments() {
        let name = "Set saved 50% %@ %2$lld 🏋️"
        XCTAssertEqual(copy(.bulgarian).primaryTitle(.startSet(number: 1, exerciseName: name)), "Започни " + name)
        XCTAssertEqual(copy(.english).primaryTitle(.startSet(number: 1, exerciseName: name)), "Start " + name)
        XCTAssertEqual(copy(.bulgarian).primaryTitle(.logSet(number: 2)), "Запиши серия 2")
    }

    func testKnownDifficultyAndUnknownFutureValueFallback() {
        XCTAssertEqual(copy(.bulgarian).difficulty("beginner"), "Начинаещи")
        XCTAssertEqual(copy(.english).difficulty("advanced"), "Advanced")
        XCTAssertEqual(copy(.bulgarian).difficulty("new_band"), "New Band")
    }

    func testEndAndHistoryCopyKeepsPartialCounts() {
        XCTAssertEqual(copy(.bulgarian).savedProgress(1, of: 3), "Записани 1 от 3 серии")
        XCTAssertEqual(copy(.english).historyAnnouncement(savedSetCount: 1, plannedSetCount: 3), "Workout saved to History. Partial, 1 of 3 sets.")
        XCTAssertTrue(copy(.bulgarian).endMessage(saved: 1, exercises: 1, planned: 3).contains("Незаписани планирани серии: 2."))
        XCTAssertEqual(copy(.english).endMessage(saved: 0, exercises: 0, planned: 3), "Nothing is logged yet, so ending now leaves no record for today.")
    }

    func testReorderedTranslationAndMalformedSignatureEnglishFallback() throws {
        let bundle = try formatBundle()
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL) }
        let localization = AppLocalization(language: .bulgarian, bundle: bundle)
        XCTAssertEqual(localization.format("Order %1$@ %2$lld", .text("50% %@ %2$lld"), .integer(Int.max)), "\(Int.max) → 50% %@ %2$lld")
        XCTAssertEqual(localization.format("Broken %1$lld", .integer(2)), "Broken 2")
        XCTAssertEqual(localization.format("Duplicate %1$@", .text("raw")), "Duplicate raw")
        XCTAssertEqual(localization.format("Unknown %1$lld", .integer(1)), "Unknown 1")
        XCTAssertEqual(localization.format("Escaped %% %1$@", .text("%")), "Escaped % %")
    }

    func testWrongTypeArityAndUnsupportedFormatFailSafely() {
        let localization = AppLocalization.english
        XCTAssertEqual(localization.format("%1$lld", .text("1")), "%1$lld")
        XCTAssertEqual(localization.format("%1$@", .text("one"), .text("two")), "%1$@")
        XCTAssertEqual(localization.format("%2$@", .text("one")), "%2$@")
        XCTAssertEqual(localization.format("%1$lld %d", .integer(1)), "%1$lld %d")
    }

    private func formatBundle() throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutFormat-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "app.the01.workout-format.\(UUID().uuidString)", "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "BNDL"], format: .xml, options: 0).write(to: directory.appendingPathComponent("Info.plist"))
            for (language, strings) in [
                ("en", #""Order %1$@ %2$lld" = "Order %1$@ %2$lld"; "Broken %1$lld" = "Broken %1$lld"; "Duplicate %1$@" = "Duplicate %1$@";"#),
                ("bg", #""Order %1$@ %2$lld" = "%2$lld → %1$@"; "Broken %1$lld" = "Wrong %1$@"; "Duplicate %1$@" = "%1$@ %1$@";"#)
            ] {
                let folder = directory.appendingPathComponent(language + ".lproj")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try strings.write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
            }
            return try XCTUnwrap(Bundle(url: directory))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

import Foundation
import XCTest
@testable import ZeroOne

final class OnboardingWeightMessagePresentationTests: XCTestCase {
    func testExactSuccessUsesActualReadingDateInSelectedBulgarianLocale() throws {
        let reading = try sample(at: 1_780_488_000)
        let output = ZeroOneOnboardingWeightMessagePresentation.message(
            sourceSuccess(reading), importedBodyWeight: reading,
            localization: AppLocalization(language: .bulgarian)
        )
        let date = reading.recordedAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLanguage.bulgarian.locale)
        )
        XCTAssertEqual(output, "Попълнено от вашата стойност в Apple Health от \(date). Прегледайте я, преди да запазите.")
    }

    func testSuccessWithoutRetainedMetadataKeepsOriginalMessage() throws {
        let reading = try sample(at: 1_780_488_000)
        let source = sourceSuccess(reading)
        XCTAssertEqual(ZeroOneOnboardingWeightMessagePresentation.message(
            source, importedBodyWeight: nil, localization: AppLocalization(language: .bulgarian)
        ), source)
    }

    func testStaleSuccessCannotBeReplacedUsingAnotherRetainedReadingDate() throws {
        let earlier = try sample(at: 1_780_488_000)
        let later = try sample(at: 1_787_488_000)
        let source = sourceSuccess(earlier)
        XCTAssertEqual(ZeroOneOnboardingWeightMessagePresentation.message(
            source, importedBodyWeight: later, localization: AppLocalization(language: .bulgarian)
        ), source)
    }

    func testRetainedMetadataDoesNotReplaceStaticFailureWithSuccess() throws {
        let reading = try sample(at: 1_780_488_000)
        let source = "01 couldn't read a body-weight sample right now. Your manual entry has not changed."
        XCTAssertEqual(ZeroOneOnboardingWeightMessagePresentation.message(
            source, importedBodyWeight: reading, localization: AppLocalization(language: .bulgarian)
        ), "01 не можа да прочете стойност на телесното тегло в момента. Ръчно въведената стойност не е променена.")
    }

    func testUnknownDiagnosticWithPercentTokensRemainsVerbatim() throws {
        let reading = try sample(at: 1_780_488_000)
        let source = "Unknown diagnostic 50% %@ %1$@"
        XCTAssertEqual(ZeroOneOnboardingWeightMessagePresentation.message(
            source, importedBodyWeight: reading, localization: AppLocalization(language: .bulgarian)
        ), source)
    }

    private func sample(at seconds: TimeInterval) throws -> ImportedBodyWeight {
        try XCTUnwrap(ImportedBodyWeight(kilograms: 75, recordedAt: Date(timeIntervalSince1970: seconds)))
    }

    private func sourceSuccess(_ reading: ImportedBodyWeight) -> String {
        "Filled from your Apple Health reading on \(reading.recordedAt.formatted(date: .abbreviated, time: .omitted)). Review it before saving."
    }
}

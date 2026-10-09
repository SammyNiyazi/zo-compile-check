import Foundation
import XCTest
@testable import ZeroOne

final class AppLocalizationTests: XCTestCase {
    func testSelectedLanguageBundleOverridesProcessLanguage() throws {
        let bundle = try fixtureBundle(includesBulgarian: true)
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL) }
        XCTAssertEqual(AppLocalization(language: .bulgarian, bundle: bundle).string("Selected language"), "Избран език")
        XCTAssertEqual(AppLocalization(language: .english, bundle: bundle).string("Selected language"), "English choice")
    }

    func testMissingBulgarianKeyFallsBackToEnglishThenCallerFallback() throws {
        let bundle = try fixtureBundle(includesBulgarian: true)
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL) }
        let localization = AppLocalization(language: .bulgarian, bundle: bundle)
        XCTAssertEqual(localization.string("Only English", fallback: "Caller fallback"), "English fallback")
        XCTAssertEqual(localization.string("Missing everywhere", fallback: "Source fallback"), "Source fallback")
        XCTAssertEqual(localization.string("Missing everywhere"), "Missing everywhere")
        XCTAssertEqual(localization.string("Only English", table: "UnknownTable", fallback: "Source fallback"), "Source fallback")
    }

    func testMissingEntireBulgarianBundleUsesEnglish() throws {
        let bundle = try fixtureBundle(includesBulgarian: false)
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL) }
        XCTAssertEqual(AppLocalization(language: .bulgarian, bundle: bundle).string("Selected language"), "English choice")
    }

    func testLookupDoesNotTreatPercentTokensOrUserFallbackAsAFormatString() throws {
        let bundle = try fixtureBundle(includesBulgarian: true)
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL) }
        let source = "My 50% workout, %@, %lld"
        XCTAssertEqual(AppLocalization(language: .bulgarian, bundle: bundle).string("Unknown key", fallback: source), source)
    }

    func testAppResourcesAreBundledAndResolveActualBulgarianCopy() throws {
        // Hosted XCTest must fail if project generation omits the localization tables.
        for language in AppLanguage.allCases {
            let directory = try XCTUnwrap(Bundle.main.url(forResource: language.rawValue, withExtension: "lproj"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Localizable.strings").path))
        }
        let bulgarian = AppLocalization(language: .bulgarian)
        XCTAssertEqual(bulgarian.string("Today"), "Днес")
        XCTAssertEqual(bulgarian.string("Language"), "Език")
        XCTAssertEqual(bulgarian.string("Import workout history"), "Импортирай историята на тренировките")
        XCTAssertEqual(bulgarian.string("Review meal"), "Прегледай храненето")
        XCTAssertEqual(AppLocalization(language: .english).string("Language"), "Language")
    }

    private func fixtureBundle(includesBulgarian: Bool) throws -> Bundle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLocalizationTests-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            let info: [String: Any] = [
                "CFBundleIdentifier": "app.the01.localization-fixture.\(UUID().uuidString)",
                "CFBundleDevelopmentRegion": "en",
                "CFBundlePackageType": "BNDL"
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Info.plist"))
            let english = url.appendingPathComponent("en.lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
            try #""Selected language" = "English choice"; "Only English" = "English fallback";"#
                .write(to: english.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
            if includesBulgarian {
                let bulgarian = url.appendingPathComponent("bg.lproj", isDirectory: true)
                try FileManager.default.createDirectory(at: bulgarian, withIntermediateDirectories: true)
                try #""Selected language" = "Избран език";"#
                    .write(to: bulgarian.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
            }
            return try XCTUnwrap(Bundle(url: url))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

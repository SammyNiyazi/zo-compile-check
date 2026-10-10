import SwiftUI
import XCTest
@testable import ZeroOne

@MainActor
final class AppLanguagePreferenceTests: XCTestCase {
    func testMissingAndUnknownPreferencesFollowDeviceLanguage() {
        let rawValues: [String?] = [nil, "", "ar", "future-language"]
        for rawValue in rawValues {
            let preference = AppLanguagePreference.storedValue(rawValue)
            XCTAssertEqual(preference, .system)
            XCTAssertEqual(preference.resolvedLanguage(preferredLanguages: ["bg-BG"]), .bulgarian)
        }
        for preference in AppLanguagePreference.allCases {
            XCTAssertEqual(AppLanguagePreference.storedValue(preference.rawValue), preference)
        }
    }

    func testRegionalAndScriptDeviceLanguagesResolveToSupportedLanguage() {
        for identifier in ["bg", "bg-BG", "bg_BG", "bg-Cyrl-BG"] {
            XCTAssertEqual(AppLanguagePreference.system.resolvedLanguage(preferredLanguages: [identifier]), .bulgarian)
        }
        for identifier in ["en", "en-GB", "en_US", "en-Latn-US"] {
            XCTAssertEqual(AppLanguagePreference.system.resolvedLanguage(preferredLanguages: [identifier]), .english)
        }
    }

    func testUnsupportedFirstDeviceLanguageUsesEnglishInsteadOfSecondaryLanguage() {
        for identifiers in [[], ["ar-SA"], ["fr-FR", "bg-BG"], [""]] {
            XCTAssertEqual(AppLanguagePreference.system.resolvedLanguage(preferredLanguages: identifiers), .english)
        }
    }

    func testExplicitPreferenceOverridesDeviceLanguage() {
        XCTAssertEqual(AppLanguagePreference.english.resolvedLanguage(preferredLanguages: ["bg-BG"]), .english)
        XCTAssertEqual(AppLanguagePreference.bulgarian.resolvedLanguage(preferredLanguages: ["en-US"]), .bulgarian)
        XCTAssertEqual(AppLanguagePreference.bulgarian.resolvedLanguage(preferredLanguages: ["ar-SA"]), .bulgarian)
    }

    func testPreferencePersistsAcrossAppStorageReadersWithoutChangingRecordedData() throws {
        let suite = "AppLanguagePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // The title deliberately matches a static catalog key. Choosing a language
        // must not turn saved/user-authored content into a translated identity.
        let recorded = Data(#"{"id":"kept-id","title":"Workout","completedAt":1791000012.25,"sets":[{"load":52.5,"unit":"kg","reps":7}]}"#.utf8)
        defaults.set(recorded, forKey: "slick.workoutHistory")
        defaults.set("Profile", forKey: "fixture.authoredName")
        defaults.set(1_791_000_012.25, forKey: "fixture.appointmentInstant")
        defaults.set(7, forKey: "fixture.completedSetCount")
        defaults.set("dark", forKey: AppearancePreference.storageKey)
        defaults.set("pink", forKey: AccentPreference.storageKey)
        defaults.set(["bg-BG", "en-US"], forKey: "AppleLanguages")
        let original = defaults.dictionaryRepresentation()

        for choice in AppLanguagePreference.allCases {
            let writer = AppStorage<String>(wrappedValue: "system", AppLanguagePreference.storageKey, store: defaults)
            writer.wrappedValue = choice.rawValue
            let restored = AppStorage<String>(wrappedValue: "system", AppLanguagePreference.storageKey, store: defaults)
            XCTAssertEqual(AppLanguagePreference.storedValue(restored.wrappedValue), choice)
            var after = defaults.dictionaryRepresentation()
            after.removeValue(forKey: AppLanguagePreference.storageKey)
            XCTAssertEqual(after as NSDictionary, original as NSDictionary)
            XCTAssertEqual(defaults.data(forKey: "slick.workoutHistory"), recorded)
        }
    }
}

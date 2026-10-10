import XCTest
@testable import ZeroOne

final class ProfileSettingsPresentationTests: XCTestCase {
    func testDeletionRequiresThePresentedAuthenticationAndIdleStore() {
        let id = UUID()
        let shown = ZeroOneAccountIdentity(id: id, authenticationID: UUID(), email: "test@example.invalid")
        let replacedAuthentication = ZeroOneAccountIdentity(id: id, authenticationID: UUID(), email: shown.email)
        XCTAssertTrue(ProfileSettingsPresentation.canDelete(presented: shown, current: shown, isBusy: false))
        XCTAssertFalse(ProfileSettingsPresentation.canDelete(presented: shown, current: nil, isBusy: false))
        XCTAssertFalse(ProfileSettingsPresentation.canDelete(presented: shown, current: shown, isBusy: true))
        XCTAssertFalse(ProfileSettingsPresentation.canDelete(presented: shown, current: replacedAuthentication, isBusy: false))
    }

    func testDeletionRejectsACompletelyDifferentAccount() {
        let shown = ZeroOneAccountIdentity(id: UUID(), authenticationID: UUID(), email: nil)
        let switched = ZeroOneAccountIdentity(id: UUID(), authenticationID: UUID(), email: nil)
        XCTAssertFalse(ProfileSettingsPresentation.canDelete(presented: shown, current: switched, isBusy: false))
    }

    func testSearchIncludesTranslatedCopyAndEveryWord() {
        let fields = ["Импорт", "Преглед преди промени", "Import", "transfer json"]
        XCTAssertTrue(ProfileSettingsPresentation.matchesSearch(query: "  ИМПОРТ json  ", fields: fields, locale: Locale(identifier: "bg")))
        XCTAssertFalse(ProfileSettingsPresentation.matchesSearch(query: "импорт zip", fields: fields, locale: Locale(identifier: "bg")))
        XCTAssertTrue(ProfileSettingsPresentation.matchesSearch(query: " \n ", fields: fields, locale: Locale(identifier: "bg")))
    }

    func testSearchFoldsAccentsAndCaseWithoutDroppingRequiredTerms() {
        let fields = ["Préférences", "Units and language"]
        XCTAssertTrue(ProfileSettingsPresentation.matchesSearch(query: "PREFERENCES language", fields: fields, locale: Locale(identifier: "en")))
        XCTAssertFalse(ProfileSettingsPresentation.matchesSearch(query: "preferences billing", fields: fields, locale: Locale(identifier: "en")))
    }

    func testGuestDoesNotBecomeAuthenticatedFromVerificationFlag() {
        XCTAssertEqual(ProfileSettingsPresentation.accountStatus(hasIdentity: false, needsVerification: true), "No account")
        XCTAssertEqual(ProfileSettingsPresentation.accountStatus(hasIdentity: true, needsVerification: true), "Reconnect to verify your session.")
        XCTAssertEqual(ProfileSettingsPresentation.accountStatus(hasIdentity: true, needsVerification: false), "Signed in")
    }

    func testUnresolvedBundleVersionIsNeverPresentedAsARelease() {
        XCTAssertNil(ProfileSettingsPresentation.version(version: "$(MARKETING_VERSION)", build: "7"))
        XCTAssertNil(ProfileSettingsPresentation.version(version: "  ", build: "7"))
        XCTAssertNil(ProfileSettingsPresentation.version(version: "0.1.0\n7", build: nil))
        XCTAssertEqual(ProfileSettingsPresentation.version(version: "0.1.0", build: "$(CURRENT_PROJECT_VERSION)"), "0.1.0")
        XCTAssertEqual(ProfileSettingsPresentation.version(version: "0.1.0", build: "7"), "0.1.0 (7)")
    }

    func testBetaAndUncertainAccessDoNotClaimMembership() {
        XCTAssertEqual(ProfileSettingsPresentation.membershipStatus(isBeta: true, access: .member(until: nil)), "Not available in this beta")
        XCTAssertEqual(ProfileSettingsPresentation.membershipStatus(isBeta: false, access: .unknown), "Membership unavailable")
        XCTAssertEqual(ProfileSettingsPresentation.membershipStatus(isBeta: false, access: .billingRetry), "Payment issue")
    }

    func testHelpRoutesContainOnlyPublishedContactsAndNoUserData() {
        XCTAssertEqual(ProfileSettingsHelpLink.founder.url.absoluteString, "mailto:sammy@the01.app")
        XCTAssertEqual(ProfileSettingsHelpLink.support.url.absoluteString, "mailto:hello@the01.app")
        for link in ProfileSettingsHelpLink.allCases {
            XCTAssertNil(URLComponents(url: link.url, resolvingAgainstBaseURL: false)?.query)
        }
    }
}

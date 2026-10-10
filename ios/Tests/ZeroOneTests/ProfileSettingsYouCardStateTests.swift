import XCTest
@testable import ZeroOne

final class ProfileSettingsYouCardStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_460_800)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    func testVerifiedAccessWithoutIssuanceKeepsUnknownNumberSinceAndRecognition() {
        let source = ProfileSettingsYouSnapshot(asOf: now, displayName: "Mira", edition: .pink)
        let state = ProfileSettingsYouCardState(access: .member(until: nil), asOf: now, calendar: calendar)
        let displayed = state.applyingEdition(.chrome, to: source)
        XCTAssertEqual(state.status, .member)
        XCTAssertEqual(displayed.displayName, "Mira")
        XCTAssertEqual(displayed.edition, .chrome)
        XCTAssertNil(displayed.card)
        XCTAssertNil(displayed.month)
    }
    func testUnexpiredTrialUsesObservedEndAndStaleInvalidDatesHoldUnknown() {
        let end = calendar.date(byAdding: .day, value: 2, to: now)!
        XCTAssertEqual(ProfileSettingsYouCardState(access: .trial(until: end), asOf: now, calendar: calendar).status,
                       .trial(daysLeft: 2))
        XCTAssertEqual(ProfileSettingsYouCardState(access: .trial(until: now), asOf: now, calendar: calendar).status, .unknown)
        XCTAssertEqual(ProfileSettingsYouCardState(access: .member(until: now), asOf: now, calendar: calendar).status, .unknown)
        XCTAssertEqual(ProfileSettingsYouCardState(access: .trial(until: Date(timeIntervalSinceReferenceDate: .nan)),
                       asOf: now, calendar: calendar).status, .unknown)
    }
    func testPaymentIssueNeverBecomesLifetimeOrContinuedAccessPromise() {
        for access in [MembershipAccess.billingRetry, .gracePeriod(until: nil), .gracePeriod(until: now)] {
            XCTAssertEqual(ProfileSettingsYouCardState(access: access, asOf: now, calendar: calendar).status, .paymentIssue)
        }
        XCTAssertEqual(ProfileSettingsYouCardState(access: .revoked, asOf: now, calendar: calendar).status, .revoked)
        XCTAssertEqual(ProfileSettingsYouCardState(access: .expired, asOf: now, calendar: calendar).status, .ended)
    }
    func testWeekCodeMatchesActualCanonicalJavaScriptReferenceVectors() {
        let vectors = [
            "1": "11001011010001111001001011111100110",
            "127": "11001011010001111001110100110011011",
            "1001": "11001011010001111110111111101001111",
            "16777215": "11010100101110000110110100111101110"
        ]
        for (number, expected) in vectors {
            XCTAssertEqual(ProfileSettingsYouWeekCode.bits(number: number), expected.map { $0 == "1" })
        }
    }
    func testWeekCodeRejectsAbsentZeroNonNumericAndOutsideProtocolRange() {
        for number in ["", "0", "-1", "1.0", "16777216", "１２７", "000000001"] {
            XCTAssertNil(ProfileSettingsYouWeekCode.bits(number: number))
        }
        XCTAssertEqual(ProfileSettingsYouWeekCode.bits(number: "0127"), ProfileSettingsYouWeekCode.bits(number: "127"))
        XCTAssertEqual(ProfileSettingsYouWeekCode.bits(number: "16777215")?.count, 35)
    }
}

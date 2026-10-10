import XCTest
@testable import ZeroOne

/// Screen 29 rating prompt rules, screen 51 What's New, and the matching theme icons.
final class GapBatchTwoTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "GapBatchTwoTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testRatingPromptAsksOncePerVersionAndNotWithinSixtyDays() throws {
        let store = try defaults()
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let first = ReviewPromptPolicy(defaults: store, version: "1.0")
        XCTAssertTrue(first.shouldAsk(.personalRecord, now: now))
        first.recordAsked(now: now)
        XCTAssertFalse(first.shouldAsk(.clubWelcome, now: now.addingTimeInterval(90 * 86_400)), "Same version never asks twice")
        let next = ReviewPromptPolicy(defaults: store, version: "1.1")
        XCTAssertFalse(next.shouldAsk(.personalRecord, now: now.addingTimeInterval(59 * 86_400)))
        XCTAssertTrue(next.shouldAsk(.personalRecord, now: now.addingTimeInterval(61 * 86_400)))
    }

    func testWhatsNewNeverShowsOnAFirstInstallButShowsOnceAfterAnUpdate() throws {
        let fresh = try defaults()
        let install = WhatsNewPolicy(defaults: fresh, version: "0.1.0", wasSetUpAtLaunch: false)
        XCTAssertNil(install.pending(), "A first install only records the version")
        XCTAssertEqual(fresh.string(forKey: WhatsNewPolicy.lastSeenKey), "0.1.0")

        let updated = try defaults()
        let update = WhatsNewPolicy(defaults: updated, version: "0.1.0", wasSetUpAtLaunch: true)
        let pending = try XCTUnwrap(update.pending())
        XCTAssertEqual(pending.version, "0.1.0")
        XCTAssertEqual(pending.items.count, 3)
        update.markSeen()
        XCTAssertNil(update.pending())

        let later = WhatsNewPolicy(defaults: updated, version: "9.9.9", wasSetUpAtLaunch: true)
        XCTAssertNil(later.pending(), "A version without notes shows nothing")
    }

    @MainActor
    func testEveryThemeHasItsOwnIconAndCoreUsesThePrimaryIcon() {
        XCTAssertNil(DesignThemePreference.core.alternateIconName)
        XCTAssertEqual(DesignThemePreference.retro.alternateIconName, "AppIcon-Retro")
        XCTAssertEqual(DesignThemePreference.freak.alternateIconName, "AppIcon-Freak")
        XCTAssertEqual(DesignThemePreference.princess.alternateIconName, "AppIcon-Princess")
        XCTAssertNil(ThemeAppIcon.iconName(for: .retro, matching: false), "Turning matching off restores the 01 icon")
        XCTAssertEqual(ThemeAppIcon.iconName(for: .freak, matching: true), "AppIcon-Freak")
    }
}

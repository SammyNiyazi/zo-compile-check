import Foundation
import StoreKit
import SwiftUI

/// Screen 29: Apple's own rating prompt, only at peaks, never mid-workout or after
/// an error. Apple decides whether it shows (at most three times a year); this
/// keeps 01 from asking again in the same version or within 60 days.
enum ReviewPeak: String, Codable, Sendable {
    case personalRecord, clubWelcome, membershipStarted, thirdGoalThisWeek
}

struct ReviewPromptPolicy {
    static let minimumDaysBetween = 60
    static let lastAskedKey = "zeroone.review.lastAskedAt"
    static let lastVersionKey = "zeroone.review.lastAskedVersion"

    private let defaults: UserDefaults
    private let version: String

    init(defaults: UserDefaults = .standard,
         version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") {
        self.defaults = defaults
        self.version = version
    }

    func shouldAsk(_ peak: ReviewPeak, now: Date = .now) -> Bool {
        if defaults.string(forKey: Self.lastVersionKey) == version { return false }
        if let last = defaults.object(forKey: Self.lastAskedKey) as? Date,
           now.timeIntervalSince(last) < Double(Self.minimumDaysBetween) * 86_400 { return false }
        return true
    }

    func recordAsked(now: Date = .now) {
        defaults.set(now, forKey: Self.lastAskedKey)
        defaults.set(version, forKey: Self.lastVersionKey)
    }

    /// The write-review page, when the App Store ID is set in Info.plist
    /// (ZeroOneAppStoreID). Empty until the app is on the App Store.
    static var writeReviewURL: URL? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "ZeroOneAppStoreID") as? String,
              !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(id)?action=write-review")
    }
}

private struct ReviewPeakModifier: ViewModifier {
    let peak: ReviewPeak
    let isReached: Bool
    let delay: Duration
    @Environment(\.requestReview) private var requestReview

    func body(content: Content) -> some View {
        content.task(id: isReached) {
            guard isReached else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let policy = ReviewPromptPolicy()
            guard policy.shouldAsk(peak) else { return }
            policy.recordAsked()
            requestReview()
        }
    }
}

extension View {
    /// Asks Apple for the rating prompt once `isReached` turns true, after the
    /// celebration has landed. Leaving the screen first cancels the request.
    func zoReviewPeak(_ peak: ReviewPeak, when isReached: Bool, after delay: Duration = .seconds(2)) -> some View {
        modifier(ReviewPeakModifier(peak: peak, isReached: isReached, delay: delay))
    }
}

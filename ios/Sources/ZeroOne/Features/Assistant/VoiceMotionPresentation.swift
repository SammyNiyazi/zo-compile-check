import Foundation
import CoreGraphics

/// Presentation time only: never driven by audio levels, recognition confidence, or action progress.
enum VoiceMotionPresentation {
    static let breathLeg: TimeInterval = 1.440

    /// CSS alternate animation with cubic-bezier(.45, 0, .55, 1), not a cosine pulse.
    static func barOpacity(elapsed: TimeInterval, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion else { return 1 }
        guard elapsed.isFinite else { return 1 }
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: breathLeg * 2) / breathLeg
        let progress = phase <= 1 ? phase : 2 - phase
        if progress <= 0 { return 0.35 }
        if progress >= 1 { return 1 }
        // Invert the curve's monotonic x component before evaluating its y component.
        var low = 0.0
        var high = 1.0
        for _ in 0..<32 {
            let t = (low + high) / 2
            let inverse = 1 - t
            let x = 3 * inverse * inverse * t * 0.45 + 3 * inverse * t * t * 0.55 + t * t * t
            if x < progress { low = t } else { high = t }
        }
        let t = (low + high) / 2
        let y = 3 * (1 - t) * t * t + t * t * t
        return 0.35 + 0.65 * y
    }

    static func cancelScale(isHot: Bool, reduceMotion: Bool) -> CGFloat {
        isHot && !reduceMotion ? 1.36 : 1
    }
}

/// This small owned table avoids edits to the shared localization catalog.
enum VoiceMotionCopy {
    static func releaseToCancel(_ localization: AppLocalization) -> String {
        localization.string("Let go to cancel", table: "VoiceMotion")
    }

    static func dragToCancel(_ localization: AppLocalization) -> String {
        localization.string("Drag here to cancel", table: "VoiceMotion")
    }
}

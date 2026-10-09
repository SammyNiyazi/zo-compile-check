import Foundation

/// Numerical timing from canonical motion.js. No fixed frame/clipping changes
/// the factual reading; only decorative ring/burst state uses these values.
enum StepsGoalMomentTiming {
    static let close = 0.48
    static let hold = 1.44
    static let fade = 0.24
    static let micro = 0.12
    static let end = close + hold + micro + fade

    /// CSS cubic-bezier timing maps x/time to y/progress, not y(parameter).
    static func curve(_ value: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let x = min(1, max(0, value))
        if x == 0 || x == 1 { return x }
        func coordinate(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        var lower = 0.0, upper = 1.0
        for _ in 0..<40 {
            let t = (lower + upper) / 2
            if coordinate(t, x1, x2) < x { lower = t } else { upper = t }
        }
        return coordinate((lower + upper) / 2, y1, y2)
    }

    static func land(_ t: Double) -> Double { curve(t, 0.2, 0.9, 0.25, 1) }
    static func carry(_ t: Double) -> Double { curve(t, 0.35, 0, 0.1, 1) }
    static func leave(_ t: Double) -> Double { curve(t, 0.4, 0, 1, 1) }

    struct Frame {
        let progress: Double
        let discScale: Double
        let discOpacity: Double
        let ringOpacity: Double
        let onAccent: Bool
        let checkScale: Double
        let checkOpacity: Double
    }

    static func frame(elapsed: Double, fromProgress: Double, reduceMotion: Bool) -> Frame {
        let t = max(0, elapsed)
        if reduceMotion {
            return Frame(progress: 1, discScale: 0, discOpacity: 0, ringOpacity: 1,
                         onAccent: false, checkScale: 1, checkOpacity: min(1, t / micro))
        }
        func overshoot(_ p: Double, peak: Double) -> Double {
            p < 0.7 ? peak * p / 0.7 : peak + (1 - peak) * (p - 0.7) / 0.3
        }
        let startFade = close + hold
        let discScale = t < close ? 0 : overshoot(land((t - close) / 0.36), peak: 1.06)
        let ringOpacity: Double
        if t < close { ringOpacity = 1 }
        else if t < startFade { ringOpacity = max(0, 1 - (t - close) / micro) }
        else { ringOpacity = land((t - startFade) / fade) }
        let check = t < startFade + micro ? 0 : overshoot(land((t - startFade - micro) / fade), peak: 1.12)
        return Frame(progress: fromProgress + (1 - fromProgress) * carry(t / close),
            discScale: discScale, discOpacity: 1 - leave((t - startFade) / fade),
            ringOpacity: ringOpacity, onAccent: t >= close && t < startFade,
            checkScale: check, checkOpacity: 1)
    }
}

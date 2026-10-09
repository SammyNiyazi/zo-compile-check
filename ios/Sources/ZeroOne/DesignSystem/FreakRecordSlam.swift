import CoreText
import SwiftUI

/// Freak's "New PR" slam (study 30 tokens, themes.freak.celebration; themes.js and themes-fx.css):
/// a chrome stamp with sigil wings lands from 1.6x on Brace (quick, 240 ms), the screen shakes
/// 6 pt once (quick, after quick minus tick), and the steel shards follow from ThemeWinRenderer.
/// Reduce Motion: the stamp appears at size, with no shake.
/// The caller owns PR evidence (WorkoutPersonalRecord), the clock and the haptic.
extension ThemeWinTimeline {
    static let brace = (0.45, 0.0, 0.55, 1.0)
    static let freakSlamDuration = 0.24
    static let freakShakeDelay = 0.18
    static let freakShakeDuration = 0.24

    /// The stamp lands at -7 degrees, then rests at its static -6 degrees.
    static func freakSlam(elapsed: Double, reduceMotion: Bool) -> Frame {
        guard !reduceMotion, elapsed.isFinite, elapsed < freakSlamDuration else {
            return Frame(translation: .zero, rotation: -6, scale: 1, opacity: 1)
        }
        let u = eased(max(elapsed, 0) / freakSlamDuration, curve: brace)
        return Frame(translation: .zero, rotation: -7, scale: 1.6 - 0.6 * u, opacity: u)
    }

    /// Five evenly spaced keyframes; Brace eases the whole effect, as in Web Animations.
    static func freakShake(elapsed: Double, reduceMotion: Bool) -> CGSize {
        let t = elapsed - freakShakeDelay
        guard !reduceMotion, t.isFinite, t > 0, t < freakShakeDuration else { return .zero }
        let keys: [CGSize] = [.zero, CGSize(width: -6, height: 3), CGSize(width: 6, height: -3),
            CGSize(width: -3, height: 2), .zero]
        let position = eased(t / freakShakeDuration, curve: brace) * Double(keys.count - 1)
        let index = min(Int(position), keys.count - 2)
        let fraction = position - Double(index)
        let from = keys[index], to = keys[index + 1]
        return CGSize(width: from.width + (to.width - from.width) * fraction,
                      height: from.height + (to.height - from.height) * fraction)
    }
}

/// themes-fx.css --sigil: a 300 x 60 thorned wing pair around a chrome diamond.
struct FreakSigilWings: Shape {
    /// Each wing thorn: a start point and two absolute cubic segments, closed.
    static let thorns: [[CGFloat]] = [
        [144, 30, 118, 22, 78, 12, 18, 28, 70, 20, 116, 28, 144, 35],
        [122, 23, 113, 12, 102, 5, 86, 1, 99, 9, 107, 15, 116, 25],
        [110, 31, 101, 43, 89, 51, 71, 58, 86, 48, 96, 40, 104, 30],
        [66, 20, 59, 13, 52, 9, 42, 7, 51, 12, 56, 16, 61, 22],
        [40, 25, 30, 31, 19, 34, 3, 34, 17, 30, 27, 27, 36, 23],
        [86, 28, 80, 34, 74, 37, 64, 38, 72, 35, 78, 31, 82, 27]
    ]
    static let viewBox = CGSize(width: 300, height: 60)

    static func unitPath() -> Path {
        var path = Path()
        for mirrored in [false, true] {
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: mirrored ? 300 - x : x, y: y) }
            for v in thorns {
                path.move(to: point(v[0], v[1]))
                path.addCurve(to: point(v[6], v[7]), control1: point(v[2], v[3]), control2: point(v[4], v[5]))
                path.addCurve(to: point(v[12], v[13]), control1: point(v[8], v[9]), control2: point(v[10], v[11]))
                path.closeSubpath()
            }
        }
        path.move(to: CGPoint(x: 150, y: 2))
        path.addLine(to: CGPoint(x: 157, y: 30))
        path.addLine(to: CGPoint(x: 150, y: 58))
        path.addLine(to: CGPoint(x: 143, y: 30))
        path.closeSubpath()
        return path
    }

    /// CSS mask "contain": uniform scale, centred.
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.viewBox.width, rect.height / Self.viewBox.height)
        let offset = CGPoint(x: rect.midX - Self.viewBox.width * scale / 2, y: rect.midY - Self.viewBox.height * scale / 2)
        return Self.unitPath().applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offset.x, ty: offset.y))
    }
}

/// themes-fx.css .fx-slam clip-path: 12 pt chamfers on the top-left and bottom-right corners.
struct FreakChamfer: Shape {
    var cut: CGFloat = 12
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
        path.closeSubpath()
        return path
    }
}

/// Decorative and never interactive; drawn in the same host coordinates as the shards.
struct FreakRecordSlam: View {
    let theme: ZeroOneThemeTokens
    let elapsed: Double
    let reduceMotion: Bool

    /// themes-fx.css --chrome: polished steel by night, graphite by day.
    private var chrome: LinearGradient {
        let stops: [Gradient.Stop]
        if theme.colorScheme == .light {
            stops = [.init(color: theme.textSecondary, location: 0), .init(color: theme.textPrimary, location: 0.5),
                .init(color: theme.textSecondary, location: 1)]
        } else {
            stops = zip(ThemeWinGeometry.darkChromeColors, ThemeWinGeometry.darkChromeStops)
                .map { Gradient.Stop(color: Color(zoHex: $0.0), location: $0.1) }
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }

    /// Pirata One at the stamp's fixed 50/54; decorative, so it does not scale with Dynamic Type.
    private var stampFont: Font {
        var spec = ZOThemeTypography.spec(for: .freak, role: .display)
        spec.size = 50; spec.lineHeight = 54
        if let font = try? spec.font(for: .large) { return Font(font) }
        return .system(size: 50, weight: .black)
    }

    var body: some View {
        let frame = ThemeWinTimeline.freakSlam(elapsed: elapsed, reduceMotion: reduceMotion)
        ZStack(alignment: .top) {
            FreakSigilWings()
                .fill(chrome)
                .frame(width: 340, height: 68)
                .offset(y: 78)
            // Verbatim in every language: Pirata One has Latin glyphs only, and the stamp is decorative.
            Text(verbatim: "New PR")
                .font(stampFont)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(theme.onAccent)
                .padding(.top, 4).padding(.bottom, 6).padding(.horizontal, 18)
                .background(chrome, in: FreakChamfer())
                .scaleEffect(frame.scale)
                .rotationEffect(.degrees(frame.rotation))
                .opacity(frame.opacity)
                .offset(y: 84)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

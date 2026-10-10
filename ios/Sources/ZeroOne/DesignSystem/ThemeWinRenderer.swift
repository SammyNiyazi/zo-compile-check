import SwiftUI

/// Eligibility, confirmation, clocks, cleanup and haptics belong to the caller.
/// An origin is mandatory for a goal burst; it is measured in the renderer's host coordinates.
enum ThemeWinTier {
    case major
    case goal(origin: CGPoint)

    var duration: Double {
        switch self { case .major: 1.8; case .goal: 1.2 }
    }
}

enum ThemeWinTimeline {
    struct Frame {
        let translation: CGPoint
        let rotation: Double
        let scale: Double
        let opacity: Double
    }
    struct RingFrame {
        let trim: Double
        let opacity: Double
    }

    static func cleanupDeadline(theme: ZOTheme, tier: ThemeWinTier, reduceMotion: Bool) -> Double {
        if reduceMotion { return theme == .core ? 0 : 1.92 }
        return switch theme {
        case .core: tier.duration + 0.12
        case .retro, .princess: 2.4
        case .freak: 2.16
        }
    }

    static func isActive(theme: ZOTheme, tier: ThemeWinTier, elapsed: Double, reduceMotion: Bool) -> Bool {
        elapsed.isFinite && elapsed >= 0 && elapsed < cleanupDeadline(theme: theme, tier: tier, reduceMotion: reduceMotion)
    }

    /// Effect easing runs before interpolation between keyframe offsets, as in Web Animations.
    static func eased(_ progress: Double, curve: (Double, Double, Double, Double)) -> Double {
        let t = min(max(progress, 0), 1)
        if t == 0 || t == 1 { return t }
        func cubic(_ s: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * a + 3 * (1 - s) * s * s * b + s * s * s
        }
        var lower = 0.0, upper = 1.0
        for _ in 0..<40 {
            let s = (lower + upper) / 2
            if cubic(s, curve.0, curve.2) < t { lower = s } else { upper = s }
        }
        return cubic((lower + upper) / 2, curve.1, curve.3)
    }

    static let land = (0.2, 0.9, 0.25, 1.0)
    static let carry = (0.35, 0.0, 0.1, 1.0)
    static let burst = (0.2, 0.6, 0.4, 1.0)

    static func wrapperOpacity(theme: ZOTheme, elapsed: Double, reduceMotion: Bool) -> Double {
        guard elapsed.isFinite, elapsed >= 0 else { return 0 }
        if reduceMotion { return 1 - min(max((elapsed / 1.92 - 0.7) / 0.3, 0), 1) }
        switch theme {
        case .retro: return 1 - min(max((elapsed / 2.4 - 0.6) / 0.4, 0), 1)
        case .freak: return 1 - min(max((elapsed / 2.16 - 0.75) / 0.25, 0), 1)
        case .core, .princess: return 1
        }
    }

    static func ring(index: Int, elapsed: Double, reduceMotion: Bool) -> RingFrame {
        let baseOpacity = index == 3 ? 0.8 : 1.0
        if reduceMotion { return RingFrame(trim: 1, opacity: baseOpacity) }
        let delay = Double(index) * 0.12
        let drawEnd = delay + 0.48
        // Backwards fill: even delayed rings start invisible, with opacity overridden to1.
        let trim = elapsed < drawEnd ? eased((elapsed - delay) / 0.48, curve: carry) : 1
        if elapsed < drawEnd { return RingFrame(trim: trim, opacity: 1) }
        let pulseEnd = drawEnd + 0.24
        if elapsed >= pulseEnd { return RingFrame(trim: 1, opacity: baseOpacity) }
        let u = eased((elapsed - drawEnd) / 0.24, curve: land)
        let opacity = u < 0.5 ? 1 - 0.45 * u / 0.5 : 0.55 + 0.45 * (u - 0.5) / 0.5
        return RingFrame(trim: 1, opacity: opacity)
    }

    static func sun(elapsed: Double, light: Bool, reduceMotion: Bool) -> Frame {
        let base = light ? 1.0 : 0.85
        if reduceMotion || elapsed >= 0.72 {
            // No forwards fill: daylight returns to CSS opacity1 after the0.85 endpoint.
            return Frame(translation: .zero, rotation: 0, scale: 1, opacity: base)
        }
        let u = eased(elapsed / 0.72, curve: land)
        return Frame(translation: CGPoint(x: 0, y: 40 * (1 - u)), rotation: 0, scale: 1, opacity: 0.85 * u)
    }

    static func sparkle(index: Int, elapsed: Double, reduceMotion: Bool) -> Frame {
        if reduceMotion { return Frame(translation: .zero, rotation: 0, scale: 1, opacity: 1) }
        let u = eased((elapsed - Double(index % 9) * 0.12) / 1.2, curve: land)
        if u <= 0.4 {
            let v = u / 0.4
            return Frame(translation: .zero, rotation: -45 * (1 - v), scale: v, opacity: v)
        }
        let v = (u - 0.4) / 0.6
        return Frame(translation: .zero, rotation: 20 * v, scale: 1 - 0.4 * v, opacity: 1 - v)
    }

    static func shard(_ shard: ThemeWinGeometry.Shard, elapsed: Double, reduceMotion: Bool) -> Frame {
        if reduceMotion {
            return Frame(translation: .zero, rotation: shard.rotation, scale: 1, opacity: shard.opacity)
        }
        let u = eased((elapsed - 0.24) / 1.44, curve: burst)
        if u <= 0.3 {
            let v = u / 0.3
            return Frame(translation: CGPoint(x: -shard.dx * (1 - v), y: -shard.dy * (1 - v)),
                rotation: shard.rotation, scale: 0.3 + 0.7 * v, opacity: 0.9 * v)
        }
        let v = (u - 0.3) / 0.7
        return Frame(translation: CGPoint(x: shard.dx * 0.2 * v, y: (shard.dy * 0.2 + 30) * v),
            rotation: shard.rotation, scale: 1, opacity: 0.9 * (1 - v))
    }

    static func core(_ particle: ThemeWinGeometry.CoreParticle, tier: ThemeWinTier, size: CGSize, elapsed: Double) -> Frame? {
        let t = (elapsed - particle.delay) / (tier.duration - particle.delay)
        // motion.js has no backwards fill, and forwards fill ends at opacity0.
        guard t >= 0 else { return nil }
        let u = eased(t, curve: burst)
        let offset: Double
        let origin: CGPoint
        let fall: Double
        switch tier {
        case .major:
            offset = 0.2
            origin = CGPoint(x: particle.x * size.width, y: -12)
            fall = particle.fall * size.height
        case .goal(let point):
            offset = 0.35
            origin = point
            fall = particle.fall
        }
        let early = min(1, u / offset), late = max(0, (u - offset) / (1 - offset))
        return Frame(translation: CGPoint(x: origin.x + particle.drift * (0.6 * early + 0.4 * late),
            y: origin.y + particle.peak * early + fall * late),
            rotation: particle.spin * (0.4 * early + 0.6 * late), scale: 1, opacity: 1 - late)
    }
}

enum ThemeWinGeometry {
    struct Generator {
        var seed: Int
        mutating func next() -> Double {
            seed = (seed * 9301 + 49297) % 233280
            return Double(seed) / 233280
        }
    }
    struct Sparkle {
        let size: Double
        let leftPercent: Double
        let top: Double
        let index: Int
        func center(hostWidth: Double) -> CGPoint {
            CGPoint(x: hostWidth * leftPercent / 100 + size / 2, y: top + size / 2)
        }
    }
    struct Shard {
        let dx: Double
        let dy: Double
        let height: Double
        let rotation: Double
        let opacity: Double
        let index: Int
        var width: Double { index % 6 == 0 ? 3 : 2 }
        func center(hostWidth: Double) -> CGPoint {
            CGPoint(x: hostWidth / 2 + dx + width / 2, y: 118 + dy + height / 2)
        }
    }
    struct CoreParticle {
        let x: Double
        let drift: Double
        let fall: Double
        let spin: Double
        let delay: Double
        let peak: Double
        let index: Int
        var isMark: Bool { index == 5 || index == 32 || index == 59 }
        func dimensions(tier: ThemeWinTier) -> CGSize {
            if case .major = tier, isMark { return CGSize(width: 10, height: 10) }
            return index % 3 == 0 ? CGSize(width: 7, height: 7) : CGSize(width: 6, height: 10)
        }
    }

    /// JavaScript Math.round ties toward +infinity, including negative coordinates.
    static func jsRound(_ number: Double) -> Double { floor(number + 0.5) }

    static let ringRadii: [Double] = [40, 52, 64, 76]
    static let sunsetBands: [(Double, Double)] = [(0, 0.4), (0.46, 0.62), (0.70, 0.80), (0.90, 1)]
    static let sunsetColors: [UInt32] = [0xFFE9A8, 0xFFC94A, 0xFF8A3D, 0xFF4D6D, 0xC04DFF]
    static let sunsetStops: [Double] = [0, 0.3, 0.55, 0.78, 1]
    static let ringColors: [UInt32] = [0xFFE9A8, 0xFF8A3D, 0xFF4D6D, 0xC04DFF]
    static let ringGlowColors: [UInt32] = [0xFF8A3D, 0xFF4D6D, 0xC04DFF, 0xC04DFF]
    static let ringGlowRadii: [Double] = [6, 6, 8, 10]
    static let darkChromeColors: [UInt32] = [0xFFFFFF, 0xE9ECEF, 0x8D939B, 0x4D535B, 0xE9ECEF, 0xFFFFFF]
    static let darkChromeStops: [Double] = [0, 0.3, 0.5, 0.52, 0.8, 1]

    static let sparkles: [Sparkle] = {
        var rng = Generator(seed: 29)
        return (0..<18).map { index in
            let z = 8 + rng.next() * 16, x = 20 + rng.next() * 350, y = 40 + rng.next() * 300
            // Positive fixed-point percent, matching JavaScript toFixed(2) for these seeded values.
            return Sparkle(size: z, leftPercent: jsRound(x / 393 * 100 * 100) / 100, top: y, index: index)
        }
    }()

    static let shards: [Shard] = {
        var rng = Generator(seed: 11)
        return (0..<40).map { index in
            let angle = rng.next() * .pi * 2, distance = 60 + rng.next() * 150, height = 6 + rng.next() * 12
            let dx = jsRound(cos(angle) * distance), dy = jsRound(sin(angle) * distance * 0.7)
            return Shard(dx: dx, dy: dy, height: height, rotation: jsRound(angle * 180 / .pi + 90),
                opacity: 0.4 + rng.next() * 0.5, index: index)
        }
    }()

    static let majorParticles: [CoreParticle] = {
        var rng = Generator(seed: 7)
        return (0..<80).map { index in
            // Preserve the original workout's seed7 and x/drift/fall/spin/delay draw order.
            CoreParticle(x: rng.next(), drift: (rng.next() - 0.5) * 120, fall: 0.6 + rng.next() * 0.5,
                spin: (rng.next() - 0.5) * 900, delay: rng.next() * 0.36, peak: 0, index: index)
        }
    }()

    static let goalParticles: [CoreParticle] = {
        var rng = Generator(seed: 7)
        return (0..<24).map { index in
            let angle = -.pi / 2 + (rng.next() - 0.5) * 2.2, velocity = 90 + rng.next() * 90
            let fall = 60 + rng.next() * 60, spin = (rng.next() - 0.5) * 900
            return CoreParticle(x: 0, drift: cos(angle) * velocity, fall: fall, spin: spin,
                delay: 0, peak: sin(angle) * velocity, index: index)
        }
    }()

    /// CSS left/top locate the box; transforms rotate about its center, not that top-left point.
    static func boxCenter(topLeft: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: topLeft.x + size.width / 2, y: topLeft.y + size.height / 2)
    }

    static func ringViewport(hostWidth: Double) -> CGRect {
        CGRect(x: hostWidth / 2 - 90, y: 32, width: 180, height: 180)
    }

    static func sparkleViewport(size: Double) -> CGRect {
        CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
    }

    /// The exact four cubic curves in themes.js STAR, not straight-edged star polygons.
    static func sparklePath() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -10))
        path.addCurve(to: CGPoint(x: 10, y: 0), control1: CGPoint(x: 1.2, y: -2.4), control2: CGPoint(x: 2.4, y: -1.2))
        path.addCurve(to: CGPoint(x: 0, y: 10), control1: CGPoint(x: 2.4, y: 1.2), control2: CGPoint(x: 1.2, y: 2.4))
        path.addCurve(to: CGPoint(x: -10, y: 0), control1: CGPoint(x: -1.2, y: 2.4), control2: CGPoint(x: -2.4, y: 1.2))
        path.addCurve(to: CGPoint(x: 0, y: -10), control1: CGPoint(x: -2.4, y: -1.2), control2: CGPoint(x: -1.2, y: -2.4))
        path.closeSubpath()
        return path
    }
}

/// Pure ornaments at caller-supplied elapsed time. No event authority, lifetime or PR claim.
struct ThemeWinRenderer: View {
    let theme: ZeroOneThemeTokens
    let tier: ThemeWinTier
    let elapsed: Double
    let reduceMotion: Bool

    var body: some View {
        Canvas { canvas, size in
            guard ThemeWinTimeline.isActive(theme: theme.designTheme, tier: tier, elapsed: elapsed, reduceMotion: reduceMotion) else { return }
            switch theme.designTheme {
            case .core: if !reduceMotion { drawCore(in: &canvas, size: size) }
            case .retro: drawRetro(in: &canvas, size: size)
            case .princess: drawPrincess(in: &canvas, size: size)
            case .freak: drawFreak(in: &canvas, size: size)
            }
        }
        // CSS wrap opacity applies after the ornaments overlap and composite.
        .compositingGroup()
        .opacity(ThemeWinTimeline.wrapperOpacity(theme: theme.designTheme, elapsed: elapsed, reduceMotion: reduceMotion))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawCore(in canvas: inout GraphicsContext, size: CGSize) {
        // The canonical confetti layer alone has overflow:hidden.
        canvas.clip(to: Path(CGRect(origin: .zero, size: size)))
        let colors = [theme.accentFill, theme.textPrimary, theme.accentFill,
            ZOColor.resolved(ZOColor.Data.protein, in: theme.colorScheme),
            ZOColor.resolved(ZOColor.Data.carbs, in: theme.colorScheme),
            ZOColor.resolved(ZOColor.Data.fat, in: theme.colorScheme), theme.textSecondary]
        let particles: [ThemeWinGeometry.CoreParticle]
        switch tier { case .major: particles = ThemeWinGeometry.majorParticles; case .goal: particles = ThemeWinGeometry.goalParticles }
        for particle in particles {
            guard let frame = ThemeWinTimeline.core(particle, tier: tier, size: size, elapsed: elapsed), frame.opacity > 0 else { continue }
            let dimensions = particle.dimensions(tier: tier)
            let center = ThemeWinGeometry.boxCenter(topLeft: frame.translation, size: dimensions)
            var piece = canvas
            piece.opacity *= frame.opacity
            piece.translateBy(x: center.x, y: center.y)
            piece.rotate(by: .degrees(frame.rotation))
            let rect = CGRect(x: -dimensions.width / 2, y: -dimensions.height / 2, width: dimensions.width, height: dimensions.height)
            if case .major = tier, particle.isMark {
                var mark = piece.resolve(Image("ZeroOneWordmark").renderingMode(.template))
                mark.shading = .color(theme.accentFill)
                piece.draw(mark, in: rect)
            } else {
                let path = particle.index % 3 == 0 ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1.5)
                piece.fill(path, with: .color(colors[particle.index % colors.count]))
            }
        }
    }

    private func drawRetro(in canvas: inout GraphicsContext, size: CGSize) {
        let light = theme.colorScheme == .light
        let frame = ThemeWinTimeline.sun(elapsed: elapsed, light: light, reduceMotion: reduceMotion)
        var sun = canvas
        sun.opacity *= frame.opacity
        sun.translateBy(x: size.width / 2, y: 60 + frame.translation.y)
        if !light { sun.addFilter(.shadow(color: Color(zoHex: 0xFF4D6D).opacity(0.6), radius: 18)) }
        sun.drawLayer { layer in
            layer.opacity = 1
            var cap = Path()
            cap.move(to: CGPoint(x: -110, y: 110))
            cap.addArc(center: CGPoint(x: 0, y: 110), radius: 110,
                startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            cap.closeSubpath()
            var mask = Path()
            for (start, end) in ThemeWinGeometry.sunsetBands {
                mask.addRect(CGRect(x: -110, y: 110 * start, width: 220, height: 110 * (end - start)))
            }
            layer.clip(to: cap)
            layer.clip(to: mask)
            let stops = zip(ThemeWinGeometry.sunsetColors, ThemeWinGeometry.sunsetStops)
                .map { Gradient.Stop(color: Color(zoHex: $0.0), location: $0.1) }
            layer.fill(Path(CGRect(x: -110, y: 0, width: 220, height: 110)),
                with: .linearGradient(Gradient(stops: stops), startPoint: .zero, endPoint: CGPoint(x: 0, y: 110)))
        }
        for index in ThemeWinGeometry.ringRadii.indices {
            let ringFrame = ThemeWinTimeline.ring(index: index, elapsed: elapsed, reduceMotion: reduceMotion)
            guard ringFrame.trim > 0 else { continue }
            var path = Path()
            // SVG circle starts at+x and proceeds clockwise, with no top-origin rotation.
            path.addArc(center: CGPoint(x: size.width / 2, y: 122), radius: ThemeWinGeometry.ringRadii[index],
                startAngle: .zero, endAngle: .degrees(360 * ringFrame.trim), clockwise: false)
            let color = light && index == 0 ? theme.textPrimary : Color(zoHex: ThemeWinGeometry.ringColors[index])
            var ring = canvas
            ring.opacity *= ringFrame.opacity
            // The embedded180×180 SVG clips filtered paint; the sun is a separate HTML object.
            ring.clip(to: Path(ThemeWinGeometry.ringViewport(hostWidth: size.width)))
            ring.drawLayer { layer in
                layer.opacity = 1
                if !light {
                    layer.addFilter(.shadow(color: Color(zoHex: ThemeWinGeometry.ringGlowColors[index]),
                        radius: ThemeWinGeometry.ringGlowRadii[index]))
                }
                layer.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .butt))
            }
        }
    }

    private func drawPrincess(in canvas: inout GraphicsContext, size: CGSize) {
        let colors = [theme.accentFill, Color(zoHex: 0xC9B4FF), Color(zoHex: 0xFFFFFF)]
        let star = ThemeWinGeometry.sparklePath()
        for sparkle in ThemeWinGeometry.sparkles {
            let frame = ThemeWinTimeline.sparkle(index: sparkle.index, elapsed: elapsed, reduceMotion: reduceMotion)
            guard frame.opacity > 0 else { continue }
            let center = sparkle.center(hostWidth: size.width)
            var piece = canvas
            piece.opacity *= frame.opacity
            piece.translateBy(x: center.x, y: center.y)
            piece.rotate(by: .degrees(frame.rotation))
            piece.scaleBy(x: frame.scale, y: frame.scale)
            // Clip the filtered path to its z×z SVG viewport, then transform the whole SVG.
            piece.clip(to: Path(ThemeWinGeometry.sparkleViewport(size: sparkle.size)))
            piece.drawLayer { layer in
                layer.opacity = 1
                if sparkle.index % 3 == 2 { layer.addFilter(.shadow(color: theme.accentFill, radius: 3)) }
                layer.scaleBy(x: sparkle.size / 20, y: sparkle.size / 20)
                layer.fill(star, with: .color(colors[sparkle.index % 3]))
            }
        }
    }

    private func drawFreak(in canvas: inout GraphicsContext, size: CGSize) {
        for shard in ThemeWinGeometry.shards {
            let frame = ThemeWinTimeline.shard(shard, elapsed: elapsed, reduceMotion: reduceMotion)
            guard frame.opacity > 0 else { continue }
            let center = shard.center(hostWidth: size.width)
            var piece = canvas
            piece.opacity *= frame.opacity
            piece.translateBy(x: center.x + frame.translation.x, y: center.y + frame.translation.y)
            piece.rotate(by: .degrees(frame.rotation))
            piece.scaleBy(x: frame.scale, y: frame.scale)
            let rect = CGRect(x: -shard.width / 2, y: -shard.height / 2, width: shard.width, height: shard.height)
            if shard.index % 6 == 0 {
                piece.fill(Path(rect), with: .color(theme.textPrimary))
            } else {
                let stops: [Gradient.Stop]
                if theme.colorScheme == .light {
                    stops = [.init(color: theme.textSecondary, location: 0), .init(color: theme.textPrimary, location: 0.5),
                        .init(color: theme.textSecondary, location: 1)]
                } else {
                    stops = zip(ThemeWinGeometry.darkChromeColors, ThemeWinGeometry.darkChromeStops)
                        .map { Gradient.Stop(color: Color(zoHex: $0.0), location: $0.1) }
                }
                piece.fill(Path(rect), with: .linearGradient(Gradient(stops: stops),
                    startPoint: CGPoint(x: 0, y: -shard.height / 2), endPoint: CGPoint(x: 0, y: shard.height / 2)))
            }
        }
        // PR stamp/wings/host shake require verified PR context; this generic renderer has none.
    }
}

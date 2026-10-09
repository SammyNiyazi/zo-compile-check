import SwiftUI
import UIKit

/// Poster geometry uses a 300 pt design width, matching club.js container units.
/// The composer scales this object; ImageRenderer expands it to exact pixels.
/// The print object deliberately keeps default text scale, unlike the controls.
struct ZOSharePoster: View {
    let payload: ZOSharePayload
    let layout: ZOShareLayout
    let size: ZOShareSize
    let photo: UIImage?
    let localization: AppLocalization
    /// The export renderer passes the composer's setting; the environment value is read-only.
    var reduceMotionOverride: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion
    private var reduceMotion: Bool { reduceMotionOverride ?? environmentReduceMotion }

    static let designWidth: CGFloat = 300
    private let ink = Color(zoHex: 0xF7F6F1)
    private let onyx = Color(zoHex: 0x020202)
    private let signal = ZOColor.Swatch.yellow.fill
    private var height: CGFloat { Self.designWidth / size.aspectRatio }
    private var isOutdoor: Bool { payload.isOutdoor }
    private var isSticker: Bool { layout == .sticker }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            if layout == .recap {
                if size == .story && !reduceMotion { confetti }
                recap
            }
            else {
                if !isSticker { branding }
                if !payload.route.isEmpty { route }
                data
            }
        }
        .frame(width: Self.designWidth, height: height)
        .clipped()
        .environment(\.dynamicTypeSize, .large)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(payload.accessibilityDescription(layout: layout, size: size, localization: localization))
    }

    @ViewBuilder private var background: some View {
        if isSticker { Color.clear }
        else if let photo, layout != .noPhoto && layout != .recap {
            Image(uiImage: photo).resizable().scaledToFill().frame(width: 300, height: height).clipped()
            LinearGradient(stops: [.init(color: onyx.opacity(0.78), location: 0),
                .init(color: onyx.opacity(0.5), location: 0.45), .init(color: .clear, location: 1)],
                startPoint: .bottom, endPoint: .top)
                .frame(width: 300, height: height * 0.52).offset(y: height * 0.48)
        } else if layout == .noPhoto {
            Color(zoHex: 0x121211)
            EllipticalGradient(stops: [.init(color: Color(zoHex: 0x1E2A22), location: 0), .init(color: .clear, location: 0.7)],
                center: UnitPoint(x: 0.3, y: 0.3), startRadiusFraction: 0, endRadiusFraction: 1)
                .scaleEffect(x: 0.6, y: 0.4, anchor: UnitPoint(x: 0.3, y: 0.3))
            streetGrid
        } else {
            onyx
            if layout == .recap {
                // components.css .zo-s14: ellipse 90% × 50% at 85% × 0%,
                // brand ink at 7% alpha, reaching transparent at 70%.
                Canvas { context, dimensions in
                    let radiusX = dimensions.width * 0.9
                    let scaleY = dimensions.height * 0.5 / radiusX
                    context.scaleBy(x: 1, y: scaleY)
                    let bounds = CGRect(x: 0, y: 0, width: dimensions.width, height: dimensions.height / scaleY)
                    context.fill(Path(bounds), with: .radialGradient(
                        Gradient(stops: [.init(color: ink.opacity(0.07), location: 0),
                            .init(color: .clear, location: 0.7)]),
                        center: CGPoint(x: dimensions.width * 0.85, y: 0),
                        startRadius: 0, endRadius: radiusX))
                }.accessibilityHidden(true)
            } else {
            RadialGradient(colors: [ink.opacity(0.07), .clear], center: .topTrailing,
                startRadius: 0, endRadius: 230)
            }
        }
    }

    private var streetGrid: some View {
        Canvas { context, dimensions in
            var path = Path()
            for x in stride(from: CGFloat(0), through: dimensions.width, by: 33) {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: dimensions.height))
            }
            for y in stride(from: CGFloat(0), through: dimensions.height, by: 27) {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: dimensions.width, y: y))
            }
            context.stroke(path, with: .color(ink.opacity(0.07)), lineWidth: 1)
        }.accessibilityHidden(true)
    }

    private func mark(_ side: CGFloat) -> some View {
        Image("ZeroOneWordmark").resizable().renderingMode(.template).scaledToFit()
            .foregroundStyle(signal).frame(width: side, height: side).accessibilityHidden(true)
    }

    private var branding: some View {
        HStack(alignment: .top) {
            mark(22).shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            Spacer()
            Text(verbatim: "the01.app").zoProofText(.mini, size: 11.1, lineHeight: 13, weight: 500)
                .modifier(ZOSharePosterTextShadow(opacity: 0.4, blur: 4))
                .foregroundStyle(ink.opacity(0.85))
        }.padding(14.1)
    }

    private var data: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isSticker { mark(24).padding(.bottom, 3) }
            if isOutdoor { outdoorData }
            else { workoutData }
        }
        .foregroundStyle(ink)
        .frame(width: 268, height: dataHeight, alignment: .bottomLeading)
        .offset(x: 16, y: height - 14.1 - dataHeight)
    }

    private var dataHeight: CGFloat {
        if isOutdoor { return layout == .route ? 74 : (isSticker ? 147 : 123) }
        return layout == .best && payload.best != nil ? 126 : (layout == .clean ? 63 : 118)
    }

    @ViewBuilder private var workoutData: some View {
        if layout == .best, let best = payload.best {
            meta(payload.title + " · " + payload.date)
            HStack(spacing: 6) {
                Image(systemName: "star").font(.system(size: 12))
                Text(verbatim: localization.string("New best")).zoProofText(.caption, size: 12, lineHeight: 16, weight: 600)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .foregroundStyle(onyx).background(signal, in: Capsule()).padding(.top, 10)
            Text(verbatim: best).zoProofText(.section, size: 22, lineHeight: 26, weight: 700, tracking: -0.2)
                .modifier(ZOSharePosterTextShadow(opacity: 0.35, blur: 8))
                .lineLimit(2).minimumScaleFactor(0.7).padding(.top, 8)
        } else {
            Text(verbatim: payload.title).zoProofText(.section, size: layout == .clean ? 18 : 22, lineHeight: 26, weight: 700, tracking: -0.2)
                .modifier(ZOSharePosterTextShadow(opacity: 0.35, blur: 8))
                .lineLimit(2).minimumScaleFactor(0.7)
            meta(payload.date).padding(.top, 2)
            if layout != .clean {
                metricRow(payload.metrics).padding(.top, 10)
                rail.padding(.top, 10)
            }
        }
    }

    @ViewBuilder private var outdoorData: some View {
        let distanceSize: CGFloat = layout == .route ? 36 : (size == .wide ? 42 : 57)
        meta(payload.title + " · " + payload.date)
        if let distance = payload.distance {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: distance)
                    .zoProofText(.timerHero, size: distanceSize,
                        lineHeight: distanceSize * 0.95, weight: 800, width: 75, tracking: -0.6, tabular: true)
                    .modifier(ZOSharePosterTextShadow(opacity: 0.35, blur: 8))
                    .lineLimit(1).minimumScaleFactor(0.65)
                Text(verbatim: payload.distanceUnit ?? "").zoProofText(.label, size: 18, lineHeight: 21, weight: 600)
                    .modifier(ZOSharePosterTextShadow(opacity: 0.35, blur: 8))
                if layout == .route, let time = payload.metrics.first(where: { $0.id == "time" }) {
                    Text(verbatim: time.value).zoProofText(.label, size: 18, lineHeight: 21, weight: 600, tabular: true)
                        .modifier(ZOSharePosterTextShadow(opacity: 0.35, blur: 8))
                        .foregroundStyle(ink.opacity(0.85)).padding(.leading, 6)
                }
            }.padding(.top, 4.5)
        }
        if layout != .route || payload.distance == nil { metricRow(payload.metrics).padding(.top, 10) }
        if let coverage = payload.metrics.first(where: { $0.id == "coverage" }) { meta(coverage.value).padding(.top, 3) }
    }

    private func meta(_ text: String) -> some View {
        Text(verbatim: text).zoProofText(.caption, size: 12, lineHeight: 16, weight: 500)
            .modifier(ZOSharePosterTextShadow(opacity: isSticker ? 0.5 : 0, blur: 6))
            .foregroundStyle(ink.opacity(0.85)).lineLimit(2).minimumScaleFactor(0.7)
    }

    private func metricRow(_ metrics: [ZOShareMetric]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(metrics.filter { $0.id != "coverage" }) { metric in
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: metric.value).zoProofText(.metric, size: 22, lineHeight: 24, weight: 700, width: 85, tabular: true)
                        .modifier(ZOSharePosterTextShadow(opacity: isSticker ? 0.5 : 0, blur: 6))
                        .lineLimit(1).minimumScaleFactor(0.55)
                    Text(verbatim: localization.string(metric.label)).zoProofText(.mini, size: 11, lineHeight: 13, weight: 400)
                        .modifier(ZOSharePosterTextShadow(opacity: isSticker ? 0.5 : 0, blur: 6))
                        .foregroundStyle(ink.opacity(0.78)).lineLimit(2)
                }
            }
        }
    }

    private var rail: some View {
        // Each group represents actual saved sets for one occurrence. No planned
        // sets or six-exercise illustration are substituted for missing facts.
        Canvas { context, dimensions in
            let count = payload.railGroups.reduce(0, +)
            guard count > 0, count <= 1000 else { return }
            let gaps = max(0, payload.railGroups.count - 1)
            let width = max(0, (dimensions.width - CGFloat(gaps) * 3 - CGFloat(count - 1) * 2) / CGFloat(count))
            guard width > 0 else { return }
            var x = CGFloat(0)
            for group in payload.railGroups {
                for _ in 0..<group {
                    context.fill(Path(roundedRect: CGRect(x: x, y: 0, width: width, height: 4.2), cornerRadius: 1), with: .color(ink))
                    x += width + 2
                }
                x += 3
            }
        }.frame(height: 4.2).accessibilityHidden(true)
    }

    private var route: some View {
        let geometry = ZOShareRouteGeometry(size: size, layout: layout)
        return Canvas { context, dimensions in
            for segment in payload.route {
                var path = Path()
                for (index, point) in segment.enumerated() {
                    let position = CGPoint(x: point.x * dimensions.width, y: point.y * dimensions.height)
                    if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                }
                context.stroke(path, with: .color(onyx.opacity(0.55)), style: StrokeStyle(lineWidth: (layout == .stats ? 7 : 5.2) / 100 * dimensions.width, lineCap: .round, lineJoin: .round))
                context.stroke(path, with: .color(signal), style: StrokeStyle(lineWidth: (layout == .stats ? 3.6 : 2.6) / 100 * dimensions.width, lineCap: .round, lineJoin: .round))
            }
            if payload.showsEndpoints, let start = payload.route.first?.first, let end = payload.route.last?.last {
                for (point, color) in [(start, ink), (end, signal)] {
                    let r = dimensions.width * 0.034
                    let dot = Path(ellipseIn: CGRect(x: point.x * dimensions.width - r, y: point.y * dimensions.height - r, width: 2 * r, height: 2 * r))
                    context.fill(dot, with: .color(color)); context.stroke(dot, with: .color(onyx.opacity(0.6)), lineWidth: dimensions.width * 0.014)
                }
            }
        }.frame(width: geometry.side, height: geometry.side).offset(x: geometry.x, y: geometry.y)
            .accessibilityHidden(true)
    }

    private var recap: some View {
        let heroSize: CGFloat = size == .story ? 69 : (size == .post ? 57 : 54)
        return
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                mark(24); Spacer()
                Text(verbatim: "the01.app").zoProofText(.mini, size: 11.1, lineHeight: 13.32, weight: 500)
                    .foregroundStyle(ZOColor.resolved(ZOColor.inkSecondary, in: .dark))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: localization.string("My first")).zoProofText(.label, size: 16.8, lineHeight: 20.16, weight: 600).foregroundStyle(ZOColor.resolved(ZOColor.inkSecondary, in: .dark))
                Text(verbatim: localization.string("14 DAYS")).zoProofText(.timerHero, size: heroSize, lineHeight: heroSize * 0.9, weight: 800, width: 75, tracking: -0.9)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }.padding(.top, size == .story ? 48 : (size == .post ? 21 : 18))
            if size != .square {
                HStack(spacing: 4.2) {
                    ForEach(payload.trainingDays) { day in
                        Circle().fill(day.trained ? ink : Color.clear)
                            .overlay { if !day.trained { Circle().strokeBorder(ZOColor.resolved(ZOColor.surface3, in: .dark), lineWidth: 1.5) } }
                    }
                }.frame(height: 15).padding(.top, 15).accessibilityHidden(true)
            }
            Spacer(minLength: size == .story ? 24 : 15)
            HStack(alignment: .top, spacing: 9) {
                ForEach(payload.metrics) { metric in
                    VStack(alignment: .leading, spacing: 2.4) {
                        Text(verbatim: metric.value).zoProofText(.metric, size: 39, lineHeight: 39, weight: 800, width: 75, tabular: true)
                        Text(verbatim: localization.string(metric.label)).zoProofText(.mini, size: 11.1, lineHeight: 13.32, weight: 500)
                            .foregroundStyle(ZOColor.resolved(ZOColor.inkSecondary, in: .dark))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if size != .square && !payload.lifts.isEmpty {
                VStack(spacing: 9) {
                    ForEach(Array(payload.lifts.prefix(size == .post ? 1 : 3))) { lift in
                        HStack(spacing: 9) {
                            Text(verbatim: lift.name).zoProofText(.caption, size: 12, lineHeight: 14.4, weight: 600)
                                .lineLimit(2).minimumScaleFactor(0.7).frame(width: 45, alignment: .leading)
                            GeometryReader { geometry in
                                Capsule().fill(ZOColor.resolved(ZOColor.surface3, in: .dark))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(ink).frame(width: geometry.size.width * lift.currentFraction)
                                    }
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(onyx).frame(width: 1.8, height: 15)
                                            .offset(x: geometry.size.width * lift.startFraction - 0.9)
                                    }
                            }.frame(height: 7.8)
                            Text(verbatim: lift.values).zoProofText(.caption, size: 12, lineHeight: 14.4, weight: 500, tabular: true)
                                .foregroundStyle(ZOColor.resolved(ZOColor.inkSecondary, in: .dark))
                                .lineLimit(1).minimumScaleFactor(0.7).frame(width: 69, alignment: .trailing)
                        }
                    }
                }.padding(.top, 15)
                    .overlay(alignment: .top) { Rectangle().fill(ZOColor.resolved(ZOColor.surface3, in: .dark)).frame(height: 1) }
                    .padding(.top, 21)
            }
            if payload.bodyWeightChange != nil || payload.nameAndNumber != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let weight = payload.bodyWeightChange {
                        Text(verbatim: weight + " " + localization.string("body weight change"))
                            .zoProofText(.mini, size: 11.1, lineHeight: 13.32, weight: 500)
                    }
                    if let name = payload.nameAndNumber {
                        Text(verbatim: name).zoProofText(.mini, size: 11.1, lineHeight: 13.32, weight: 500)
                    }
                }
                .foregroundStyle(ZOColor.resolved(ZOColor.inkSecondary, in: .dark))
                .padding(.top, 15)
            }
        }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 19.5).foregroundStyle(ink)
    }

    private var confetti: some View {
        ZStack(alignment: .topLeading) {
            ForEach(ZOShareConfettiPiece.proofPieces) { piece in
                Group {
                    if piece.isMark { mark(10) }
                    else if piece.isCircle { Circle().fill(confettiColor(piece.id)).frame(width: 7, height: 7) }
                    else { RoundedRectangle(cornerRadius: 1.5).fill(confettiColor(piece.id)).frame(width: 6, height: 10) }
                }
                .rotationEffect(.degrees(piece.rotation)).opacity(piece.opacity)
                .offset(x: piece.x, y: piece.y)
            }
        }.frame(width: 300, height: height * 0.24, alignment: .topLeading)
            .clipped().offset(y: height * 0.41).accessibilityHidden(true)
    }

    private func confettiColor(_ index: Int) -> Color {
        switch index % 7 {
        case 0, 2: signal
        case 1: ink
        case 3: ZOColor.resolved(ZOColor.Data.protein, in: .dark)
        case 4: ZOColor.resolved(ZOColor.Data.carbs, in: .dark)
        case 5: ZOColor.resolved(ZOColor.Data.fat, in: .dark)
        default: ZOColor.resolved(ZOColor.inkSecondary, in: .dark)
        }
    }
}

/// Apply before caller foregroundStyle so the independent glyph copy receives
/// the CSS shadow color. Background keeps layout unchanged; the shadow is not AX
/// content and cannot receive touches. Native blur-kernel parity remains UNRUN.
private struct ZOSharePosterTextShadow: ViewModifier {
    let opacity: Double
    let blur: CGFloat

    func body(content: Content) -> some View {
        content.background {
            if opacity > 0 {
                content.foregroundStyle(Color.black.opacity(opacity))
                    .blur(radius: blur).offset(y: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

/// Exact deterministic frozen composition from motion.js zoConfettiStatic(240,
/// 170, 22, 53). There is no animation or replayed success event on this poster.
private struct ZOShareConfettiPiece: Identifiable {
    let id: Int; let x: Double; let y: Double; let rotation: Double; let opacity: Double
    var isMark: Bool { id % 23 == 4 }
    var isCircle: Bool { id % 3 == 0 }
    static let proofPieces: [Self] = {
        var seed = 53
        func next() -> Double { seed = (seed * 9301 + 49297) % 233280; return Double(seed) / 233280 }
        return (0..<22).map { id in
            let x = next() * 240, y = next() * 170 * 0.75, rotation = (next() * 360).rounded()
            return Self(id: id, x: x, y: y, rotation: rotation, opacity: id % 23 == 4 ? 1 : 0.55 + next() * 0.45)
        }
    }()
}

struct ZOShareRouteGeometry: Equatable {
    let x: Double; let y: Double; let side: Double
    init(size: ZOShareSize, layout: ZOShareLayout) {
        if layout == .stats {
            side = size == .square || size == .wide ? 66 : 78
            x = 300 - 18 - side
            y = size == .square || size == .wide ? 48 : 300 / size.aspectRatio - 75 - side
        } else if size == .square { x = 78; y = 24; side = 144 }
        else if size == .wide { x = 171; y = 27; side = 108 }
        else { x = 36; y = layout == .sticker ? 30 : 54; side = 228 }
    }
}

struct ZOShareExport {
    let image: UIImage
    let pngData: Data
    let size: ZOShareSize
    let layout: ZOShareLayout
}

enum ZOShareRenderError: Error { case unavailable }

@MainActor
enum ZOShareRenderer {
    static func render(payload: ZOSharePayload, layout: ZOShareLayout, size: ZOShareSize,
                       photo: UIImage?, localization: AppLocalization, reduceMotion: Bool = false) throws -> ZOShareExport {
        let dimensions = size.pixels
        let renderer = ImageRenderer(content: ZOSharePoster(payload: payload, layout: layout, size: size, photo: photo, localization: localization,
                                                         reduceMotionOverride: reduceMotion)
            .scaleEffect(dimensions.width / 300, anchor: .topLeading)
            .frame(width: dimensions.width, height: dimensions.height, alignment: .topLeading))
        renderer.proposedSize = ProposedViewSize(width: dimensions.width, height: dimensions.height)
        renderer.scale = 1
        renderer.isOpaque = layout != .sticker
        guard let image = renderer.uiImage, let png = image.pngData() else { throw ZOShareRenderError.unavailable }
        return ZOShareExport(image: image, pngData: png, size: size, layout: layout)
    }
}

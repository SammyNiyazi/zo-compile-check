import SwiftUI
import CoreText

/// A brand object, independent of the page theme. No photo, sensor or service ownership.
struct ProfileSettingsYouCardView: View {
    let snapshot: ProfileSettingsYouSnapshot
    var tilt: Double = 0
    var playsArrival = true
    var membershipState: ProfileSettingsYouCardState? = nil
    var side: ProfileSettingsYouCardSide = .front
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var width: CGFloat = 353
    @State private var arrived = false
    @State private var sheen = ProfileSettingsYouPresentation.settledSheen

    private var material: ProfileSettingsYouMaterial { .init(edition: snapshot.edition) }
    private var scale: CGFloat { width / 353 }

    var body: some View {
        ProfileSettingsYouCardLayout {
            VStack(alignment: .leading, spacing: side == .back && snapshot.card != nil ? 0 : 10 * scale) {
                header
                Spacer(minLength: 0)
                if side == .back, let card = snapshot.card,
                   let bits = ProfileSettingsYouWeekCode.bits(number: card.number) {
                    weekCode(bits)
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 2 * scale) {
                        Text(verbatim: localization.format("Scan in 01 to train with %1$@", .text(card.holderName)))
                            .youCardText(size: width * 0.048, line: 1.2, style: .section)
                        Text(verbatim: localization.format("Member No. %1$@", .text(card.number)))
                            .youCardText(size: width * 0.0368, line: 1.38, style: .label)
                            .foregroundStyle(material.ink2)
                    }
                } else {
                    identity
                    Spacer(minLength: 0)
                    if let card = snapshot.card { stats(card) }
                }
            }
            .padding(.horizontal, width * 0.057)
            .padding(.vertical, width * 0.051)
            .padding(.bottom, side == .back && snapshot.card != nil ? width * 0.011 : 0)
            .foregroundStyle(material.ink)
        }
        .background {
            ProfileSettingsYouCardMaterial(edition: snapshot.edition,
                sheen: reduceMotion ? ProfileSettingsYouPresentation.settledSheen : sheen,
                isTrial: membershipState?.isTrial == true)
        }
        .clipShape(.rect(cornerRadius: 20))
        .overlay {
            switch snapshot.edition {
            case .pink:
                ProfileSettingsYouInsetEdge(color: .white.opacity(0.50), offset: 1)
            case .chrome:
                ProfileSettingsYouInsetEdge(color: .white.opacity(0.22), offset: 1)
                ProfileSettingsYouInsetEdge(color: .black.opacity(0.40), offset: -1)
            case .onyx, .neon:
                if scheme == .dark {
                    RoundedRectangle(cornerRadius: 20).strokeBorder(Color(zoHex: 0x2D2D2B), lineWidth: 1)
                        .allowsHitTesting(false)
                } else { ProfileSettingsYouInsetEdge(color: .white.opacity(0.06), offset: 1) }
            }
        }
        .overlay {
            if membershipState?.isTrial == true {
                RoundedRectangle(cornerRadius: width * 0.034)
                    .strokeBorder(Color(zoHex: 0xFFFE2A).opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [4.5, 4.5]))
                    .padding(width * 0.023).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .shadow(color: scheme == .light || snapshot.edition == .pink || snapshot.edition == .chrome ? material.shadow : .clear,
                radius: 20, x: 0, y: 18)
        .opacity(membershipState?.status == .ended ? 0.55 : 1)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .rotation3DEffect(.degrees(reduceMotion ? 0 : ProfileSettingsYouPresentation.boundedTilt(tilt)), axis: (x: 0, y: 1, z: 0))
        .onAppear {
            guard !arrived else { return }
            arrived = true
            guard playsArrival && !reduceMotion else { return }
            sheen = -0.30
            withAnimation(ZOMotion.land(ZOMotion.momentum)) { sheen = ProfileSettingsYouPresentation.settledSheen }
        }
        .onChange(of: tilt) {
            guard arrived, !reduceMotion else { return }
            sheen = ProfileSettingsYouPresentation.sheenPosition(tilt: tilt, reduceMotion: false)
        }
        .onChange(of: reduceMotion) {
            if reduceMotion {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { sheen = ProfileSettingsYouPresentation.settledSheen }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(alignment: .top) {
            Image("ZeroOneWordmark")
                .renderingMode(.template).resizable().scaledToFit()
                .frame(width: width * 0.085, height: width * 0.085)
                .foregroundStyle(membershipState?.isTrial == true && snapshot.edition == .onyx ? material.ink : material.mark).accessibilityHidden(true)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(verbatim: "01 Club").youCardText(size: width * 0.0368, line: 1.38, style: .section)
                if side == .back, snapshot.card != nil {
                    Text(verbatim: localization.string("Week code")).youCardText(size: width * 0.0368, line: 1.38, style: .caption)
                } else if membershipState?.isTrial == true {
                    Text(verbatim: localization.string("Trial active")).youCardText(size: width * 0.0368, line: 1.38, style: .caption)
                } else if let crew = snapshot.card?.crew {
                    Text(verbatim: crew).youCardText(size: width * 0.0368, line: 1.38, style: .caption)
                }
            }
            .foregroundStyle(material.ink2)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            if let card = snapshot.card {
                Text(verbatim: card.holderName)
                    .youCardText(size: width * 0.0737, line: 1.15, style: .display, tracking: -0.3)
                Text(verbatim: card.since.map {
                    localization.format("Member No. %1$@ · since %2$@", .text(card.number),
                        .text($0.formatted(.dateTime.month(.abbreviated).year().locale(localization.locale))))
                } ?? localization.format("Member No. %1$@", .text(card.number)))
                    .youCardText(size: width * 0.0368, line: 1.38, style: .label)
                    .foregroundStyle(material.ink2)
                if membershipState?.isTrial == true { membershipLabel } else { badges(card); membershipLabel }
            } else {
                Text(verbatim: snapshot.displayName ?? localization.string("You"))
                    .youCardText(size: width * 0.0737, line: 1.15, style: .display, tracking: -0.3)
                Text(verbatim: localization.string("Member card unavailable"))
                    .youCardText(size: width * 0.0368, line: 1.38, style: .label)
                    .foregroundStyle(material.ink2)
                membershipLabel
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var membershipLabel: some View {
        if case let .trial(days)? = membershipState?.status {
            Text(verbatim: localization.format("Temporary · %1$lld days left", .integer(days)))
                .youCardText(size: width * 0.0312, line: 1.2, style: .section)
                .padding(.horizontal, width * 0.023).padding(.vertical, 3 * scale)
                .overlay(Capsule().strokeBorder(material.mark, lineWidth: 1))
                .padding(.top, width * 0.017)
        } else if let key = membershipState?.statusKey {
            Text(verbatim: localization.string(key))
                .youCardText(size: width * 0.0312, line: 1.2, style: .label)
                .foregroundStyle(material.ink2).padding(.top, width * 0.017)
        }
    }

    private func weekCode(_ bits: [Bool]) -> some View {
        let unit = width * 0.86828 / 616
        var weekCalendar = Calendar(identifier: .gregorian)
        weekCalendar.locale = localization.locale
        let symbols = weekCalendar.veryShortStandaloneWeekdaySymbols
        let weekdays = Array(symbols.dropFirst()) + Array(symbols.prefix(1))
        return VStack(spacing: unit * 8) {
            Canvas { context, size in
                let factor = size.width / 616
                for day in 0..<7 {
                    for segment in 0..<5 {
                        let index = day * 5 + segment
                        let x = CGFloat(day * 90 + segment * 16) * factor
                        let rect = CGRect(x: x, y: 0, width: 12 * factor, height: 30 * factor)
                        context.fill(Path(roundedRect: rect, cornerRadius: 3 * factor),
                            with: .color(material.ink.opacity(bits[index] ? 1 : 0.26)))
                    }
                }
            }.aspectRatio(616.0 / 30, contentMode: .fit).accessibilityHidden(true)
            HStack(spacing: unit * 14) {
                ForEach(weekdays.indices, id: \.self) { index in
                    Text(verbatim: weekdays[index])
                        .youCardText(size: unit * 14, line: 1.2, style: .section)
                        .frame(maxWidth: .infinity).foregroundStyle(material.ink3)
                }
            }.accessibilityHidden(true)
        }.padding(.horizontal, width * 0.00886)
    }

    private func badges(_ card: ProfileSettingsYouVerifiedCard) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: width * 0.016) { recognition(card); sticker(card) }
            VStack(alignment: .leading, spacing: 6 * scale) { recognition(card); sticker(card) }
        }
        .padding(.top, width * 0.017)
    }

    @ViewBuilder private func recognition(_ card: ProfileSettingsYouVerifiedCard) -> some View {
        if let recognition = card.recognition {
            HStack(spacing: width * 0.017) {
                switch recognition {
                case .founder: Text(verbatim: localization.string("Founder"))
                case .foundingMember: Text(verbatim: localization.string("Founding member"))
                case let .partner(tier):
                    Text(verbatim: localization.string("Partner"))
                    HStack(spacing: width * 0.008) {
                        ForEach(1...4, id: \.self) { index in
                            Circle().fill(index <= tier ? badgeInk : .clear)
                                .overlay(Circle().strokeBorder(badgeInk, lineWidth: 1))
                                .frame(width: width * 0.014, height: width * 0.014)
                        }
                    }.accessibilityLabel(localization.format("Tier %1$lld of 4", .integer(tier)))
                }
            }
            .youCardText(size: width * 0.0312, line: 1.2, style: .section)
            .foregroundStyle(badgeInk)
            .padding(.horizontal, width * 0.023)
            .padding(.vertical, 3 * scale)
            .frame(minHeight: width * 0.0623)
            .background(badgeInk.opacity(snapshot.edition == .onyx ? 0.14 : 0.12), in: Capsule())
        }
    }

    @ViewBuilder private func sticker(_ card: ProfileSettingsYouVerifiedCard) -> some View {
        if card.hasFounderSticker {
            Text(verbatim: "01 Daddy")
                .youCardText(size: width * 0.0312, line: 1.2, style: .display)
                .padding(.horizontal, width * 0.023).padding(.vertical, 3 * scale)
                .frame(minHeight: width * 0.0623)
                .overlay(Capsule().strokeBorder(material.ink, lineWidth: 1.5))
                .rotationEffect(.degrees(-4))
        }
    }

    private var badgeInk: Color { snapshot.edition == .onyx ? material.mark : material.ink }

    private func stats(_ card: ProfileSettingsYouVerifiedCard) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: width * 0.051) { statItems(card) }
            } else {
                HStack(alignment: .top, spacing: width * 0.051) { statItems(card) }
            }
        }
    }

    @ViewBuilder private func statItems(_ card: ProfileSettingsYouVerifiedCard) -> some View {
        if let value = card.workouts { stat(value, "workouts") }
        if let value = card.consecutiveWeeks { stat(value, "weeks in a row") }
        if let value = card.personalBests { stat(value, "personal bests") }
    }

    private func stat(_ value: Int, _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value, format: .number.locale(localization.locale))
                .youCardText(size: width * 0.0538, line: 1.16, style: .metric)
            Text(verbatim: localization.string(key))
                .youCardText(size: width * 0.0312, line: 1.2, style: .caption)
                .foregroundStyle(material.ink3)
        }.fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// Zero-blur CSS inset: the rounded silhouette minus its vertically shifted copy.
private struct ProfileSettingsYouInsetEdge: View {
    let color: Color
    let offset: CGFloat
    var body: some View {
        color.mask {
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(.white)
                RoundedRectangle(cornerRadius: 20).fill(.white).offset(y: offset).blendMode(.destinationOut)
            }.compositingGroup()
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Measures content before fixing the design ratio; larger text or long facts grow the card.
private struct ProfileSettingsYouCardLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 353)
        let content = subviews.first?.sizeThatFits(.init(width: width, height: nil)) ?? .zero
        return .init(width: width, height: max(width / 1.586, content.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: .init(width: bounds.width, height: bounds.height))
    }
}

/// Reuses the exact registered variable font descriptor/axes. Uncapped Dynamic Type scaling
/// applies here even to metrics, whose shared screen style otherwise caps at xxxLarge.
private struct ProfileSettingsYouCardText: ViewModifier {
    let size: CGFloat
    let line: CGFloat
    let style: ZOTextStyle
    let tracking: CGFloat
    @ScaledMetric(relativeTo: .body) private var dynamicScale = 1.0
    func body(content: Content) -> some View {
        let base = style.ctFont(for: .large)
        let font = CTFontCreateCopyWithAttributes(base, size * dynamicScale, nil, nil)
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        content.font(Font(font).monospacedDigit()).tracking(tracking)
            .lineSpacing(max(0, size * dynamicScale * line - natural))
    }
}
private extension View {
    func youCardText(size: CGFloat, line: CGFloat, style: ZOTextStyle, tracking: CGFloat = 0) -> some View {
        modifier(ProfileSettingsYouCardText(size: size, line: line, style: style, tracking: tracking))
    }
}

/// Scoped material adapter: generated DesignTokens has no brandObject.editions API.
private struct ProfileSettingsYouMaterial {
    let stops: [UInt32]
    let inkHex: UInt32
    let ink2Hex: UInt32
    let ink3Hex: UInt32
    let markHex: UInt32
    let shine: Double
    let shadow: Color
    var ink: Color { Color(zoHex: inkHex) }
    var ink2: Color { Color(zoHex: ink2Hex) }
    var ink3: Color { Color(zoHex: ink3Hex) }
    var mark: Color { Color(zoHex: markHex) }
    init(edition: ProfileSettingsYouEdition) {
        switch edition {
        case .onyx:
            stops = [0x121211, 0x020202, 0x0A0A09, 0x121211]
            (inkHex, ink2Hex, ink3Hex, markHex, shine) = (0xF7F6F1, 0xB5B4B1, 0x9B9A97, 0xFFFE2A, 0.16)
            shadow = Color(zoHex: 0x020202, alpha: 0.28)
        case .pink:
            stops = [0xFFC2E3, 0xFF9AD5, 0xF2C3EA, 0xE3C9F5]
            (inkHex, ink2Hex, ink3Hex, markHex, shine) = (0x22091B, 0x4D2442, 0x5E3253, 0x020202, 0.42)
            shadow = Color(zoHex: 0xFF9AD5, alpha: 0.30)
        case .chrome:
            stops = [0x16171A, 0x25282D, 0x040405, 0x1A1C20]
            (inkHex, ink2Hex, ink3Hex, markHex, shine) = (0xF4F4F0, 0xD2D4D8, 0xC2C5CA, 0xF7F6F1, 0.20)
            shadow = .black.opacity(0.30)
        case .neon:
            stops = [0x120A16, 0x060307, 0x0E0812, 0x120A16]
            (inkHex, ink2Hex, ink3Hex, markHex, shine) = (0xFFF1D6, 0xE2BFD0, 0xC59DB6, 0xF7F6F1, 0.14)
            shadow = Color(zoHex: 0x020202, alpha: 0.28)
        }
    }
}

private struct ProfileSettingsYouCardMaterial: View, Animatable {
    let edition: ProfileSettingsYouEdition
    var sheen: Double
    var isTrial = false
    var animatableData: Double {
        get { sheen }
        set { sheen = newValue }
    }
    var body: some View {
        GeometryReader { proxy in
            let material = ProfileSettingsYouMaterial(edition: edition)
            let base = endpoints(angle: 155, size: proxy.size)
            let light = endpoints(angle: 104, size: proxy.size)
            ZStack(alignment: .bottom) {
                LinearGradient(stops: zip(material.stops, [0.0, 0.42, 0.72, 1.0]).map {
                    Gradient.Stop(color: Color(zoHex: $0.0), location: $0.1)
                }, startPoint: base.0, endPoint: base.1)
                editionDetail(proxy.size)
                Canvas { context, size in
                    // CSS px maps to logical points at the 353-point reference size.
                    let pixel: CGFloat = 1
                    for x in stride(from: CGFloat.zero, through: size.width, by: pixel * 3) {
                        context.fill(Path(CGRect(x: x, y: 0, width: pixel, height: size.height)), with: .color(.white.opacity(0.014)))
                    }
                }
                LinearGradient(stops: sheenStops(shine: material.shine), startPoint: light.0, endPoint: light.1)
                if !isTrial {
                    if edition == .neon {
                    LinearGradient(colors: [0xC04DFF, 0xFF4D6D, 0xFF8A3D, 0xFFE9A8].map { Color(zoHex: UInt32($0)) }, startPoint: .leading, endPoint: .trailing)
                        .frame(height: 4)
                    } else { (edition == .onyx ? material.mark : material.ink).frame(height: 4) }
                }
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }

    /// CSS angles are clockwise from up; gradient length includes rectangular "magic corners".
    private func endpoints(angle: Double, size: CGSize) -> (UnitPoint, UnitPoint) {
        let radians = angle * .pi / 180
        let dx = sin(radians), dy = -cos(radians)
        let width = max(1, size.width), height = max(1, size.height)
        let length = abs(width * dx) + abs(height * dy)
        return (.init(x: 0.5 - dx * length / (2 * width), y: 0.5 - dy * length / (2 * height)),
                .init(x: 0.5 + dx * length / (2 * width), y: 0.5 + dy * length / (2 * height)))
    }

    /// Crop the moving CSS stops to the visible gradient domain, interpolating boundary alpha.
    private func sheenStops(shine: Double) -> [Gradient.Stop] {
        let points: [(Double, Double)] = [(sheen - 0.38, 0), (sheen - 0.18, shine * 0.25),
            (sheen, shine), (sheen + 0.18, shine * 0.25), (sheen + 0.38, 0)]
        func alpha(at t: Double) -> Double {
            for index in 0..<4 {
                let a = points[index], b = points[index + 1]
                if t >= a.0 && t <= b.0 { return a.1 + (b.1 - a.1) * (t - a.0) / (b.0 - a.0) }
            }
            return 0
        }
        let clipped = [(0.0, alpha(at: 0))] + points.filter { $0.0 > 0 && $0.0 < 1 } + [(1.0, alpha(at: 1))]
        return clipped.map { .init(color: .white.opacity($0.1), location: $0.0) }
    }

    @ViewBuilder private func editionDetail(_ size: CGSize) -> some View {
        switch edition {
        case .onyx: EmptyView()
        case .pink:
            Canvas { context, canvas in
                // Exact percentage ellipses/stops from components.css:586.
                func drift(center: CGPoint, radius: CGSize, color: Color, end: CGFloat) {
                    var layer = context
                    layer.translateBy(x: center.x, y: center.y)
                    layer.scaleBy(x: radius.width, y: radius.height)
                    layer.fill(Path(CGRect(x: -1, y: -1, width: 2, height: 2)), with: .radialGradient(
                        Gradient(stops: [.init(color: color, location: 0), .init(color: .clear, location: end)]),
                        center: .zero, startRadius: 0, endRadius: 1))
                }
                drift(center: .init(x: canvas.width * 0.1, y: canvas.height),
                    radius: .init(width: canvas.width * 0.6, height: canvas.height * 0.8), color: Color(zoHex: 0xE3C9F5, alpha: 0.70), end: 0.7)
                drift(center: .init(x: canvas.width * 0.85, y: canvas.height * 0.1),
                    radius: .init(width: canvas.width * 0.7, height: canvas.height * 0.9), color: .white.opacity(0.35), end: 0.6)
            }
        case .chrome:
            ProfileSettingsYouSigil().fill(.white.opacity(0.09))
                .frame(width: size.width * 0.72, height: size.height * 0.26)
                .position(x: size.width * 0.70, y: size.height * 0.43)
        case .neon:
            let diameter = size.width * 0.38
            LinearGradient(stops: [
                .init(color: Color(zoHex: 0xFFE9A8), location: 0),
                .init(color: Color(zoHex: 0xFFC94A), location: 0.3),
                .init(color: Color(zoHex: 0xFF8A3D), location: 0.5),
                .init(color: Color(zoHex: 0xFF4D6D), location: 0.7),
                .init(color: Color(zoHex: 0xC04DFF), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .frame(width: diameter, height: diameter).clipShape(Circle())
            .mask {
                Canvas { context, canvas in
                    for y in stride(from: CGFloat.zero, through: canvas.height, by: canvas.height * 0.12) {
                        context.fill(Path(CGRect(x: 0, y: y, width: canvas.width, height: canvas.height * 0.09)), with: .color(.black))
                    }
                }
            }
            .opacity(0.9)
            .position(x: size.width * 0.89, y: size.height * 1.26 - diameter / 2)
        }
    }
}

/// Exact SVG paths from components.css:613, translated into a native shape.
private struct ProfileSettingsYouSigil: Shape {
    func path(in rect: CGRect) -> Path {
        var half = Path()
        half.move(to: .init(x: 144, y: 30)); half.addCurve(to: .init(x: 18, y: 28), control1: .init(x: 118, y: 22), control2: .init(x: 78, y: 12)); half.addCurve(to: .init(x: 144, y: 35), control1: .init(x: 70, y: 20), control2: .init(x: 116, y: 28)); half.closeSubpath()
        half.move(to: .init(x: 122, y: 23)); half.addCurve(to: .init(x: 86, y: 1), control1: .init(x: 113, y: 12), control2: .init(x: 102, y: 5)); half.addCurve(to: .init(x: 116, y: 25), control1: .init(x: 99, y: 9), control2: .init(x: 107, y: 15)); half.closeSubpath()
        half.move(to: .init(x: 110, y: 31)); half.addCurve(to: .init(x: 71, y: 58), control1: .init(x: 101, y: 43), control2: .init(x: 89, y: 51)); half.addCurve(to: .init(x: 104, y: 30), control1: .init(x: 86, y: 48), control2: .init(x: 96, y: 40)); half.closeSubpath()
        half.move(to: .init(x: 66, y: 20)); half.addCurve(to: .init(x: 42, y: 7), control1: .init(x: 59, y: 13), control2: .init(x: 52, y: 9)); half.addCurve(to: .init(x: 61, y: 22), control1: .init(x: 51, y: 12), control2: .init(x: 56, y: 16)); half.closeSubpath()
        half.move(to: .init(x: 40, y: 25)); half.addCurve(to: .init(x: 3, y: 34), control1: .init(x: 30, y: 31), control2: .init(x: 19, y: 34)); half.addCurve(to: .init(x: 36, y: 23), control1: .init(x: 17, y: 30), control2: .init(x: 27, y: 27)); half.closeSubpath()
        half.move(to: .init(x: 86, y: 28)); half.addCurve(to: .init(x: 64, y: 38), control1: .init(x: 80, y: 34), control2: .init(x: 74, y: 37)); half.addCurve(to: .init(x: 82, y: 27), control1: .init(x: 72, y: 35), control2: .init(x: 78, y: 31)); half.closeSubpath()
        var path = half
        path.addPath(half, transform: .init(a: -1, b: 0, c: 0, d: 1, tx: 300, ty: 0))
        path.move(to: .init(x: 150, y: 2)); path.addLines([.init(x: 157, y: 30), .init(x: 150, y: 58), .init(x: 143, y: 30)]); path.closeSubpath()
        let scale = min(rect.width / 300, rect.height / 60)
        return path.applying(.init(a: scale, b: 0, c: 0, d: scale, tx: rect.midX - 150 * scale, ty: rect.midY - 30 * scale))
    }
}

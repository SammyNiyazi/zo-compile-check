import Foundation
import SwiftUI

/// Isolated public-API experiment, never production fidelity approval.
/// Native intrinsic bar geometry, track cancellation, mask scheduling and AOD
/// contours must be measured on the actual host. No fraction is sampled here.
struct WorkoutNativeRestLineExperiment: View {
    let interval: ClosedRange<Date>?
    let accent: Color
    let track: Color
    /// Caller supplies the actual normal-mode token, or nil for no edge.
    /// The extension has no assumed accentEdge property.
    let normalInsetEdge: Color?
    let dimmed: Bool

    @ViewBuilder var body: some View {
        if let interval = WorkoutNativeRestMaskCoordinates.valid(interval) {
            GeometryReader { geometry in
                let width = geometry.size.width
                if width.isFinite, width > 0 {
                    if dimmed {
                        if let inner = WorkoutNativeRestMaskCoordinates.inner(
                            interval: interval, width: width, inset: 1.5) {
                            line(interval: interval, width: width, inner: inner)
                        }
                        // Invalid auxiliary dates/dimensions draw nothing.
                        // A solid fill is not a substitute for an unprovable outline.
                    } else if let edge = normalInsetEdge {
                        if let inner = WorkoutNativeRestMaskCoordinates.inner(
                            interval: interval, width: width, inset: 1) {
                            normalFill(interval: interval, width: width)
                                .overlay {
                                    edge.mask {
                                        WorkoutNativeRestMaskBand(
                                            interval: interval, width: width, inner: inner)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .circular))
                        }
                    } else {
                        normalFill(interval: interval, width: width)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .circular))
                    }
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        // Unknown input is genuinely absent, with no replacement clock or spacer.
    }

    private func normalFill(interval: ClosedRange<Date>, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            track
            accent.mask {
                WorkoutNativeRestFillMask(interval: interval, width: width, height: 6)
            }
        }
    }

    private func line(
        interval: ClosedRange<Date>, width: CGFloat,
        inner: WorkoutNativeRestMaskCoordinates.Inner
    ) -> some View {
        ZStack(alignment: .topLeading) {
            // Track is outside difference and destinationOut isolation.
            track
            accent.mask {
                WorkoutNativeRestMaskBand(interval: interval, width: width, inner: inner)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .circular))
        // Existing card brightness(.72) belongs to the actual caller, once only.
    }
}

/// Drawing coordinates only: never a workout deadline, notification or payload.
/// The earlier inner end compensates for the narrower host; same-range padding
/// has a time-dependent right inset. This does not prove native cap geometry.
enum WorkoutNativeRestMaskCoordinates {
    struct Inner {
        let interval: ClosedRange<Date>
        let width: CGFloat
        let height: CGFloat
        let inset: CGFloat
    }

    static func valid(_ interval: ClosedRange<Date>?) -> ClosedRange<Date>? {
        guard let interval,
              interval.lowerBound.timeIntervalSinceReferenceDate.isFinite,
              interval.upperBound.timeIntervalSinceReferenceDate.isFinite,
              interval.lowerBound < interval.upperBound else { return nil }
        let duration = interval.upperBound.timeIntervalSince(interval.lowerBound)
        guard duration.isFinite, duration > 0 else { return nil }
        return interval
    }

    static func inner(
        interval: ClosedRange<Date>, width: CGFloat, inset: CGFloat
    ) -> Inner? {
        guard let original = valid(interval),
              width.isFinite, inset.isFinite, inset > 0,
              width > 2 * inset, 6 > 2 * inset else { return nil }
        let duration = original.upperBound.timeIntervalSince(original.lowerBound)
        let correction = duration * (Double(2 * inset) / Double(width))
        guard correction.isFinite, correction > 0 else { return nil }
        let end = original.upperBound.addingTimeInterval(-correction)
        guard end.timeIntervalSinceReferenceDate.isFinite,
              original.lowerBound < end, end < original.upperBound else { return nil }
        return Inner(interval: original.lowerBound ... end,
                     width: width - 2 * inset, height: 6 - 2 * inset, inset: inset)
    }
}

/// Two real native timer passes. Black backing and each pass's isolated group
/// prevent unrelated track/background pixels from becoming the difference input.
/// Public built-in linear presentation is tried; no custom ProgressViewStyle.
/// Frame and clipping constrain hosts, not the native moving-end radius.
struct WorkoutNativeRestFillMask: View {
    let interval: ClosedRange<Date>
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            nativePass(tint: .black)
            nativePass(tint: .white)
                .blendMode(.difference)
        }
        .compositingGroup()
        .luminanceToAlpha()
        .frame(width: width, height: height)
        .clipped()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func nativePass(tint: Color) -> some View {
        ZStack {
            Color.black
            ProgressView(timerInterval: interval, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(tint)
            .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .clipped()
        .compositingGroup()
    }
}

/// Alpha subtraction is confined to a transparent group before the real track.
/// Painting a background-colored interior would hide the track and is forbidden.
struct WorkoutNativeRestMaskBand: View {
    let interval: ClosedRange<Date>
    let width: CGFloat
    let inner: WorkoutNativeRestMaskCoordinates.Inner

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.mask {
                WorkoutNativeRestFillMask(interval: interval, width: width, height: 6)
            }
            Color.white
                .frame(width: inner.width, height: inner.height)
                .mask {
                    WorkoutNativeRestFillMask(
                        interval: inner.interval, width: inner.width, height: inner.height)
                }
                .offset(x: inner.inset, y: inner.inset)
                .blendMode(.destinationOut)
        }
        .frame(width: width, height: 6, alignment: .topLeading)
        .compositingGroup()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

import SwiftUI

struct ExerciseGuidanceMotionConfiguration: Equatable, Sendable {
    let exerciseID: ExerciseID
    let start: UnitPoint
    let control: UnitPoint
    let end: UnitPoint
    let duration: TimeInterval

    func point(at progress: CGFloat) -> UnitPoint {
        let clamped = min(max(progress, 0), 1)
        let inverse = 1 - clamped
        return UnitPoint(
            x: inverse * inverse * start.x
                + 2 * inverse * clamped * control.x
                + clamped * clamped * end.x,
            y: inverse * inverse * start.y
                + 2 * inverse * clamped * control.y
                + clamped * clamped * end.y
        )
    }
}

enum ExerciseGuidanceMotionCatalog {
    static let supportedExerciseIDs: Set<ExerciseID> = [
        ExerciseIDs.dumbbellBenchPress,
        ExerciseIDs.lyingLegCurl,
        ExerciseIDs.seatedCableRow,
        ExerciseIDs.romanianDeadlift,
        ExerciseIDs.legPress,
        ExerciseIDs.latPulldown
    ]

    static func configuration(for exerciseID: ExerciseID) -> ExerciseGuidanceMotionConfiguration? {
        switch exerciseID {
        case ExerciseIDs.dumbbellBenchPress:
            return configuration(exerciseID, start: .init(x: 0.48, y: 0.58), end: .init(x: 0.48, y: 0.20))
        case ExerciseIDs.lyingLegCurl:
            return configuration(
                exerciseID,
                start: .init(x: 0.72, y: 0.69),
                control: .init(x: 0.79, y: 0.57),
                end: .init(x: 0.78, y: 0.43)
            )
        case ExerciseIDs.seatedCableRow:
            return configuration(exerciseID, start: .init(x: 0.75, y: 0.43), end: .init(x: 0.43, y: 0.39))
        case ExerciseIDs.romanianDeadlift:
            return configuration(
                exerciseID,
                start: .init(x: 0.50, y: 0.36),
                control: .init(x: 0.40, y: 0.34),
                end: .init(x: 0.34, y: 0.46)
            )
        case ExerciseIDs.legPress:
            return configuration(exerciseID, start: .init(x: 0.51, y: 0.62), end: .init(x: 0.68, y: 0.38))
        case ExerciseIDs.latPulldown:
            return configuration(exerciseID, start: .init(x: 0.58, y: 0.19), end: .init(x: 0.58, y: 0.39))
        default:
            return nil
        }
    }

    private static func configuration(
        _ exerciseID: ExerciseID,
        start: UnitPoint,
        control: UnitPoint? = nil,
        end: UnitPoint
    ) -> ExerciseGuidanceMotionConfiguration {
        ExerciseGuidanceMotionConfiguration(
            exerciseID: exerciseID,
            start: start,
            control: control ?? UnitPoint(
                x: (start.x + end.x) / 2,
                y: (start.y + end.y) / 2
            ),
            end: end,
            duration: 0.62
        )
    }
}

struct ExerciseGuidanceMotionState: Equatable, Sendable {
    let progress: CGFloat
    let cueOpacity: Double

    static let initial = ExerciseGuidanceMotionState(progress: 0, cueOpacity: 1)
    static let settled = ExerciseGuidanceMotionState(progress: 1, cueOpacity: 0)

    static func entryState(reduceMotion: Bool) -> ExerciseGuidanceMotionState {
        reduceMotion ? .settled : .initial
    }
}

struct ExerciseGuidanceMotionView: View {
    @Environment(\.zeroOneTheme) private var theme
    let artwork: ExerciseArtwork

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motionState = ExerciseGuidanceMotionState.initial

    var body: some View {
        ZStack {
            ZeroOneExerciseArtwork(artwork: artwork, contentMode: .fit)

            if let configuration = ExerciseGuidanceMotionCatalog.configuration(for: artwork.exerciseID),
               motionState.cueOpacity > 0 {
                GeometryReader { proxy in
                    let point = configuration.point(at: motionState.progress)

                    Circle()
                        .stroke(theme.accentForeground.opacity(0.72), lineWidth: 1.5)
                        .background(Circle().fill(theme.accentFill))
                        .frame(width: 8, height: 8)
                        .position(x: point.x * proxy.size.width, y: point.y * proxy.size.height)
                        .opacity(motionState.cueOpacity)
                        .accessibilityHidden(true)
                }
            }
        }
        .onAppear(perform: beginEntryCue)
        .onChange(of: artwork.exerciseID) { _, _ in
            beginEntryCue()
        }
    }

    private func beginEntryCue() {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_MOTION_STATE"]?.lowercased() {
        case "initial":
            motionState = .initial
            return
        case "settled":
            motionState = .settled
            return
        default:
            break
        }
        #endif

        motionState = .entryState(reduceMotion: reduceMotion)
        guard !reduceMotion,
              let configuration = ExerciseGuidanceMotionCatalog.configuration(for: artwork.exerciseID) else {
            return
        }

        withAnimation(.easeInOut(duration: configuration.duration)) {
            motionState = ExerciseGuidanceMotionState(progress: 1, cueOpacity: 1)
        }
        withAnimation(.easeOut(duration: 0.22).delay(configuration.duration * 0.72)) {
            motionState = .settled
        }
    }
}

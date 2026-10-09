import Foundation
import SwiftUI

struct AssistantPushToTalkSection: View {
    let coordinator: VoiceAssistantCoordinator
    let onConfirm: (String) -> Void
    var onRequestAccess: (() -> Void)? = nil

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOverCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack {
                Text("Speak a request")
                    .zoText(.caption)

                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }

            content
        }
        .padding(ZOSpace.l)
        .background(theme.surfacePrimary)
        .overlay {
            RoundedRectangle(cornerRadius: ZORadius.card, style: .continuous)
                .stroke(theme.strokeSubtle, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: ZORadius.card, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .needsConsent:
            consentContent
        case .requestingAccess:
            statusContent(
                title: "Opening system permissions",
                message: localization.string("Choose microphone and speech access only if push-to-talk is useful."),
                symbol: "ellipsis"
            )
        case .ready, .preparing, .listening, .finalizing:
            // One subtree keeps the hold alive through ready -> preparing -> listening.
            listeningContent
        case .transcriptConfirmation:
            transcriptConfirmation
        case let .feedback(confirmation):
            feedbackContent(confirmation)
        case .denied:
            accessIssue(
                title: "Voice access is off",
                message: localization.string("Push-to-talk stays unavailable. Touch actions still work normally."),
                symbol: "mic.slash"
            )
        case .unavailable:
            accessIssue(
                title: "On-device speech is unavailable",
                message: localization.string("01 will not send audio away for transcription. Touch actions remain available."),
                symbol: "mic.slash"
            )
        case .cancelled:
            VStack(alignment: .leading, spacing: ZOSpace.m) {
                statusContent(
                    title: "Voice setup cancelled",
                    message: localization.string("Nothing was recorded. Try again only when you choose."),
                    symbol: "xmark"
                )
                Button("Try voice setup again") {
                    coordinator.tryAgain()
                }
                .buttonStyle(ZOButtonStyle(.secondary))
            }
        }
    }

    private var consentContent: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("Hold to speak, then review what 01 heard before choosing an action.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Speech stays on this iPhone. Microphone and speech access are optional; 01 listens only while you hold the control.")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Enable push-to-talk") {
                if let onRequestAccess { onRequestAccess() }
                else { Task { await coordinator.requestAccess() } }
            }
            .buttonStyle(ZOButtonStyle(.primary))
            .accessibilityHint("Requests microphone and speech recognition access from iOS.")
        }
    }

    private var listeningContent: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isOverCancel {
                        Image(systemName: "xmark")
                            .zoIcon(ZOIcon.inline)
                            .accessibilityHidden(true)
                    } else {
                        VoiceMark(size: 14, isListening: coordinator.phase == .listening)
                    }
                    Text(verbatim: isOverCancel ? VoiceMotionCopy.releaseToCancel(localization) : listeningTitle)
                        .zoProofText(.caption, size: 13, lineHeight: 18, weight: 500)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.textSecondary)

                // The service supplies one whole transcript, without word confidence.
                Text(verbatim: listeningMessage)
                    .zoProofText(.section, size: 22, lineHeight: 28, weight: 600, tracking: -0.2)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : ZOMotion.land(ZOMotion.label),
                               value: coordinator.transcript)
                    .transaction { if reduceMotion { $0.disablesAnimations = true } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.horizontal, ZOSpace.l)
            .background(theme.colorScheme == .dark ? theme.surfaceSecondary : theme.surfacePrimary,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(theme.strokeSubtle, lineWidth: ZOStroke.hairline)
            }
            .opacity(isOverCancel ? 0.55 : 1)

            VoiceAssistantControl(coordinator: coordinator, isOverCancel: $isOverCancel)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityElement(children: .contain)
    }

    private var transcriptConfirmation: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("What 01 heard")
                .zoText(.caption)

                .foregroundStyle(theme.textSecondary)

            Text(verbatim: "“" + coordinator.transcript + "”")
                .zoText(.title)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(localization.format("Recognized transcript. %1$@", .text(coordinator.transcript)))

            Text("No action has happened yet.")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: ZOSpace.s) { transcriptActions }
                VStack(alignment: .leading, spacing: ZOSpace.s) { transcriptActions }
            }
        }
    }

    @ViewBuilder
    private var transcriptActions: some View {
        Button("Cancel request") { coordinator.cancelTranscript() }
            .buttonStyle(ZOButtonStyle(.secondary))
        Button("Try again") { coordinator.tryAgain() }
            .buttonStyle(ZOButtonStyle(.secondary))
        Button("Confirm") {
            if let transcript = coordinator.confirmTranscript() { onConfirm(transcript) }
        }
        .buttonStyle(ZOButtonStyle(.primary))
    }

    private func feedbackContent(_ confirmation: AssistantConfirmation) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            statusContent(
                title: confirmation.kind == .error ? "No action taken" : "Confirmed",
                message: VoiceFeedbackCopy.message(confirmation.message, localization: localization),
                symbol: confirmation.kind == .error ? "exclamationmark" : "checkmark"
            )
            if confirmation.kind != .success {
                Button("Try again") {
                    coordinator.tryAgain()
                }
                .buttonStyle(ZOButtonStyle(.secondary))
            }
        }
    }

    private func accessIssue(title: String, message: String, symbol: String) -> some View {
        statusContent(title: title, message: message, symbol: symbol)
    }

    private func statusContent(title: String, message: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: ZOSpace.m) {
            Image(systemName: symbol)
                .zoIcon(ZOIcon.row)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: localization.string(title))
                    .zoText(.section)
                    .foregroundStyle(theme.textPrimary)
                Text(verbatim: message)
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var listeningTitle: String {
        switch coordinator.phase {
        case .ready: localization.string("Hold while speaking")
        case .preparing: localization.string("Starting on-device speech")
        case .listening: localization.string("Listening while held")
        case .finalizing: localization.string("Finishing transcript")
        default: localization.string("Push to talk")
        }
    }

    private var listeningMessage: String {
        switch coordinator.phase {
        case .ready:
            localization.string("Release to review. Slide onto the cancel button to discard.")
        case .preparing:
            coordinator.transcript.isEmpty ? localization.string("Recording begins only after access is ready.") : coordinator.transcript
        case .listening:
            coordinator.transcript.isEmpty ? localization.string("Speak now. Release to stop.") : coordinator.transcript
        case .finalizing:
            coordinator.transcript.isEmpty
                ? localization.string("Recording stopped. Preparing the text for your review.")
                : coordinator.transcript
        default:
            localization.string("Recording begins only after access is ready.")
        }
    }

}

struct RootVoiceMark: View {
    let size: CGFloat
    let isListening: Bool
    var body: some View { VoiceMark(size: size, isListening: isListening) }
}

struct VoiceAssistantControl: View {
    let coordinator: VoiceAssistantCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var isPressing = false
    @Binding var isOverCancel: Bool
    @State private var holdGeneration: UInt = 0
    @GestureState private var gestureIsActive = false

    private var hasActiveHold: Bool {
        coordinator.phase == .preparing || coordinator.phase == .listening
    }

    private let geometry = VoiceHoldPresentation.Geometry.proof

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: geometry.gap) {
                Text(verbatim: VoiceMotionCopy.dragToCancel(localization))
                    .zoProofText(.caption, size: 12, lineHeight: 16, weight: 500)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: geometry.cancelSize + geometry.gap)
                    .frame(width: geometry.cancelSize)
                    .opacity(hasActiveHold && !isOverCancel ? 1 : 0)
                Color.clear.frame(width: geometry.controlSize, height: 0)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            HStack(spacing: geometry.gap) {
                Button {
                    cancelHold()
                } label: {
                    ZStack {
                        Circle()
                            .fill(isOverCancel ? theme.destructivePrimary : theme.surfaceSecondary)
                            .overlay {
                                Circle().stroke(isOverCancel ? .clear : theme.separatorStrong, lineWidth: ZOStroke.control)
                            }
                        Image(systemName: "xmark")
                            .zoIcon(ZOIcon.row)
                            .foregroundStyle(isOverCancel ? theme.backgroundPrimary : theme.textSecondary)
                    }
                    // Only decoration scales. The Button's fixed 44 pt rectangle is the hit target.
                    .scaleEffect(VoiceMotionPresentation.cancelScale(isHot: isOverCancel, reduceMotion: reduceMotion))
                    .animation(ZOMotion.land(ZOMotion.quick), value: isOverCancel)
                    .allowsHitTesting(false)
                    .frame(width: geometry.cancelSize, height: geometry.cancelSize)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: geometry.cancelSize, height: geometry.cancelSize)
                .contentShape(Rectangle())
                .opacity(hasActiveHold ? 1 : 0)
                .disabled(!hasActiveHold)
                .accessibilityHidden(!hasActiveHold)
                .accessibilityLabel("Cancel voice request")
                .accessibilityHint("Discards the recording without choosing an action.")

                Button {
                    coordinator.toggleForAccessibility()
                } label: {
                    VoiceMark(size: 26, isListening: false)
                        .foregroundStyle(theme.backgroundPrimary)
                        .frame(width: geometry.controlSize, height: geometry.controlSize)
                        .background(theme.textPrimary, in: Circle())
                        .background {
                            Circle().fill(theme.textPrimary.opacity(0.10))
                                .padding(-6)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        .opacity(isOverCancel ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(coordinator.phase == .finalizing)
                .highPriorityGesture(holdGesture)
                .accessibilityLabel("Push to talk")
                .accessibilityValue(accessibilityValue)
                .accessibilityHint("Double tap to begin, then double tap again to stop and review. Use Cancel voice request to discard.")
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: coordinator.phase == .preparing) { _, new in new }
        .sensoryFeedback(.impact(weight: .light), trigger: isOverCancel) { _, new in new }
        .onChange(of: gestureIsActive) { _, active in
            // GestureState can reset in the release transaction. Let onEnded
            // clear isPressing before treating a missing end callback as cancellation.
            if !active, isPressing {
                let generation = holdGeneration
                Task { @MainActor in
                    await Task.yield()
                    if generation == holdGeneration, !gestureIsActive, isPressing { cancelHold() }
                }
            }
        }
        .onChange(of: coordinator.phase) { _, phase in
            if phase != .preparing && phase != .listening {
                holdGeneration &+= 1
                isPressing = false
                isOverCancel = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelHold() }
        }
        .onDisappear { cancelHold() }
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($gestureIsActive) { _, active, _ in active = true }
            .onChanged { value in
                if !isPressing {
                    guard coordinator.phase == .ready else { return }
                    holdGeneration &+= 1
                    isPressing = true
                    coordinator.pressBegan()
                }
                guard hasActiveHold else { return }
                isOverCancel = VoiceHoldPresentation.isOnCancel(value.location, geometry: geometry, isRightToLeft: layoutDirection == .rightToLeft)
            }
            .onEnded { value in
                guard isPressing else { return }
                let cancelled = VoiceHoldPresentation.isOnCancel(value.location, geometry: geometry, isRightToLeft: layoutDirection == .rightToLeft)
                holdGeneration &+= 1
                isPressing = false
                isOverCancel = false
                if cancelled { coordinator.cancelTranscript() }
                else { coordinator.pressEnded() }
            }
    }

    private func cancelHold() {
        holdGeneration &+= 1
        // Includes finalizing: backgrounding must not leave a pending transcript operation.
        if hasActiveHold || coordinator.phase == .finalizing {
            coordinator.cancelTranscript()
        }
        isPressing = false
        isOverCancel = false
    }

    private var accessibilityValue: String {
        if isOverCancel { return localization.string("Release to cancel") }
        switch coordinator.phase {
        case .ready: return localization.string("Ready")
        case .preparing: return localization.string("Preparing")
        case .listening: return coordinator.transcript.isEmpty ? localization.string("Listening") : coordinator.transcript
        case .finalizing: return localization.string("Finishing transcript")
        default: return localization.string("Unavailable")
        }
    }
}

/// Exact icons.js MARK geometry in a 400 x 400 viewBox. Only the interior rect can breathe.
private struct VoiceMark: View {
    let size: CGFloat
    let isListening: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            VoiceMarkOutline().fill(style: FillStyle(eoFill: true))
            if isListening && !reduceMotion {
                VoiceBreathingBar(size: size)
            } else {
                VoiceMarkBar(size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct VoiceMarkBar: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size / 400, style: .circular)
            .frame(width: size * 50 / 400, height: size * 34 / 400)
            .position(x: size * 124 / 400, y: size * 209 / 400)
    }
}

private struct VoiceBreathingBar: View {
    let size: CGFloat
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            VoiceMarkBar(size: size)
                .opacity(VoiceMotionPresentation.barOpacity(elapsed: timeline.date.timeIntervalSince(startedAt)))
        }
    }
}

private struct VoiceMarkOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 84, y: 25))
        path.addLine(to: CGPoint(x: 164, y: 25))
        path.addCurve(to: CGPoint(x: 214, y: 79), control1: CGPoint(x: 192, y: 25), control2: CGPoint(x: 214, y: 49))
        path.addLine(to: CGPoint(x: 214, y: 320))
        path.addCurve(to: CGPoint(x: 164, y: 376), control1: CGPoint(x: 214, y: 351), control2: CGPoint(x: 192, y: 376))
        path.addLine(to: CGPoint(x: 84, y: 376))
        path.addCurve(to: CGPoint(x: 36, y: 320), control1: CGPoint(x: 57, y: 376), control2: CGPoint(x: 36, y: 351))
        path.addLine(to: CGPoint(x: 36, y: 80))
        path.addCurve(to: CGPoint(x: 84, y: 25), control1: CGPoint(x: 36, y: 49), control2: CGPoint(x: 57, y: 25))
        path.closeSubpath()
        path.move(to: CGPoint(x: 100, y: 85))
        path.addLine(to: CGPoint(x: 149, y: 85))
        path.addCurve(to: CGPoint(x: 162, y: 99), control1: CGPoint(x: 157, y: 85), control2: CGPoint(x: 162, y: 91))
        path.addLine(to: CGPoint(x: 162, y: 310))
        path.addCurve(to: CGPoint(x: 149, y: 324), control1: CGPoint(x: 162, y: 318), control2: CGPoint(x: 157, y: 324))
        path.addLine(to: CGPoint(x: 100, y: 324))
        path.addCurve(to: CGPoint(x: 88, y: 310), control1: CGPoint(x: 92, y: 324), control2: CGPoint(x: 88, y: 318))
        path.addLine(to: CGPoint(x: 88, y: 99))
        path.addCurve(to: CGPoint(x: 100, y: 85), control1: CGPoint(x: 88, y: 91), control2: CGPoint(x: 92, y: 85))
        path.closeSubpath()
        path.move(to: CGPoint(x: 291, y: 25))
        for point in [CGPoint(x: 342, y: 25), CGPoint(x: 342, y: 342), CGPoint(x: 369, y: 342),
                      CGPoint(x: 369, y: 376), CGPoint(x: 247, y: 376), CGPoint(x: 247, y: 342),
                      CGPoint(x: 274, y: 342), CGPoint(x: 274, y: 85), CGPoint(x: 237, y: 85), CGPoint(x: 237, y: 65)] {
            path.addLine(to: point)
        }
        path.addCurve(to: CGPoint(x: 291, y: 25), control1: CGPoint(x: 258, y: 59), control2: CGPoint(x: 278, y: 44))
        path.closeSubpath()
        return path.applying(CGAffineTransform(a: rect.width / 400, b: 0, c: 0, d: rect.height / 400,
                                              tx: rect.minX, ty: rect.minY))
    }
}

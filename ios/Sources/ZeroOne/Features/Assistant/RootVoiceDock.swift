import SwiftUI

/// Presentation only. The root owns the coordinator, consent task, sheet seed and actions.
/// The original MainActionControl owns the continuous touch; this view never adds a gesture host.
struct RootVoiceDock: View {
    let coordinator: VoiceAssistantCoordinator
    let isAccessRequestPending: Bool
    let isOverCancel: Bool
    let onCancel: () -> Void
    let onRequestAccess: () -> Void
    let onConfirm: (String) -> Void
    let onOpenActions: () -> Void
    let onClose: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                switch coordinator.phase {
                case .ready, .preparing, .listening, .finalizing:
                    // One structural branch preserves the real hold's local gesture state.
                    captureContent(availableHeight: geometry.size.height)
                default:
                    ViewThatFits(in: .vertical) {
                        reviewAndAccessContent
                        ScrollView { reviewAndAccessContent }
                    }
                    .frame(maxHeight: max(0, geometry.size.height - 138), alignment: .bottom)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 122)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { onClose() }
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
    }

    private func captureContent(availableHeight: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            ViewThatFits(in: .vertical) {
                listeningPanel
                ScrollView { listeningPanel }
            }
                .frame(maxHeight: max(0, availableHeight - 138), alignment: .bottom)
                .padding(.horizontal, 16)
                .padding(.bottom, 122)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .zoIcon(ZOIcon.row)
                    .foregroundStyle(isOverCancel ? theme.backgroundPrimary : theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(isOverCancel ? theme.destructivePrimary : theme.surfaceSecondary, in: Circle())
                    .overlay { Circle().stroke(isOverCancel ? .clear : theme.separatorStrong, lineWidth: ZOStroke.control) }
                    .scaleEffect(VoiceMotionPresentation.cancelScale(isHot: isOverCancel, reduceMotion: reduceMotion))
                    .animation(reduceMotion ? nil : ZOMotion.land(ZOMotion.quick), value: isOverCancel)
                    .allowsHitTesting(false)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                Text(verbatim: VoiceMotionCopy.dragToCancel(localization))
                    .zoProofText(.caption, size: 12, lineHeight: 16, weight: 500)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: true, vertical: true)
                    .offset(y: -26)
                    .opacity(isOverCancel ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Cancel voice request")
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(x: -106)
            .padding(.bottom, 30)
            .opacity(coordinator.phase == .preparing || coordinator.phase == .listening ? 1 : 0)
            .disabled(coordinator.phase != .preparing && coordinator.phase != .listening)
            .accessibilityHidden(coordinator.phase != .preparing && coordinator.phase != .listening)
        }
    }

    private var listeningPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if isOverCancel {
                    Image(systemName: "xmark")
                        .zoIcon(ZOIcon.inline)
                        .accessibilityHidden(true)
                } else {
                    RootVoiceMark(size: 14, isListening: coordinator.phase == .listening)
                }
                Text(verbatim: isOverCancel ? VoiceMotionCopy.releaseToCancel(localization) : listeningTitle)
                    .zoProofText(.caption, size: 13, lineHeight: 18, weight: 500)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if coordinator.phase == .ready {
                    closeButton
                }
            }
            .foregroundStyle(theme.textSecondary)

            // Real service text is whole-transcript only; no word confidence is invented.
            Text(verbatim: listeningMessage)
                .zoProofText(.section, size: 22, lineHeight: 28, weight: 600, tracking: -0.2)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : ZOMotion.land(ZOMotion.label), value: coordinator.transcript)

            if coordinator.phase == .ready {
                openActionsButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(theme.colorScheme == .dark ? theme.surfaceSecondary : theme.surfacePrimary)
                .shadow(color: listeningFloatColor, radius: 24, x: 0, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.strokeSubtle, lineWidth: ZOStroke.hairline)
        }
        .opacity(isOverCancel ? 0.55 : 1)
    }

    private var reviewAndAccessContent: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            HStack {
                Text("Assistant").zoText(.section)
                Spacer()
                closeButton
            }
            // Existing consent, confirmation, denial, unavailable and feedback callbacks.
            AssistantPushToTalkSection(
                coordinator: coordinator,
                onConfirm: onConfirm,
                onRequestAccess: onRequestAccess
            )
            .disabled(isAccessRequestPending)
            openActionsButton
        }
        .padding(16)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.strokeSubtle, lineWidth: ZOStroke.hairline)
        }
    }

    private var closeButton: some View {
        Button("Close", action: onClose)
            .zoText(.caption)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Close voice request")
    }

    private var openActionsButton: some View {
        Button("Type a request or choose an action", action: onOpenActions)
            .zoText(.caption)
            .frame(minHeight: 44)
            .disabled(isAccessRequestPending)
            .accessibilityHint("Opens the Assistant's existing request and action controls.")
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
            coordinator.transcript.isEmpty ? localization.string("Recording stopped. Preparing the text for your review.") : coordinator.transcript
        default:
            localization.string("Recording begins only after access is ready.")
        }
    }

    // Inherited --zo-float contract from the sealed voice theme-surface prerequisite.
    // Native blur calibration remains UNRUN; the CSS literal is 0 8px 24px at .12.
    private var listeningFloatColor: Color {
        guard theme.colorScheme == .light else { return .clear }
        return switch theme.designTheme {
        case .core: Color(zoHex: 0x020202, alpha: 0.12)
        case .retro: Color(zoHex: 0x2A0E1E, alpha: 0.12)
        case .freak: Color(zoHex: 0x0A0B0D, alpha: 0.12)
        case .princess: Color(zoHex: 0x35122B, alpha: 0.12)
        }
    }
}

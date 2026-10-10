import SwiftUI

/// Proof 42 "Coach settings, with the voice": the "Out loud" part. Off by
/// default; speed and a sample. Your music gets quieter while 01 speaks.
struct WorkoutCoachSettingsView: View {
    @AppStorage(WorkoutSpokenCoach.enabledKey) private var speaks = false
    @AppStorage(WorkoutSpokenCoach.speedKey) private var speedRaw = WorkoutSpokenCoach.Speed.normal.rawValue
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var needsHeadphones = false

    private var spoken: WorkoutSpokenCoach { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                Text("How 01 talks to you during a workout.").zoText(.body).foregroundStyle(theme.textSecondary)
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text("Out loud").zoText(.section)
                    VStack(alignment: .leading, spacing: ZOSpace.xs) {
                        Toggle(isOn: $speaks) {
                            Label("Say it in my AirPods", systemImage: "headphones").zoText(.section)
                        }
                        .accessibilityIdentifier("coach.speaks")
                        Text("Only with headphones connected").zoText(.caption).foregroundStyle(theme.textSecondary)
                    }
                    .padding(ZOSpace.cardPadding)
                    .zoThemeCardSurface()
                    HStack(spacing: ZOSpace.s) {
                        ForEach(WorkoutSpokenCoach.Speed.allCases) { speed in
                            ZOChip(title: localization.string(speed.title), isSelected: speedRaw == speed.rawValue) {
                                speedRaw = speed.rawValue
                            }
                        }
                    }
                    .disabled(!speaks)
                }
                Text("Your music gets quieter while 01 speaks, then comes back. Nothing is recorded.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                Button {
                    if spoken.headphonesConnected {
                        needsHeadphones = false
                        spoken.say(localization.string("Last time 16 kg for 10. Same again, nice and steady."),
                                   language: localization.language, force: true)
                    } else {
                        needsHeadphones = true
                    }
                } label: {
                    Label("Play a sample", systemImage: "play.fill")
                }
                .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                if needsHeadphones {
                    Text("Connect your AirPods or other headphones first.").zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .foregroundStyle(theme.textPrimary)
            .padding(ZOSpace.screenMargin)
        }
        .zoThemeScreenSurface()
        .navigationTitle(localization.string("Coach voice"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: speaks) { _, on in if !on { spoken.stop() } }
    }
}

import SwiftUI

/// Proof 30 "Welcome to the Club": the card arrives with its real number and
/// full confetti, a short note from Sammy, then Apple's own rating prompt
/// (screen 29, the club-welcome peak). Shown once, right after joining.
struct ClubWelcomeView: View {
    let me: ClubSelf
    let onDone: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @State private var askReview = false

    var body: some View {
        ScrollView {
            VStack(spacing: ZOSpace.l) {
                VStack(spacing: ZOSpace.xs) {
                    Text("You are in").zoText(.caption).foregroundStyle(theme.textSecondary)
                    Text("Welcome to the Club").zoThemeText(.display)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.top, ZOSpace.xl)
                if let card = ProfileSettingsYouVerifiedCard(number: me.person.memberNo.map(ClubPerson.memberNumber) ?? "",
                    holderName: me.person.displayName, since: me.person.joinedAt, workouts: me.workoutsCount) {
                    ProfileSettingsYouCardView(snapshot: .init(asOf: .now, displayName: me.person.displayName, card: card))
                        .rotationEffect(.degrees(-3))
                        .padding(.vertical, ZOSpace.m)
                }
                Text("Your card counts every workout you save. Show it, share it, or let a friend scan it at the gym.")
                    .zoText(.body).foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: ZOSpace.m) {
                    // Sammy's portrait: founder notes only, never on a card.
                    Image("SammyFounder")
                        .resizable().scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: ZOSpace.xs) {
                        Text("Thanks for being one of the first. I read every message.").zoText(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        (Text(verbatim: "Sammy").fontWeight(.semibold) + Text(verbatim: " · ") + Text("Founder of 01"))
                            .zoText(.caption).foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, ZOSpace.screenMargin)
        }
        .scrollIndicators(.hidden)
        .zoThemeScreenSurface()
        .overlay(alignment: .top) { WorkoutFinishConfetti() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Show me the Club", action: onDone)
                .buttonStyle(ZOButtonStyle(.primary))
                .accessibilityIdentifier("club.welcome.done")
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.vertical, ZOSpace.m)
                .background(theme.backgroundPrimary)
        }
        .zoReviewPeak(.clubWelcome, when: askReview)
        .onAppear { askReview = true }
    }
}

import SwiftUI

/// Proof 41 "When a time passed": a planned workout whose time passed without a
/// start stays waiting on Today for three days. Plans move; no guilt, no streak talk.
enum MissedPlan {
    static let windowDays = 3

    static func latest(_ appointments: [WorkoutAppointment], now: Date = .now) -> WorkoutAppointment? {
        appointments
            .filter { $0.status == .scheduled && $0.startedSessionID == nil && $0.preparedSessionID == nil
                && $0.endsAt < now && now.timeIntervalSince($0.startsAt) < Double(windowDays) * 86_400 }
            .max { $0.startsAt < $1.startsAt }
    }

    /// The same clock time tomorrow, so moving keeps the person's usual time.
    static func tomorrow(at time: Date, now: Date = .now, calendar: Calendar = .current) -> Date? {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
        return calendar.date(bySettingHour: parts.hour ?? 18, minute: parts.minute ?? 0, second: 0, of: tomorrow)
    }
}

struct MissedPlanCard: View {
    let appointment: WorkoutAppointment
    let onDoToday: () -> Void
    let onMoveToTomorrow: () -> Void
    let onSkip: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.calendar) private var calendar

    private var whenText: String {
        let time = appointment.startsAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(localization.locale))
        if calendar.isDateInYesterday(appointment.startsAt) { return localization.format("Yesterday at %1$@", .text(time)) }
        if calendar.isDateInToday(appointment.startsAt) { return localization.format("Today at %1$@", .text(time)) }
        let day = appointment.startsAt.formatted(.dateTime.weekday(.wide).locale(localization.locale))
        return localization.format("%1$@ at %2$@", .text(day), .text(time))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text(whenText).zoText(.caption).foregroundStyle(theme.textSecondary)
                Text(localization.format("%1$@ is still waiting", .text(appointment.title)))
                    .zoThemeText(.title)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Plans move. Your week isn't lost.").zoText(.body).foregroundStyle(theme.textSecondary)
            }
            Button(localization.string("Do it today"), action: onDoToday)
                .buttonStyle(ZOButtonStyle(.primary))
                .accessibilityIdentifier("today.missed.doToday")
            HStack(spacing: ZOSpace.s) {
                Button(localization.string("Move to tomorrow"), action: onMoveToTomorrow)
                    .buttonStyle(ZOButtonStyle(.secondary))
                Button(localization.string("Skip this one"), action: onSkip)
                    .buttonStyle(ZOButtonStyle(.secondary))
            }
        }
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
        .accessibilityElement(children: .contain)
    }
}

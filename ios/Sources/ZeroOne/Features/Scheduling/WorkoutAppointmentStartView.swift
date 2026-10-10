import SwiftUI

/// Proof 41's "When it is time": the date tile with the appointment's own
/// time, the workout with its counts and first exercises, the warm-up length
/// and Start in the dock. Start is the host's existing pending-start path;
/// Close changes nothing. "Move to tomorrow" and the coach line need data
/// and actions this screen is not given, so they are not drawn.
struct WorkoutAppointmentStartView: View {
    let appointment: WorkoutAppointment
    let session: WorkoutSession?
    @Binding var warmUp: WorkoutWarmUpLength
    let onStart: () -> Void
    let onClose: () -> Void
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    /// Shown in the iPhone's current zone, as the schedule list does: travel
    /// changes the displayed local time, never the saved instant.
    private var zone: TimeZone { .current }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    whenTile
                    Text(appointment.title)
                        .zoText(.display)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, ZOSpace.l)
                    if let session {
                        sessionFacts(session)
                    } else {
                        Text("This exact workout is no longer available. Edit its appointment to choose another.")
                            .zoText(.body)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(ZOSpace.cardPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.card))
                            .padding(.top, ZOSpace.m)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.top, ZOSpace.xs)
                .padding(.bottom, ZOSpace.xl)
                .frame(maxWidth: .infinity)
            }
            .background(theme.backgroundPrimary.ignoresSafeArea())
            .foregroundStyle(theme.textPrimary)
            .tint(theme.textPrimary)
            .navigationTitle("Scheduled workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) { Image(systemName: "xmark").zoIcon(ZOIcon.row) }
                        .buttonStyle(ZOButtonStyle(.round))
                        .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session != nil {
                    Button("Start workout", action: onStart)
                        .buttonStyle(ZOButtonStyle(.primary))
                        .frame(maxWidth: 620)
                        .padding(.horizontal, ZOSpace.screenMargin)
                        .padding(.vertical, ZOSpace.m)
                        .frame(maxWidth: .infinity)
                        .background(theme.backgroundPrimary)
                }
            }
        }
    }

    /// Proof `.zo-when`: the date tile and the appointment's time in its own
    /// zone. A time that has passed says so; it never counts as done.
    private var whenTile: some View {
        let tile = WorkoutSchedulePresentation.dateTile(for: appointment.startsAt, zone: zone, locale: localization.locale)
        let time = appointment.startsAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)
            .locale(localization.locale))
        let headline: String = switch WorkoutSchedulePresentation.relativeDay(of: appointment.startsAt, now: .now, zone: zone) {
        case .today: localization.format("Today at %1$@", .text(time))
        case .tomorrow: localization.format("Tomorrow at %1$@", .text(time))
        case .other: appointment.startsAt.formatted(Date.FormatStyle(date: .complete, time: .shortened, timeZone: zone)
            .locale(localization.locale))
        }
        return HStack(spacing: ZOSpace.m) {
            WorkoutAppointmentDateTile(tile: tile)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .zoText(.section)
                    .fixedSize(horizontal: false, vertical: true)
                Text(appointment.startsAt < .now
                     ? localization.string("Scheduled time passed; no completion recorded")
                     : localization.format("Reserved %1$@", .text(workoutCopy.quantity(appointment.durationMinutes, .minutes))))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, ZOSpace.l)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.card))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sessionFacts(_ session: WorkoutSession) -> some View {
        let summary = WorkoutSchedulePresentation.StartSummary(session: session)
        Text(startMeta(summary))
            .zoText(.caption)
            .foregroundStyle(theme.textSecondary)
            .padding(.top, ZOSpace.xs)

        posterStack(summary)
            .padding(.top, ZOSpace.m)

        ExerciseDetailSubhead(title: "Workout")
        VStack(spacing: 0) {
            ForEach(Array(session.exercises.enumerated()), id: \.element.id) { index, exercise in
                if index > 0 {
                    Rectangle().fill(theme.strokeSubtle).frame(height: ZOStroke.hairline)
                        .accessibilityHidden(true)
                }
                HStack(alignment: .firstTextBaseline, spacing: ZOSpace.m) {
                    Text(exercise.plan.name)
                        .zoText(.section)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(localization.format("%1$@ × %2$@", .text(exercise.plan.plannedSetCount.formatted()),
                                             .text(workoutCopy.prescription(exercise.plan.prescription))))
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, ZOSpace.s)
                .frame(minHeight: ZOSpace.rowMinHeight)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, ZOSpace.l)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.card))

        ExerciseDetailSubhead(title: "Warm-up", trailing: warmUpTrailing(session.warmUp))
        ZOSegmentedControl("Warm-up", selection: $warmUp, options: [
            ZOSegment(value: WorkoutWarmUpLength.full, label: Text("Full")),
            ZOSegment(value: WorkoutWarmUpLength.short, label: Text("Short")),
            ZOSegment(value: WorkoutWarmUpLength.none, label: Text("Skip"))
        ])
    }

    private func startMeta(_ summary: WorkoutSchedulePresentation.StartSummary) -> String {
        var parts = [workoutCopy.quantity(summary.exerciseCount, .exercises),
                     workoutCopy.quantity(summary.setCount, .sets)]
        if let minutes = summary.minutes {
            parts.append(localization.format("about %1$@", .text(workoutCopy.quantity(minutes, .minutes))))
        }
        return parts.joined(separator: " · ")
    }

    /// The warm-up's own estimate for the chosen length, as the library
    /// states it; nothing when the session has no warm-up.
    private func warmUpTrailing(_ warmUp: WorkoutWarmUp?) -> String? {
        guard let warmUp else { return nil }
        switch self.warmUp {
        case .full: return localization.format("About %1$@", .text(workoutCopy.quantity(warmUp.estimatedMinutes, .minutes)))
        case .short: return localization.format("About %1$@", .text(workoutCopy.quantity(max(2, warmUp.estimatedMinutes - 2), .minutes)))
        case .none: return localization.string("Straight to set 1")
        }
    }

    /// Proof `.zo-thumbs`: 36 pt posters overlapping by 8 pt, then "+N".
    private func posterStack(_ summary: WorkoutSchedulePresentation.StartSummary) -> some View {
        HStack(spacing: -8) {
            ForEach(Array(summary.stackExerciseIDs.enumerated()), id: \.offset) { _, exerciseID in
                CustomWorkoutExerciseThumbnail(exercise: MoveKitExerciseCatalog.programmePoster(for: exerciseID)?.exercise,
                                               width: 36, height: 36, cornerRadius: 10)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.backgroundPrimary, lineWidth: 2)
                    }
            }
            if summary.overflowCount > 0 {
                Text(verbatim: "+\(summary.overflowCount)")
                    .zoText(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(width: 36, height: 36)
                    .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.backgroundPrimary, lineWidth: 2)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Proof `.zo-when .cal`: a 48 pt tile, the weekday on ink at 11/18 bold,
/// the day of the month at 22/30 bold below. Decorative beside the words.
struct WorkoutAppointmentDateTile: View {
    let tile: WorkoutSchedulePresentation.DateTile
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(spacing: 0) {
            Text(tile.weekday.uppercased(with: localization.locale))
                .zoProofText(.mini, size: 11, lineHeight: 18, weight: 700, tracking: 0.6)
                .lineLimit(1)
                .foregroundStyle(theme.backgroundPrimary)
                .frame(maxWidth: .infinity, minHeight: 18)
                .background(theme.textPrimary)
            Text(tile.day.formatted())
                .zoProofText(.title, size: 22, lineHeight: 30, weight: 700, tabular: true)
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .frame(width: 48)
        .background(theme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

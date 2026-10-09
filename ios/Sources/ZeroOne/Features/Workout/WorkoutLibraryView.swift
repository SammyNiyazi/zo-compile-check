import CoreText
import SwiftUI

struct WorkoutLibraryView: View {
    let programmes: [WorkoutProgramme]
    let selectedProgrammeID: WorkoutProgrammeID?
    let activeSchedule: WorkoutProgrammeSchedule?
    /// False when the saved schedule could not be read. The coordinator keeps
    /// its last value then, so `activeSchedule` is not presented as current.
    let scheduleIsAvailable: Bool
    let workoutHistory: WorkoutHistoryRepository
    let customWorkouts: CustomWorkoutRepository
    let onOpenProfile: () -> Void
    let onSelect: (WorkoutProgrammeID) -> Void
    let onStartCustom: (CustomWorkout, WorkoutWarmUpLength) -> Bool
    let outdoorActivityInProgress: Bool
    let onOpenOutdoor: (OutdoorActivityKind) -> Void
    var music: WorkoutMusicStore? = nil
    var musicNamespace: Namespace.ID? = nil
    /// Proof 38's header routes. Each round button appears only when its
    /// caller supplies the route; the library never invents one.
    var onOpenSchedule: (() -> Void)? = nil
    var onOpenHistory: (() -> Void)? = nil

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }
    private var localizedCalendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = localization.locale
        return calendar
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsMoveKit = false
    @State private var searchText = ""
    @State private var selectedFilter: LibraryFilter = .forYou
    @State private var selectedExperienceBand = ""
    @State private var selectedSection: LibrarySection = .plans
    @State private var selectedExercise: MoveKitExercise?
    @State private var selectedMuscle: String?
    @State private var selectedEquipment: String?
    @State private var selectedCustomDraft: CustomWorkout?
    @State private var pendingCustomWorkout: CustomWorkout?
    @State private var showsDraftConflict = false
    @State private var showsDraftError = false
    @State private var selectedCustomStartID: UUID?
    @State private var selectedCustomWarmUpLength: WorkoutWarmUpLength = .full
    @State private var showsCustomStartError = false
    @FocusState private var searchIsFocused: Bool

    /// Planned days, "Your plan" and the next session come only from a
    /// schedule that could be read.
    private var scheduleState: WorkoutScheduleAvailability {
        WorkoutScheduleAvailability(schedule: activeSchedule, isAvailable: scheduleIsAvailable)
    }

    private enum LibrarySection: String, CaseIterable {
        case plans = "Plans"
        case mine = "My workouts"
        case exercises = "Exercises"
    }

    private enum LibraryFilter: String, CaseIterable {
        case forYou = "All plans"
        case build = "Build muscle"
        case arms = "Arms"
        case biceps = "Biceps"
        case consistency = "Consistency"
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    libraryHeader

                    ZOSegmentedControl("Workout library", selection: $selectedSection, options: LibrarySection.allCases.map { section in ZOSegment(value: section, label: Text(localization.string(section.rawValue))) })
                    .padding(.top, ZOSpace.m)
                    .accessibilityIdentifier("workout.librarySection")

                    if selectedSection == .plans {
                        // Proof 38: your week, the plans, then beyond the gym.
                        yourWeekCard
                            .padding(.top, 14)

                        librarySubhead("Plans for you")
                        programmeFilters

                        LazyVStack(spacing: ZOSpace.s) {
                            ForEach(filteredProgrammes) { programme in
                                Button {
                                    onSelect(programme.id)
                                } label: {
                                    programmeRow(programme)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(programmeAccessibilityLabel(programme))
                                .accessibilityHint("Opens programme details.")
                            }
                        }
                        .padding(.top, ZOSpace.m)

                        if filteredProgrammes.isEmpty {
                            ContentUnavailableView(
                                "No plans match",
                                systemImage: "line.3.horizontal.decrease.circle",
                                description: Text("Try another filter or show all plans.")
                            )
                                .foregroundStyle(theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, ZOSpace.x4)
                            Button("Show all plans") {
                                searchText = ""
                                selectedFilter = .forYou
                                selectedExperienceBand = ""
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.textPrimary)
                            .frame(maxWidth: .infinity)
                        }

                        librarySubhead("Beyond the gym")
                        outdoorActivitySection
                    } else if selectedSection == .mine {
                        customWorkoutSection
                            .padding(.top, 14)
                    } else {
                        searchField
                            .padding(.top, 14)
                        exerciseLibrary
                    }

                    Spacer(minLength: 110)
                }
                .frame(maxWidth: 620, minHeight: proxy.size.height, alignment: .leading)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.top, ZOSpace.m)
            }
            .scrollIndicators(.hidden)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsMoveKit) {
            Group {
                NavigationStack {
                    ScrollView {
                        MoveKitExerciseCarousel(style: .full)
                            .padding(ZOSpace.l)
                    }
                    .background(theme.backgroundPrimary)
                    .navigationTitle("MoveKit")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showsMoveKit = false }
                        }
                    }
                }
            }
            .zoSheet()
        }
        .sheet(item: $selectedExercise) { exercise in
            Group {
                NavigationStack {
                    exerciseDetail(exercise)
                }
                .zeroOneTheme(theme)
                .preferredColorScheme(theme.colorScheme)
            }
            .zoSheet(theme)
        }
        .sheet(item: $selectedCustomDraft) { workout in
            Group {
                CustomWorkoutBuilderView(
                    workout: workout,
                    isNew: !customWorkouts.workouts.contains(where: { $0.id == workout.id }),
                    repository: customWorkouts,
                    onStart: onStartCustom
                )
                .zeroOneTheme(theme)
                .preferredColorScheme(theme.colorScheme)
            }
            .zoSheet(theme)
        }
        .alert("Could not start session", isPresented: $showsCustomStartError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your saved session is still here. Try again after resolving any active workout recovery message.")
        }
        .alert("Draft change not confirmed", isPresented: $showsDraftError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your unfinished workout was not discarded. Its local data has not been replaced.")
        }
        .confirmationDialog("An unfinished workout is saved", isPresented: $showsDraftConflict) {
            Button("Resume unfinished workout") {
                selectedCustomDraft = customWorkouts.draft?.workout
                pendingCustomWorkout = nil
            }
            Button("Discard draft and continue", role: .destructive) {
                if customWorkouts.discardDraft() {
                    selectedCustomDraft = pendingCustomWorkout
                    pendingCustomWorkout = nil
                } else {
                    showsDraftError = true
                }
            }
            Button("Keep draft") { pendingCustomWorkout = nil }
        } message: {
            Text("Only one unfinished workout can be kept on this iPhone.")
        }
        .onChange(of: selectedSection) { _, _ in searchText = "" }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_WORKOUT_STATE"] == "movekit" {
                showsMoveKit = true
            } else if ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_WORKOUT_STATE"] == "exercises" {
                selectedSection = .exercises
            }
            #endif
        }
    }

    /// Proof 38: "Workout" with the schedule and history routes as round
    /// buttons, then the profile button the tab already had.
    private var libraryHeader: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: ZOSpace.s))
        return layout {
            Text("Workout")
                .zoThemeHeading(.display, context: .headRowDisplay)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: ZOSpace.s) {
                Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 0 : ZOSpace.m)

            if let onOpenSchedule {
                Button(action: onOpenSchedule) {
                    Image(systemName: "calendar").zoIcon(ZOIcon.row)
                }
                .buttonStyle(ZOButtonStyle(.round))
                .accessibilityLabel("Schedule")
            }
            if let onOpenHistory {
                Button(action: onOpenHistory) {
                    Image(systemName: "clock").zoIcon(ZOIcon.row)
                }
                .buttonStyle(ZOButtonStyle(.round))
                .accessibilityLabel("History")
            }
            ZeroOneProfileButton(action: onOpenProfile)
            }
        }
    }

    /// Proof `.zo-weekhead`: a section title with an optional trailing caption.
    private func librarySubhead(_ title: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
            Text(localization.string(title))
                .zoText(.section)
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: ZOSpace.s)
            if let trailing {
                Text(trailing)
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.top, 22)
        .padding(.bottom, ZOSpace.s)
        .padding(.horizontal, 2)
    }

    /// Side by side, or stacked at accessibility sizes so text keeps its width.
    private var rowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: ZOSpace.m))
    }

    // MARK: Your week

    /// Proof 38's week card. Done days come only from readable History, planned
    /// days only from the confirmed schedule; programme progress is never guessed.
    private var yourWeekCard: some View {
        let calendar = localizedCalendar
        let week = WorkoutWeekPresentation(
            schedule: scheduleState,
            entries: workoutHistory.availability == .available ? workoutHistory.entries : nil,
            now: .now, calendar: calendar
        )
        let programme = scheduleState.currentSchedule.flatMap { schedule in
            programmes.first { $0.id == schedule.programmeID }
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                Text("Your week")
                    .zoText(.section)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: ZOSpace.s)
                Text(weekCountText(week.count))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }

            weekStrip(week, calendar: calendar)
                .padding(.top, ZOSpace.m)

            if week.scheduleIsUnavailable {
                // Not "no plan": the saved days exist but could not be read.
                Text("Your training days couldn't be read, so none are shown. Nothing was changed.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, ZOSpace.m)
            }

            if let programme, let day = week.nextPlannedDay {
                nextSessionRow(programme, day: day, calendar: calendar)
                    .padding(.top, 14)
            }
        }
        .padding(ZOSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout.yourWeek")
    }

    private func weekCountText(_ count: WorkoutWeekPresentation.Count) -> String {
        switch count {
        case let .planned(done, planned, otherDays):
            let plannedText = localization.format("%1$lld of %2$lld planned days done", .integer(done), .integer(planned))
            guard otherDays > 0 else { return plannedText }
            // Workouts on unplanned days are their own fact, never planned sessions.
            return plannedText + " · " + localization.format("%1$lld more on other days", .integer(otherDays))
        case let .unplanned(done):
            return localization.format("%1$lld done this week", .integer(done))
        case .historyUnavailable:
            return localization.string("History unavailable")
        }
    }

    /// Proof `.zo-week7`: done days are ink discs with a check, planned days
    /// rings, others quiet; today is outlined.
    private func weekStrip(_ week: WorkoutWeekPresentation, calendar: Calendar) -> some View {
        HStack(alignment: .top, spacing: ZOSpace.xs) {
            ForEach(week.days) { day in
                VStack(spacing: 6) {
                    Text(calendar.veryShortStandaloneWeekdaySymbols[day.weekday - 1])
                        .zoText(.caption)
                        .fontWeight(day.isToday ? .bold : nil)
                        .foregroundStyle(day.isToday ? theme.textPrimary : theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    weekDisc(day)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(weekDayAccessibilityLabel(day, calendar: calendar))
            }
        }
    }

    private func weekDisc(_ day: WorkoutWeekPresentation.Day) -> some View {
        ZStack {
            if day.isDone {
                Circle().fill(theme.textPrimary)
                Image(systemName: "checkmark")
                    .zoIcon(ZOIcon.inline)
                    .foregroundStyle(theme.backgroundPrimary)
            } else {
                if day.isPlanned {
                    Circle().strokeBorder(theme.textPrimary, lineWidth: 2)
                } else {
                    Circle().fill(theme.surfaceSecondary)
                }
                Text(day.dayOfMonth.formatted())
                    .zoText(.label)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(day.isPlanned ? theme.textPrimary : theme.textSecondary)
            }
        }
        .frame(width: 36, height: 36)
        .overlay {
            // Proof: outline 2 pt, offset 2 pt. Drawn outside the 36 pt disc
            // without taking layout, so seven days fit a phone-width card.
            if day.isToday {
                Circle().strokeBorder(theme.textPrimary, lineWidth: 2).padding(-4)
            }
        }
    }

    private func weekDayAccessibilityLabel(_ day: WorkoutWeekPresentation.Day, calendar: Calendar) -> String {
        var parts = [day.date.formatted(.dateTime.weekday(.wide).day().locale(localization.locale))]
        if day.isToday { parts.append(localization.string("Today")) }
        if day.isDone { parts.append(localization.string("Workout saved")) }
        if day.isPlanned { parts.append(localization.string("Planned training day")) }
        return parts.joined(separator: ", ")
    }

    /// The next planned session of the confirmed plan. Its title comes from the
    /// programme's own rotation over saved History; the time is the authored
    /// estimate. "Open" leads to the plan, where the warm-up is chosen and the
    /// session starts.
    private func nextSessionRow(_ programme: WorkoutProgramme, day: Date, calendar: Calendar) -> some View {
        let historyReadable = workoutHistory.availability == .available
        let title = historyReadable
            ? programme.makeSession(previousHistory: workoutHistory.entries, progressionAllowed: false).title
            : programme.title
        let when = calendar.isDate(day, inSameDayAs: .now)
            ? localization.string("Today")
            : day.formatted(.dateTime.weekday(.wide).locale(localization.locale))
        return rowLayout {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .zoText(.section)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(localization.format("%1$@ · about %2$@", .text(when),
                                         .text(workoutCopy.quantity(programme.durationMinutes, .minutes))))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button(localization.string("Open")) { onSelect(programme.id) }
                .buttonStyle(WorkoutLibraryCompactButtonStyle(isPrimary: true))
                .accessibilityLabel(localization.format("Open %1$@", .text(programme.title)))
                .accessibilityHint("Opens the plan, where you choose the warm-up and start.")
        }
        .padding(.top, ZOSpace.m)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.strokeSubtle).frame(height: ZOStroke.hairline)
        }
    }

    // MARK: Plans

    /// Proof `.zo-chips`: the plan filters, then the existing level choice.
    private var programmeFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: ZOSpace.s) {
                ForEach(LibraryFilter.allCases, id: \.self) { filter in
                    Button(localization.string(filter.rawValue)) { selectedFilter = filter }
                        .buttonStyle(ZOChipStyle(isSelected: selectedFilter == filter))
                }
                Menu {
                    Picker("Programme level", selection: $selectedExperienceBand) {
                        Text("All levels").tag("")
                        ForEach(Array(Set(programmes.map(\.experienceBand))).sorted(), id: \.self) { band in
                            Text(workoutCopy.difficulty(band)).tag(band)
                        }
                    }
                } label: {
                    HStack(spacing: ZOSpace.xs) {
                        Text(selectedExperienceBand.isEmpty
                             ? localization.string("All levels") : workoutCopy.difficulty(selectedExperienceBand))
                        Image(systemName: "chevron.down").zoIcon(12)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(ZOChipStyle(isSelected: !selectedExperienceBand.isEmpty))
                .accessibilityIdentifier("workout.programmeLevel")
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    /// Proof `.zo-plan`: the poster frame of the plan's first exercise with a
    /// real MoveKit poster, cropped square, then the authored facts. The
    /// current plan carries an ink badge; its progress is not invented.
    private func programmeRow(_ programme: WorkoutProgramme) -> some View {
        let poster = programme.posterMatch
        let isCurrent = scheduleState.isCurrentPlan(programme.id)
        return rowLayout {
            CustomWorkoutExerciseThumbnail(exercise: poster?.exercise, width: 76, height: 76,
                                           cornerRadius: ZORadius.control)
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text(verbatim: programme.title)
                    .zoText(.section)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(localization.format("%1$@ · %2$@ · %3$@",
                    .text(workoutCopy.quantity(programme.durationWeeks, .weeks)),
                    .text(workoutCopy.quantity(programme.sessions.count, .sessions)),
                    .text(workoutCopy.quantity(programme.durationMinutes, .minutes))))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let poster, case .variation = poster.relationship {
                    // The picture is an illustrative variation, never an exact match.
                    Text(poster.relationship.label)
                        .zoText(.caption)
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isCurrent {
                    ZOBadge(text: localization.string("Your plan"), isInk: true)
                        .padding(.top, 2)
                } else if selectedProgrammeID == programme.id {
                    ZOBadge(text: localization.string("Last opened"))
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .zoIcon(ZOIcon.inline)
                .foregroundStyle(theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(ZOSpace.m)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: .continuous))
        .contentShape(Rectangle())
    }

    /// Proof 38's My workouts: New workout, the unsaved draft as a banner,
    /// then each saved workout as a card. Every action is the existing one:
    /// create, resume the draft (with the one-draft conflict dialog), Edit,
    /// and Start with the warm-up choice before the session opens.
    private var customWorkoutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                openCustomWorkout(CustomWorkout(name: ""))
            } label: {
                Label("New workout", systemImage: "plus")
                    .labelStyle(ZOIconLabelStyle())
            }
            .buttonStyle(ZOButtonStyle(.secondary, wide: true))
            .disabled(!customWorkouts.isAvailable)
            .accessibilityIdentifier("workout.createCustomSession")

            if !customWorkouts.isAvailable {
                Text("Saved sessions are unavailable. Existing local data has not been replaced.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.top, ZOSpace.s)
            }

            if customWorkouts.isDraftAvailable, let unfinished = customWorkouts.draft {
                draftBanner(unfinished.workout)
                    .padding(.top, ZOSpace.m)
            } else if !customWorkouts.isDraftAvailable {
                Text("An unfinished workout cannot be recovered. Existing local draft data has not been replaced.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.top, ZOSpace.m)
            }

            librarySubhead("Your sessions", trailing: customWorkouts.workouts.count.formatted())

            if customWorkouts.workouts.isEmpty && customWorkouts.draft == nil {
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text("Pick. Shape. Train.")
                        .zoThemeText(.title)
                        .foregroundStyle(theme.textPrimary)
                    Text("Choose exercises, set your order and save a workout you can repeat.")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ZOSpace.l)
                .zoThemeCardSurface()
            }

            VStack(spacing: ZOSpace.s) {
                ForEach(customWorkouts.workouts) { workout in
                    savedWorkoutCard(workout)
                }
            }
        }
    }

    /// Proof `.zo-banner`: the draft is kept on this iPhone until it is saved
    /// or discarded; Finish reopens it in the builder.
    private func draftBanner(_ draft: CustomWorkout) -> some View {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? localization.string("Untitled workout") : draft.name
        return rowLayout {
            Image(systemName: "clock")
                .zoIcon(ZOIcon.row)
                .foregroundStyle(theme.textPrimary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.format("%1$@ isn't saved yet", .text(name)))
                    .zoText(.section)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your changes are kept on this iPhone")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button(localization.string("Finish")) { selectedCustomDraft = draft }
                .buttonStyle(WorkoutLibraryCompactButtonStyle(isPrimary: false))
                .accessibilityLabel(localization.format("Finish %1$@", .text(name)))
                .accessibilityHint("Reopens the unsaved workout in the builder.")
        }
        .padding(.vertical, ZOSpace.m)
        .padding(.horizontal, 14)
        .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ZORadius.card))
        .accessibilityIdentifier("workout.customDraftBanner")
    }

    /// Proof 38's saved card: name and counts, More (Edit), the first four
    /// exercise pictures stacked, Start, then the set rail. The last-done
    /// date is left out: History does not record which saved workout a
    /// session came from.
    private func savedWorkoutCard(_ workout: CustomWorkout) -> some View {
        let card = CustomWorkoutCardPresentation(workout: workout)
        let isStarting = selectedCustomStartID == workout.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: ZOSpace.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: workout.name)
                        .zoText(.section)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(savedWorkoutMeta(card))
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Menu {
                    Button("Edit", systemImage: "pencil") {
                        selectedCustomStartID = nil
                        openCustomWorkout(workout)
                    }
                } label: {
                    Image(systemName: "ellipsis").zoIcon(ZOIcon.row)
                }
                .menuStyle(.button)
                .buttonStyle(ZOButtonStyle(.round))
                .accessibilityLabel(localization.format("More for %1$@", .text(workout.name)))
            }

            HStack(alignment: .center, spacing: 10) {
                posterStack(card)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(localization.string(isStarting ? "Close" : "Start")) {
                    if isStarting {
                        selectedCustomStartID = nil
                    } else {
                        selectedCustomWarmUpLength = workout.warmUpLength ?? .full
                        selectedCustomStartID = workout.id
                    }
                }
                .buttonStyle(WorkoutLibraryCompactButtonStyle(isPrimary: false))
                .accessibilityLabel(localization.format("%1$@ %2$@", .text(localization.string(isStarting ? "Close" : "Start")), .text(workout.name)))
                .accessibilityHint("Choose a warm-up length before starting this session.")
            }

            setRail(card.railGroups)

            if isStarting {
                CustomWorkoutWarmUpPicker(selection: $selectedCustomWarmUpLength)
                if let music, let context = customReadyMusicContext(for: workout) {
                    WorkoutMusicLane(music: music,
                        context: context,
                        musicNamespace: musicNamespace)
                }
                Button(customStartButtonTitle) {
                    let started = withAnimation(WorkoutMusicJoinTransition.animation(
                        spatialMotion: !reduceMotion && !voiceOverEnabled && !dynamicTypeSize.isAccessibilitySize
                    )) { onStartCustom(workout, selectedCustomWarmUpLength) }
                    if !started {
                        showsCustomStartError = true
                    }
                }
                .buttonStyle(ZOButtonStyle(.primary))
                .accessibilityIdentifier("customWorkout.confirmStart")
                .accessibilityHint("Opens this saved session with the selected warm-up length.")
            }
        }
        .padding(ZOSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
    }

    private func savedWorkoutMeta(_ card: CustomWorkoutCardPresentation) -> String {
        var parts = [workoutCopy.quantity(card.exerciseCount, .exercises)]
        if let sets = card.setCount { parts.append(workoutCopy.quantity(sets, .sets)) }
        parts.append(card.estimatedMinutes.map {
            localization.format("about %1$@", .text(workoutCopy.quantity($0, .minutes)))
        } ?? localization.string("Time varies"))
        return parts.joined(separator: " · ")
    }

    /// Proof `.zo-thumbs`: 36 pt squares overlapping by 8 pt, each ringed in
    /// the card colour, then "+N". Exercises without exact media keep the
    /// honest no-video surface.
    private func posterStack(_ card: CustomWorkoutCardPresentation) -> some View {
        HStack(spacing: -8) {
            ForEach(Array(card.stack.enumerated()), id: \.offset) { _, exercise in
                CustomWorkoutExerciseThumbnail(exercise: exercise, width: 36, height: 36, cornerRadius: 10)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.surfacePrimary, lineWidth: 2)
                    }
            }
            if card.overflowCount > 0 {
                Text("+\(card.overflowCount)")
                    .zoText(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.surfacePrimary, lineWidth: 2)
                    }
            }
        }
        .accessibilityHidden(true)
    }

    /// Proof 38's set rail under each saved workout: one 6 pt segment per
    /// planned set, all the same width, with a wider gap between exercises.
    /// Decorative; the counts are in words above. A malformed older count is
    /// drawn as at most 12 segments.
    private func setRail(_ groups: [Int]) -> some View {
        let segments = groups.enumerated().flatMap { group, sets in
            (0 ..< min(12, max(1, sets))).map { (group: group, set: $0) }
        }
        return HStack(spacing: 2 * ZOStroke.hairline) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.set == 0, segment.group > 0 {
                    Color.clear.frame(width: ZOSpace.xs)
                }
                ZORailSegment(mark: .ahead, radius: 2 * ZOStroke.hairline, motionEnabled: false)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: ZOStroke.railApp)
        .accessibilityHidden(true)
    }

    private func openCustomWorkout(_ workout: CustomWorkout) {
        if let unfinished = customWorkouts.draft, unfinished.workout.id != workout.id {
            pendingCustomWorkout = workout
            showsDraftConflict = true
        } else {
            selectedCustomDraft = customWorkouts.draft?.workout.id == workout.id
                ? customWorkouts.draft?.workout : workout
        }
    }

    /// Proof 38's "Beyond the gym": Walk and Run as list rows. While an
    /// activity is unfinished, one row returns to it.
    private var outdoorActivitySection: some View {
        VStack(spacing: 0) {
            if outdoorActivityInProgress {
                outdoorRow(title: "Resume activity", detail: "Return to your walk or run to resume or finish it.",
                           icon: "figure.walk") { onOpenOutdoor(.walk) }
            } else {
                outdoorRow(title: "Walk", detail: "Time, distance and steps", icon: "figure.walk") {
                    onOpenOutdoor(.walk)
                }
                Rectangle().fill(theme.strokeSubtle).frame(height: ZOStroke.hairline)
                    .accessibilityHidden(true)
                outdoorRow(title: "Run", detail: "With the route, if you want it", icon: "map") {
                    onOpenOutdoor(.run)
                }
            }
        }
        .padding(.horizontal, ZOSpace.l)
        .zoThemeCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout.outdoorActivity")
    }

    /// Proof `.zo-row`: a 28 pt lead icon, title and caption, a chevron.
    private func outdoorRow(title: String, detail: String, icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: ZOSpace.m) {
                Image(systemName: icon)
                    .zoIcon(ZOIcon.row)
                    .frame(width: 28)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localization.string(title))
                        .zoText(.section)
                        .foregroundStyle(theme.textPrimary)
                    Text(localization.string(detail))
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .zoIcon(ZOIcon.inline)
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, ZOSpace.s)
            .frame(minHeight: ZOSpace.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func customReadyMusicContext(for workout: CustomWorkout) -> WorkoutMusicContext? {
        guard var session = workout.makeSession() else { return nil }
        session.selectWarmUpLength(selectedCustomWarmUpLength, at: .now)
        return WorkoutMusicContext(session: session, stage: .ready)
    }

    private var customStartButtonTitle: String {
        switch selectedCustomWarmUpLength {
        case .full: return localization.string("Start warm-up")
        case .short: return localization.string("Start short warm-up")
        case .none: return localization.string("Start set 1")
        }
    }

    /// Proof 38's search field, naming the real size of the bundled library.
    private var searchField: some View {
        HStack(spacing: ZOSpace.m) {
            Image(systemName: "magnifyingglass")
                .zoIcon(ZOIcon.row)
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)

            TextField(localization.format("Search %1$lld exercises", .integer(MoveKitExercise.all.count)), text: $searchText)
                .zoText(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(theme.textPrimary)
                .focused($searchIsFocused)
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .zoIcon(ZOIcon.row)
                        .foregroundStyle(theme.textSecondary)
                        .frame(minWidth: ZOSpace.hitTarget, minHeight: ZOSpace.hitTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear workout search")
            }
        }
        .padding(.leading, ZOSpace.l)
        .padding(.trailing, searchText.isEmpty ? ZOSpace.l : ZOSpace.xs)
        .frame(minHeight: ZOSpace.rowMinHeight)
        .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .control, radius: ZORadius.control).resolvedRadius))
        .overlay {
            // Proof `.zo-field.focus`: a 2 pt ink edge while typing, otherwise
            // the 1.5 pt strong separator.
            RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .control, radius: ZORadius.control).resolvedRadius)
                .strokeBorder(searchIsFocused
                              ? theme.textPrimary
                              : theme.separatorStrong,
                              lineWidth: searchIsFocused ? ZOStroke.focus : ZOStroke.control)
        }
        .accessibilityElement(children: .contain)
    }

    /// Proof 38's Exercises: filters as chips, the selection's name and count,
    /// then a poster grid (two columns, one at accessibility sizes). Every
    /// picture is the exercise's own MoveKit poster frame; a missing one stays
    /// an honest no-video surface, never a drawn figure.
    private var exerciseLibrary: some View {
        let results = MoveKitExerciseCatalog.filter(
            query: searchText,
            muscle: selectedMuscle,
            equipment: selectedEquipment
        )
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
                            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
        return VStack(alignment: .leading, spacing: 0) {
            exerciseFilters

            librarySubhead(exerciseSelectionTitle,
                           trailing: workoutCopy.quantity(results.count, .exercises))

            if results.isEmpty {
                ContentUnavailableView(
                    "No matching exercises",
                    systemImage: "magnifyingglass",
                    description: Text("Try a shorter search or clear the filters.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, ZOSpace.x3)
                Button("Clear exercise filters") {
                    searchText = ""
                    selectedMuscle = nil
                    selectedEquipment = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(results) { exercise in
                        Button {
                            selectedExercise = exercise
                        } label: {
                            exerciseCard(exercise)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(exerciseAccessibilityLabel(exercise))
                        .accessibilityHint("Opens the inline exercise demonstration.")
                    }
                }
            }
        }
    }

    /// The filter in force, as the section title ("Dumbbell"), or all of them.
    /// `librarySubhead` localizes the key; catalog names stay as authored.
    private var exerciseSelectionTitle: String {
        switch (selectedEquipment, selectedMuscle) {
        case let (equipment?, muscle?): return "\(muscle) · \(equipment)"
        case let (equipment?, nil): return equipment
        case let (nil, muscle?): return muscle
        case (nil, nil): return "All exercises"
        }
    }

    /// Proof `.zo-excard`: the poster 112 pt tall, then the name and what it
    /// trains with what. A saved set is added only when History has one.
    private func exerciseCard(_ exercise: MoveKitExercise) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkoutLibraryPoster(exercise: exercise)
                .frame(maxWidth: .infinity)
                .frame(height: 112)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: exercise.name)
                    .zoText(.label)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = exerciseDetailLine(exercise) {
                    Text(verbatim: detail)
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let saved = exactSavedPerformance(for: exercise),
                   let lastSet = saved.latestSavedSet {
                    Text(localization.format("%1$@ · %2$@", .text(localization.string(saved.hasNewerUnknownDetails ? "Last identifiable" : "Last saved")), .text(workoutCopy.setSummary(lastSet))))
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, ZOSpace.s)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: .continuous))
    }

    private func exerciseDetailLine(_ exercise: MoveKitExercise) -> String? {
        WorkoutExerciseGridPresentation.detailLine(for: exercise)
    }

    private func exerciseAccessibilityLabel(_ exercise: MoveKitExercise) -> String {
        ([exercise.name] + [exerciseDetailLine(exercise)].compactMap { $0 }).joined(separator: ", ")
    }

    /// Proof `.zo-chips`: equipment first, as the proof shows, then muscles.
    private var exerciseFilters: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            exerciseFilterRow("Equipment", options: MoveKitExerciseCatalog.equipmentFilters, selection: $selectedEquipment)
            exerciseFilterRow("Muscle", options: MoveKitExerciseCatalog.muscleFilters, selection: $selectedMuscle)
        }
        .padding(.top, 10)
    }

    private func exerciseFilterRow(
        _ title: String,
        options: [String],
        selection: Binding<String?>
    ) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: ZOSpace.s) {
                ForEach(["All"] + options, id: \.self) { option in
                    let isSelected = option == "All"
                        ? selection.wrappedValue == nil
                        : selection.wrappedValue == option
                    Button(option == "All" ? localization.string("All") : option) {
                        selection.wrappedValue = option == "All" ? nil : option
                    }
                    .buttonStyle(ZOChipStyle(isSelected: isSelected))
                    .accessibilityLabel(option == "All" ? localization.format("All %1$@ categories", .text(localization.string(title))) : localization.format("%1$@ %2$@ filter", .text(option), .text(localization.string(title))))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    /// Proof 39's exercise page: the licensed loop cropped like
    /// `.zo-media.pose`, the name, the muscles and equipment as words, the
    /// catalog's own cue when the exercise maps to one, then "You and this
    /// exercise" from saved History. No body figure, no invented cue.
    private func exerciseDetail(_ exercise: MoveKitExercise) -> some View {
        let cue = MoveKitExerciseCatalog.workoutExerciseID(for: exercise.id)
            .flatMap { ExerciseLibrary.exercise(id: $0)?.shortCoachingCue }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let tags = ExerciseDetailPresentation.tags(muscleFocus: exercise.muscleFocus, equipment: exercise.equipment)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MoveKitVideoPlayer(exercise: exercise)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: .continuous))

                Text(exercise.name)
                    .zoThemeHeading(.display, context: .directScrollDisplay)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 14)

                if !tags.isEmpty {
                    ExerciseWordTags(tags: tags)
                        .padding(.top, ZOSpace.s)
                }

                Text("Movement demonstration. Follow your workout for sets, reps, and load.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, ZOSpace.s)

                if let cue {
                    ExerciseDetailSubhead(title: "How to do it")
                    ExerciseCueList(cues: [cue])
                }

                savedExerciseHistory(for: exercise)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, ZOSpace.xs)
            .padding(.bottom, ZOSpace.xl)
        }
        .background(theme.backgroundPrimary.ignoresSafeArea())
        .navigationTitle("Exercise")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { selectedExercise = nil }
            }
        }
    }

    private func exactSavedPerformance(for exercise: MoveKitExercise) -> RecordedExercisePerformance? {
        guard let exerciseID = MoveKitExerciseCatalog.workoutExerciseID(for: exercise.id),
              case let .recorded(performance) = workoutHistory.previousPerformance(for: exerciseID)
        else { return nil }
        return performance
    }

    /// Proof 39's "You and this exercise": the best set and its date, the
    /// heaviest set of each session as one line, and the latest sessions
    /// with every set. Only exact saved sets for this exercise; unreadable
    /// History and exercises without a seed mapping say so.
    @ViewBuilder
    private func savedExerciseHistory(for exercise: MoveKitExercise) -> some View {
        if let exerciseID = MoveKitExerciseCatalog.workoutExerciseID(for: exercise.id) {
            switch workoutHistory.previousPerformance(for: exerciseID) {
            case let .recorded(performance):
                let history = ExerciseHistoryPresentation(history: WorkoutExerciseHistory(
                    exerciseID: exerciseID, entries: workoutHistory.entries.map { WorkoutHistoryDisplayItem(entry: $0) }))
                ExerciseDetailSubhead(title: "You and this exercise",
                                      trailing: workoutCopy.quantity(history.sessionCount, .sessions))
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    if let best = history.best {
                        bestSetCard(best, points: history.topSets)
                    }
                    if !history.recentSessions.isEmpty {
                        recentSessionList(history.recentSessions, bestSetID: history.best?.setID)
                    }
                    if performance.hasNewerUnknownDetails {
                        Text("Some newer workouts have no exercise-level detail; this may not be your latest set.")
                            .zoText(.caption)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case let .noRecordedSets(hasUnknownDetails):
                ExerciseDetailSubhead(title: "You and this exercise")
                historyNote(hasUnknownDetails
                    ? "No identifiable saved sets. Older workouts lack exercise-level detail."
                    : "No saved sets yet.")
            case .unavailable:
                ExerciseDetailSubhead(title: "You and this exercise")
                historyNote("Saved workout history is unavailable on this device.")
            }
        }
    }

    private func historyNote(_ key: String) -> some View {
        Text(localization.string(key))
            .zoText(.body)
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(ZOSpace.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .zoThemeCardSurface()
    }

    private func bestSetLoadNumber(_ load: Load, locale: Locale) -> String {
        var number = String(load.value)
        if number.hasSuffix(".0") { number.removeLast(2) }
        number = number.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
        return number
    }

    /// Proof's best-set card: the caption, the load as a metric with reps as
    /// its unit, the date on an ink badge, then the line of session bests.
    private func bestSetCard(_ best: ExerciseHistoryPresentation.Best,
                             points: [ExerciseHistoryPresentation.Point]) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            HStack(alignment: .center, spacing: ZOSpace.m) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Best set")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(verbatim: bestSetLoadNumber(best.load, locale: localization.locale))
                            .zoThemeText(.metric)
                            .foregroundStyle(theme.textPrimary)
                        Text(verbatim: best.load.unit.rawValue)
                            .zoText(.label)
                            .foregroundStyle(theme.textSecondary)
                        Text(verbatim: "× \(best.reps.formatted())")
                            .zoText(.label)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(localization.format("Best set: %1$@, %2$@",
                    .text(workoutCopy.load(best.load)), .text(workoutCopy.quantity(best.reps, .reps))))
                Spacer(minLength: ZOSpace.s)
                HStack(spacing: ZOSpace.xs) {
                    Image(systemName: "star.fill")
                        .zoIcon(14)
                        .accessibilityHidden(true)
                    Text(best.completedAt.formatted(.dateTime.day().month(.abbreviated).locale(localization.locale)))
                        .zoText(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(theme.backgroundPrimary)
                .padding(.horizontal, 10)
                .frame(minHeight: 24)
                .background(theme.textPrimary, in: Capsule())
            }
            if points.count >= 2 {
                ExerciseTopSetChart(points: points, bestSessionID: best.sessionID,
                                    load: { workoutCopy.load($0) }, locale: localization.locale)
                    .frame(height: 120)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(localization.format("Heaviest set each session: %1$@",
                        .text(points.map { workoutCopy.load($0.load) }.joined(separator: ", "))))
            }
        }
        .padding(ZOSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
    }

    /// Proof `.zo-list` of sessions: the date, then each set as a chip; the
    /// best set is the ink chip.
    private func recentSessionList(_ sessions: [ExerciseHistoryPresentation.Session], bestSetID: UUID?) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                if index > 0 {
                    Rectangle().fill(theme.strokeSubtle).frame(height: ZOStroke.hairline)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.completedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                        .locale(localization.locale)))
                        .zoText(.section)
                        .foregroundStyle(theme.textPrimary)
                    ExerciseTagFlowLayout(spacing: 6) {
                        ForEach(session.sets) { set in
                            Text(verbatim: setChipText(set))
                                .zoText(.caption)
                                .fontWeight(set.id == bestSetID ? .semibold : .medium)
                                .monospacedDigit()
                                .foregroundStyle(set.id == bestSetID ? theme.backgroundPrimary : theme.textPrimary)
                                .padding(.horizontal, 9)
                                .frame(minHeight: 28)
                                .background(set.id == bestSetID ? theme.textPrimary : theme.surfaceSecondary,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .padding(.vertical, ZOSpace.s)
                .frame(maxWidth: .infinity, minHeight: ZOSpace.rowMinHeight, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, ZOSpace.l)
        .zoThemeCardSurface()
    }

    /// "22 kg × 9", or the existing wording for timed and unloaded sets.
    private func setChipText(_ set: CompletedSet) -> String {
        guard !set.isTimed, set.load.value > 0, set.isPerSide != true else {
            return set.load.value > 0 ? workoutCopy.setSummary(set) : workoutCopy.performance(set)
        }
        return "\(workoutCopy.load(set.load)) × \(set.reps.formatted())"
    }

    private var filteredProgrammes: [WorkoutProgramme] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let byFilter = programmes.filter { programme in
            guard selectedExperienceBand.isEmpty || programme.experienceBand == selectedExperienceBand else { return false }
            switch selectedFilter {
            case .forYou: return true
            case .build: return programme.id == .zeroOneBuild
            case .arms: return programme.id == .arms
            case .biceps: return programme.id == .biceps
            case .consistency: return programme.id == .zeroOneConsistency
            }
        }
        guard !query.isEmpty else { return byFilter }
        return byFilter.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
                || $0.experienceBand.localizedCaseInsensitiveContains(query)
                || $0.goalSupport.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func programmeAccessibilityLabel(_ programme: WorkoutProgramme) -> String {
        let facts = localization.format("%1$@, level %2$@, %3$@, %4$@", .text(programme.title), .text(workoutCopy.difficulty(programme.experienceBand)), .text(workoutCopy.quantity(programme.durationWeeks, .weeks)), .text(workoutCopy.quantity(programme.sessions.count, .sessions)))
        // The row's badge, which the button label would otherwise hide.
        if scheduleState.isCurrentPlan(programme.id) {
            return facts + ", " + localization.string("Your plan")
        }
        if selectedProgrammeID == programme.id {
            return facts + ", " + localization.string("Last opened")
        }
        return facts
    }
}

struct ProgrammeDetailView: View {
    let programme: WorkoutProgramme
    let previewSession: WorkoutSession
    let activeSchedule: WorkoutProgrammeSchedule?
    let scheduleIsAvailable: Bool
    let onBack: () -> Void
    let onStart: (WorkoutWarmUpLength) -> Void
    let onConfirmSchedule: (Set<Int>, WorkoutProgrammeSchedule?) throws -> Void
    let customWorkouts: CustomWorkoutRepository
    let onStartCustom: (CustomWorkout, WorkoutWarmUpLength) -> Bool
    var music: WorkoutMusicStore? = nil
    var onPrepareVolumePlan: (@MainActor (ProgrammeVolumeChange) async throws -> ProgrammeVolumeProposal)? = nil
    var onApplyVolumePlan: (@MainActor (ProgrammeVolumeProposal) async throws -> Void)? = nil
    var volumeChangeIsActive = false
    var volumeIsAvailable = true
    var onValidateVolume: (() throws -> Void)? = nil
    var onPrepareWeeklyPlan: (@MainActor (WeeklyTrainingChange, ReportedTrainingWeekdays) async throws -> WeeklyTrainingProposal)? = nil
    var onApplyWeeklyPlan: (@MainActor (WeeklyTrainingProposal) async throws -> WorkoutProgrammeSchedule)? = nil
    var musicNamespace: Namespace.ID? = nil

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }
    private var localizedCalendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = localization.locale
        return calendar
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedExercisePlan: ExercisePlan?
    @State private var showsWeeklyReview = false
    @State private var showsVolumeReview = false
    @Environment(\.zeroOneWellbeingAssessment) private var wellbeingAssessment
    @State private var customizationCopy: CustomWorkout?
    @State private var pendingCustomizationCopy: CustomWorkout?
    @State private var showsCustomizationDraftConflict = false
    @State private var showsCustomizationError = false
    @State private var customizationErrorMessage = ""
    @State private var showsEquipment = false
    @State private var showsSchedule = false
    @State private var selectedWarmUpLength: WorkoutWarmUpLength = .full

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: ZOSpace.xl) {
                    detailHeader

                    // Proof 9: the cover, the week grid, then the programme's
                    // own words. Everything below keeps its existing gates.
                    VStack(alignment: .leading, spacing: ZOSpace.m) {
                        ProgrammeCoverView(
                            programme: programme,
                            cover: cover,
                            chips: coverChips(cover)
                        )
                        if dynamicTypeSize.isAccessibilitySize {
                            // The cover's type follows its width, not Dynamic
                            // Type; the name is repeated at the reader's size.
                            Text(verbatim: programme.title)
                                .zoThemeText(.display)
                                .foregroundStyle(theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityHidden(true)
                        }
                        programmeWeekCard(cover)
                        programmeNote
                    }

                    VStack(alignment: .leading, spacing: ZOSpace.s) {
                        Button { showsEquipment.toggle() } label: {
                            HStack {
                                Text("EQUIPMENT")
                                    .zoText(.caption)

                                Spacer()
                                Image(systemName: showsEquipment ? "chevron.up" : "chevron.down")
                            }
                            .foregroundStyle(theme.textSecondary)
                        }
                        .buttonStyle(.plain)

                        Text(showsEquipment ? programme.equipmentContext : compactEquipment)
                            .zoText(.section)
                            .foregroundStyle(theme.textPrimary)
                    }

                    sessionPreview

                    if let music {
                        WorkoutMusicLane(music: music, context: readyMusicContext,
                            musicNamespace: musicNamespace)
                    }

                    Button("Customize a copy before starting", action: customizeSession)
                        .buttonStyle(ZOButtonStyle(.secondary))
                        .disabled(!volumeIsAvailable)
                        .accessibilityIdentifier("workout.customizeProgrammeCopy")
                        .accessibilityHint("Opens an editable copy. Save and review it before starting a workout.")
                    Text("Change sets, rep or time ranges, rest and starting loads in your copy.")
                        .zoText(.caption).foregroundStyle(theme.textSecondary)

                    scheduleCard

                        exerciseSequence
                            .id("exercise-sequence")

                        Spacer(minLength: ZOSpace.xl)
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.horizontal, ZOSpace.screenMargin)
                    .padding(.top, ZOSpace.m)
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom, spacing: 0) { startDock }
                .onAppear {
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_WORKOUT_STATE"] == "alternatives" {
                        DispatchQueue.main.async {
                            reader.scrollTo("exercise-sequence", anchor: .center)
                        }
                    }
                    #endif
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            // Extend only the background into the top safe area, so scrolled
            // equipment and exercise labels cannot show through the status bar.
            GeometryReader { geometry in
                theme.backgroundPrimary
                    .frame(height: geometry.safeAreaInsets.top)
                    .offset(y: -geometry.safeAreaInsets.top)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .sheet(item: $selectedExercisePlan) { plan in
            Group {
                NavigationStack {
                    ProgrammeExerciseDetailView(plan: plan, onStart: {
                        selectedExercisePlan = nil
                        onStart(selectedWarmUpLength)
                    })
                }
                .zeroOneTheme(theme)
                .preferredColorScheme(theme.colorScheme)
            }
            .zoSheet(theme)
        }
        .sheet(isPresented: $showsVolumeReview) {
            Group {
                if let onPrepareVolumePlan, let onApplyVolumePlan {
                    ProgrammeVolumeReviewView(initialChange: volumeChangeIsActive ? .restore : .ease,
                        onPrepare: onPrepareVolumePlan, onApply: onApplyVolumePlan).zeroOneTheme(theme)
                }
            }
            .zoSheet(theme)
        }
        .sheet(isPresented: $showsWeeklyReview) {
            Group {
                if let activeSchedule, let onPrepareWeeklyPlan, let onApplyWeeklyPlan {
                    WeeklyTrainingReviewView(schedule: activeSchedule, onPrepare: onPrepareWeeklyPlan, onApply: onApplyWeeklyPlan)
                        .zeroOneTheme(theme)
                }
            }
            .zoSheet(theme)
        }
        .sheet(item: $customizationCopy) { copy in
            Group {
                CustomWorkoutBuilderView(workout: copy,
                isNew: !customWorkouts.workouts.contains(where: { $0.id == copy.id }),
                repository: customWorkouts, onStart: onStartCustom)
                .zeroOneTheme(theme)
                .preferredColorScheme(theme.colorScheme)
            }
            .zoSheet(theme)
        }
        .alert("Could not open the editable copy", isPresented: $showsCustomizationError) {
            Button("OK", role: .cancel) { }
        } message: { Text(localization.string(customizationErrorMessage)) }
        .confirmationDialog("An unfinished workout is saved", isPresented: $showsCustomizationDraftConflict) {
            Button("Resume unfinished workout") {
                customizationCopy = customWorkouts.draft?.workout
                pendingCustomizationCopy = nil
            }
            Button("Discard draft and open copy", role: .destructive) {
                if customWorkouts.discardDraft() {
                    customizationCopy = pendingCustomizationCopy
                    pendingCustomizationCopy = nil
                } else {
                    customizationErrorMessage = "The unfinished workout could not be discarded. Your copy has not replaced it."
                    showsCustomizationError = true
                }
            }
            Button("Keep draft", role: .cancel) { pendingCustomizationCopy = nil }
        } message: { Text("Only one unfinished workout can be kept on this iPhone.") }
        .sheet(isPresented: $showsSchedule) {
            Group {
                ProgrammeScheduleSheet(
                    programme: programme,
                    currentSchedule: activeSchedule,
                    scheduleIsAvailable: scheduleIsAvailable,
                    onConfirm: onConfirmSchedule
                )
                .zeroOneTheme(theme)
                .preferredColorScheme(theme.colorScheme)
            }
            .zoSheet(theme)
        }
    }

    private func customizeSession() {
        guard volumeIsAvailable else {
            customizationErrorMessage = ProgrammeVolumeError.unavailable.messageKey
            showsCustomizationError = true
            return
        }
        guard customWorkouts.isAvailable, customWorkouts.isDraftAvailable else {
            customizationErrorMessage = "Saved workouts or the unfinished draft could not be read. Resolve the saved-data issue before creating a copy."
            showsCustomizationError = true
            return
        }
        do {
            try onValidateVolume?()
            let copy = try ProgrammeSessionCustomization.makeCopy(programme: programme,
                previewSession: previewSession, warmUpLength: selectedWarmUpLength)
            if customWorkouts.draft != nil {
                pendingCustomizationCopy = copy
                showsCustomizationDraftConflict = true
            } else { customizationCopy = copy }
        } catch let error as ProgrammeVolumeError {
            customizationErrorMessage = error.messageKey
            showsCustomizationError = true
        } catch let error as ProgrammeSessionCustomizationError {
            customizationErrorMessage = error.message
            showsCustomizationError = true
        } catch {
            customizationErrorMessage = "The complete session could not be copied. Reopen the programme and try again."
            showsCustomizationError = true
        }
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text("YOUR WEEK")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            if let current = scheduleState.currentSchedule, current.programmeID == programme.id {
                Text(localization.format("Training days: %1$@", .text(current.weekdaysInCalendarOrder(.current).map {
                    localizedCalendar.shortStandaloneWeekdaySymbols[$0 - 1]
                }.joined(separator: " · "))))
                    .zoText(.section)
            } else if scheduleIsAvailable {
                Text("Choose days that fit your life. You can still start a workout on another day.")
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
            }
            Button(localization.string(scheduleState.isCurrentPlan(programme.id) ? "Change training days" : "Plan training days")) {
                showsSchedule = true
            }
            .buttonStyle(ZOButtonStyle(.secondary))
            .disabled(!scheduleIsAvailable)
            if scheduleIsAvailable, activeSchedule?.programmeID == programme.id,
               onPrepareWeeklyPlan != nil, onApplyWeeklyPlan != nil,
               let assessment = wellbeingAssessment, assessment.isCurrent(at: .now),
               assessment.hasCurrentRecoveryReport,
               !assessment.recommendations.contains(where: { $0.demand == .pauseForSymptoms }),
               assessment.recommendations.contains(where: {
                   $0.demand == .easeTraining && ($0.kind == .recovery || $0.kind == .fuelling)
               }) {
                Button("Review your training week") { showsWeeklyReview = true }
                    .buttonStyle(ZOButtonStyle(.secondary))
            }
            if onPrepareVolumePlan != nil, onApplyVolumePlan != nil {
                if volumeChangeIsActive { Text("Reduced programme sets are active").zoText(.caption) }
                Button("Review future programme sets") { showsVolumeReview = true }
                    .buttonStyle(ZOButtonStyle(.secondary))
                if !volumeIsAvailable {
                    Text("The saved programme adjustment needs review before a new session can start.")
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                }
            }
            if !scheduleIsAvailable {
                Text("Your saved schedule could not be read, so 01 will not replace it.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zeroOneFeatureSurface()
    }

    private var previewPlans: [ExercisePlan] {
        previewSession.exercises.map(\.plan)
    }

    private var sessionPreview: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text(localization.format("Level: %1$@", .text(workoutCopy.difficulty(programme.experienceBand))))
                .zoText(.section)
            Text("Loads and results remain adjustable during the workout. Customize a copy before starting to change sets, rep or time ranges and rest.")
                .zoText(.caption).foregroundStyle(theme.textSecondary)
            Text("NEXT SESSION")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            Text(previewSession.title)
                .zoThemeText(.title)
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(localization.format("%1$@ · working sets: %2$lld · about %3$@", .text(workoutCopy.quantity(previewPlans.count, .exercises)), .integer(previewSession.totalPlannedSetCount), .text(workoutCopy.quantity(programme.durationMinutes, .minutes))))
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
            if let warmUp = previewSession.warmUp {
                ZOSegmentedControl("Warm-up length", selection: $selectedWarmUpLength, options: [ZOSegment(value: WorkoutWarmUpLength.full, label: Text("Full")), ZOSegment(value: WorkoutWarmUpLength.short, label: Text("Short")), ZOSegment(value: WorkoutWarmUpLength.none, label: Text("None"))])
                .accessibilityIdentifier("workout.warmUpLength")

                DisclosureGroup("About warm-up and starting loads") {
                    Text(warmUpDescription(for: warmUp))
                    Text("Adjust the suggested load to what you actually use during the workout.")
                }
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zeroOneFeatureSurface()
    }

    /// Planned days come only from a schedule that could be read; an
    /// unreadable one is never shown as current.
    private var scheduleState: WorkoutScheduleAvailability {
        WorkoutScheduleAvailability(schedule: activeSchedule, isAvailable: scheduleIsAvailable)
    }

    private var cover: ProgrammeCoverPresentation {
        ProgrammeCoverPresentation(programme: programme, schedule: scheduleState)
    }

    /// Proof 9's `.zo-dock`: the existing Start, fixed above the tab bar on
    /// the canvas, 12 pt above and the screen margin at the sides. Its gate,
    /// warm-up choice and transition are unchanged.
    private var startDock: some View {
        Button {
            withAnimation(WorkoutMusicJoinTransition.animation(spatialMotion: allowsMusicJoinMotion)) {
                onStart(selectedWarmUpLength)
            }
        } label: {
            HStack {
                Text(startButtonTitle)
                Spacer()
                Image(systemName: "arrow.right")
            }
        }
        .buttonStyle(ZOButtonStyle(.primary))
        .disabled(!volumeIsAvailable)
        .accessibilityLabel(localization.format("%1$@ for %2$@", .text(startButtonTitle), .text(previewSession.title)))
        .accessibilityHint("Opens this session with your chosen warm-up length.")
        .frame(maxWidth: 620)
        .padding(.horizontal, ZOSpace.screenMargin)
        .padding(.top, ZOSpace.m)
        .padding(.bottom, ZOSpace.m)
        .frame(maxWidth: .infinity)
        .background(theme.backgroundPrimary)
        .accessibilityIdentifier("workout.programmeStartDock")
    }

    private var allowsMusicJoinMotion: Bool {
        !reduceMotion && !voiceOverEnabled && !dynamicTypeSize.isAccessibilitySize
    }

    private var readyMusicContext: WorkoutMusicContext {
        var session = previewSession
        session.selectWarmUpLength(selectedWarmUpLength, at: .now)
        return WorkoutMusicContext(session: session, stage: .ready)
    }

    private var startButtonTitle: String {
        switch selectedWarmUpLength {
        case .full: return localization.string("Start warm-up")
        case .short: return localization.string("Start short warm-up")
        case .none: return localization.string("Start set 1")
        }
    }

    private func warmUpDescription(for warmUp: WorkoutWarmUp) -> String {
        switch selectedWarmUpLength {
        case .full:
            return localization.format("About %1$@ of easy movement and lighter practice before working sets.", .text(workoutCopy.quantity(warmUp.estimatedMinutes, .minutes)))
        case .short:
            return localization.format("About %1$@ of lighter practice before working sets.", .text(workoutCopy.quantity(max(2, warmUp.estimatedMinutes - 2), .minutes)))
        case .none:
            return localization.string("Go straight to set 1. A warm-up is encouraged, especially before heavier work.")
        }
    }

    /// Proof 9's top bar: a round back button. The programme's name is on
    /// the cover below.
    private var detailHeader: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .zoIcon(ZOIcon.row)
            }
            .buttonStyle(ZOButtonStyle(.round))
            .accessibilityLabel("Back to Workout Library")

            Spacer()
        }
    }

    /// The cover's chips: level, then days a week only from the person's
    /// confirmed schedule for this programme (otherwise the rotation, named as
    /// a rotation), authored minutes and the main equipment. A rotation is
    /// never presented as a weekly frequency.
    private func coverChips(_ cover: ProgrammeCoverPresentation) -> [String] {
        [workoutCopy.difficulty(programme.experienceBand),
         cover.scheduledDaysPerWeek.map {
             localization.format("%1$@ a week", .text(workoutCopy.quantity($0, .days)))
         } ?? localization.format("%1$@ in rotation", .text(workoutCopy.quantity(cover.rotationLength, .sessions))),
         workoutCopy.quantity(cover.minutes, .minutes),
         compactEquipment].filter { !$0.isEmpty }
    }

    /// Proof 9's week grid: one column per authored week. Bars per week come
    /// only from the person's confirmed days for this programme; without them
    /// each week is a single bar, so no weekly count or total is implied. No
    /// bar is filled: programme progress is not a fact this screen has, and no
    /// finish date is computed.
    private func programmeWeekCard(_ cover: ProgrammeCoverPresentation) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                    Text(workoutCopy.quantity(cover.weeks, .weeks))
                        .zoText(.section)
                        .foregroundStyle(theme.textPrimary)
                    Spacer(minLength: ZOSpace.s)
                    Text(localization.format("About %1$@ each", .text(workoutCopy.quantity(cover.minutes, .minutes))))
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.trailing)
                }
                Text(weekCardDetail(cover))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            if cover.gridWeeks > 0, cover.gridBarsPerWeek > 0 {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(1 ... cover.gridWeeks, id: \.self) { week in
                        VStack(spacing: 6) {
                            VStack(spacing: 3) {
                                ForEach(0 ..< cover.gridBarsPerWeek, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(theme.surfaceTertiary)
                                        .frame(height: 6)
                                }
                            }
                            Text(localization.format("W%1$lld", .integer(week)))
                                .zoText(.caption)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                // Decorative: the heading and detail above state the facts.
                .accessibilityHidden(true)
            }
        }
        .padding(ZOSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
        .accessibilityIdentifier("workout.programmeWeeks")
    }

    /// "3 sessions in rotation", plus the person's own days when confirmed.
    private func weekCardDetail(_ cover: ProgrammeCoverPresentation) -> String {
        let rotation = localization.format("%1$@ in rotation", .text(workoutCopy.quantity(cover.rotationLength, .sessions)))
        if cover.scheduleIsUnavailable {
            return rotation + " · " + localization.string("Training days couldn't be read")
        }
        guard let days = cover.scheduledDaysPerWeek else { return rotation }
        return rotation + " · " + localization.format("Your plan: %1$@ a week", .text(workoutCopy.quantity(days, .days)))
    }

    /// The programme's own description, where the proof places its note. The
    /// proof's founder note and photo are sample content, not authored data.
    private var programmeNote: some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text("About this programme")
                .zoText(.section)
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: programme.summary)
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ZOSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
    }

    private var exerciseSequence: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NEXT SESSION EXERCISES")
                .zoText(.caption)

                .foregroundStyle(theme.textSecondary)
                .padding(.bottom, ZOSpace.m)

            ForEach(Array(previewPlans.enumerated()), id: \.element.id) { index, plan in
                Button {
                    selectedExercisePlan = plan
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: ZOSpace.m) {
                    Text((index + 1).formatted(.number.precision(.integerLength(2))))
                        .zoText(.caption)
                        .foregroundStyle(theme.textTertiary)
                        .monospacedDigit()

                    VStack(alignment: .leading, spacing: ZOSpace.xs) {
                        Text(plan.name)
                            .zoText(.section)
                            .foregroundStyle(theme.textPrimary)

                        Text(prescriptionText(for: plan))
                        .zoText(.label)
                        .foregroundStyle(theme.textSecondary)

                        if let definition = ExerciseLibrary.exercise(id: plan.exerciseID) {
                            Text(localization.format("Level: %1$@", .text(workoutCopy.difficulty(definition.difficulty.rawValue))))
                                .zoText(.caption).foregroundStyle(theme.textSecondary)
                        }
                        if let alternativeName = preferredAlternativeName(for: plan) {
                            Text(localization.format("OPTION %1$@", .text(alternativeName)))
                                .zoText(.caption)

                                .foregroundStyle(theme.textTertiary)
                        }
                    }

                    Spacer(minLength: ZOSpace.s)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, ZOSpace.m)
                .accessibilityHint("Opens exercise details and guidance.")

                if index < previewPlans.count - 1 {
                    Rectangle()
                        .fill(theme.strokeSubtle)
                        .frame(height: 1)
                }
            }
        }
    }

    private func preferredAlternativeName(for plan: ExercisePlan) -> String? {
        if let alternativeID = plan.alternativeExerciseIDs.first {
            return ExerciseLibrary.exercise(id: alternativeID)?.name
        }
        return plan.unresolvedAlternativeNames.first
    }

    private func prescriptionText(for plan: ExercisePlan) -> String {
        let work = localization.format("%1$@ · %2$@", .text(workoutCopy.quantity(plan.plannedSetCount, .sets)), .text(workoutCopy.prescription(plan.prescription)))
        guard plan.targetLoad.value > 0 else { return work }
        return localization.format("%1$@ · suggested %2$@", .text(work), .text(workoutCopy.load(plan.targetLoad)))
    }

    private var compactEquipment: String {
        let items = programme.equipmentContext.components(separatedBy: ", ")
        return items.prefix(2).joined(separator: ", ")
            + (items.count > 2 ? " + more" : "")
    }
}

private struct ProgrammeScheduleSheet: View {
    let programme: WorkoutProgramme
    let currentSchedule: WorkoutProgrammeSchedule?
    let scheduleIsAvailable: Bool
    let onConfirm: (Set<Int>, WorkoutProgrammeSchedule?) throws -> Void

    @State private var selectedWeekdays: Set<Int> = []
    @State private var reviewedSchedule: WorkoutProgrammeSchedule?
    @State private var showsSaveError = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = localization.locale
        return calendar
    }
    private var orderedWeekdays: [Int] {
        (0 ..< 7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }
    private var minimumDays: Int { min(2, programme.sessions.count) }
    private var canConfirm: Bool {
        scheduleIsAvailable && selectedWeekdays.count >= minimumDays
            && selectedWeekdays.count <= programme.sessions.count
    }

    /// Proof 41's "Your week": the days as a big week strip (chosen days are
    /// ink discs), the count against the rotation, what saving does, and
    /// Save my week in the dock. The weekday authority, minimum, stale-save
    /// review and defaults are the existing ones. No usual time, reminder or
    /// Calendar copy is offered: the programme schedule does not store them.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("When do you train?")
                        .zoThemeHeading(.display, context: .directScrollDisplay)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(localization.format("Choose at least %1$@ for training that usually fit. You can move a session when life changes.", .text(workoutCopy.quantity(minimumDays, .days))))
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)

                    HStack(alignment: .top, spacing: ZOSpace.xs) {
                        ForEach(orderedWeekdays, id: \.self) { weekday in
                            let isOn = selectedWeekdays.contains(weekday)
                            Button {
                                if !selectedWeekdays.insert(weekday).inserted {
                                    selectedWeekdays.remove(weekday)
                                }
                            } label: {
                                // Proof `.zo-week7.big`: 42 pt discs with the day's
                                // initial at 17 semibold; the full name is spoken.
                                Text(calendar.veryShortStandaloneWeekdaySymbols[weekday - 1])
                                    .zoText(.section)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .foregroundStyle(isOn ? theme.backgroundPrimary : theme.textSecondary)
                                    .frame(width: 42, height: 42)
                                    .background(isOn ? theme.textPrimary : theme.surfaceSecondary, in: Circle())
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(calendar.weekdaySymbols[weekday - 1])
                            .accessibilityValue(localization.string(isOn ? "Training day" : "Rest day"))
                            .accessibilityAddTraits(isOn ? .isSelected : [])
                        }
                    }
                    .padding(.top, 20)

                    Text(localization.format("%1$lld of %2$lld session days selected", .integer(selectedWeekdays.count), .integer(programme.sessions.count)))
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.top, 10)
                    if selectedWeekdays.count < minimumDays {
                        Text(localization.format("Choose at least %1$@ to save this plan.", .text(workoutCopy.quantity(minimumDays, .days))))
                            .zoText(.caption)
                            .foregroundStyle(theme.textSecondary)
                            .padding(.top, ZOSpace.xs)
                    } else if selectedWeekdays.count < programme.sessions.count {
                        Text("The session rotation stays in order. With fewer days per week, the plan takes longer.")
                            .zoText(.caption)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, ZOSpace.xs)
                    }
                    Text(localization.format("Saving makes %1$@ your current weekly plan. It does not start a workout or create a history entry.", .text(programme.title)))
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, ZOSpace.m)
                }
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.top, 6)
                .padding(.bottom, ZOSpace.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.backgroundPrimary.ignoresSafeArea())
            .foregroundStyle(theme.textPrimary)
            .navigationTitle("Training days")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark").zoIcon(ZOIcon.row) }
                        .buttonStyle(ZOButtonStyle(.round))
                        .accessibilityLabel("Cancel")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button("Save my week") {
                    do {
                        try onConfirm(selectedWeekdays, reviewedSchedule)
                        dismiss()
                    } catch {
                        showsSaveError = true
                    }
                }
                .buttonStyle(ZOButtonStyle(.primary))
                .disabled(!canConfirm)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.vertical, ZOSpace.m)
                .background(theme.backgroundPrimary)
            }
            .alert("Schedule change not confirmed", isPresented: $showsSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The saved schedule may have changed, or storage could not confirm this change. Close and reopen the schedule before trying again.")
            }
            .onAppear {
                reviewedSchedule = currentSchedule
                if currentSchedule?.programmeID == programme.id {
                    selectedWeekdays = Set(currentSchedule?.weekdays ?? [])
                } else {
                    switch programme.sessions.count {
                    case 1: selectedWeekdays = [4]
                    case 2: selectedWeekdays = [2, 5]
                    case 3: selectedWeekdays = [2, 4, 6]
                    default: selectedWeekdays = [2, 3, 5, 6]
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Proof 39's exercise page for a planned exercise: the guide (licensed loop,
/// name, muscles as words, today's prescription and the cue), or the
/// existing artwork when no MoveKit match exists. The existing Start sits in
/// the proof's bottom dock. History is not passed here, so no saved sets are
/// shown on this route.
private struct ProgrammeExerciseDetailView: View {
    let plan: ExercisePlan
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    private var artwork: ExerciseArtwork {
        ExerciseArtwork(exerciseID: plan.exerciseID, exerciseName: plan.name, level: .hero)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let match = MoveKitExerciseCatalog.match(for: plan.exerciseID) {
                    MoveKitExerciseGuide(match: match, plan: plan)
                } else {
                    ZeroOneActiveExerciseStage(artwork: artwork, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: .continuous))
                    Text(plan.name)
                        .zoThemeHeading(.display, context: .directScrollDisplay)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 14)
                    HStack(alignment: .top, spacing: ZOSpace.s) {
                        detailMetric("Sets", plan.plannedSetCount.formatted())
                        detailMetric(plan.isTimed ? "Duration" : "Reps", workoutCopy.prescription(plan.prescription))
                        detailMetric("Rest", workoutCopy.quantity(Int(plan.restSeconds), .seconds))
                    }
                    .padding(ZOSpace.cardPadding)
                    .zoThemeCardSurface()
                    .padding(.top, ZOSpace.l)
                    if let cue = plan.coachingCue, !cue.isEmpty {
                        ExerciseDetailSubhead(title: "How to do it")
                        ExerciseCueList(cues: [cue])
                    }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, ZOSpace.xs)
            .padding(.bottom, ZOSpace.xl)
        }
        .scrollIndicators(.hidden)
        .background(theme.backgroundPrimary.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Start workout", action: onStart)
                .buttonStyle(ZOButtonStyle(.primary))
                .accessibilityHint("Starts the first exercise in this programme.")
                .frame(maxWidth: 620)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.vertical, ZOSpace.m)
                .frame(maxWidth: .infinity)
                .background(theme.backgroundPrimary)
        }
        .navigationTitle("Exercise detail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func detailMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localization.string(title)).zoText(.caption).foregroundStyle(theme.textSecondary)
            Text(value)
                .zoText(.section)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Proof 9's cover, a record sleeve: a 4:5 onyx band, a huge condensed
/// weeks numeral in the accent, the title and authored chips at the foot.
/// The proof's full-bleed photo has no approved app asset, so the surface
/// stays honestly neutral; the layout and type are the proof's. Sizes follow
/// the cover's width (the proof's `cqw` units). The facts are read once as a
/// single element.
private struct ProgrammeCoverView: View {
    let programme: WorkoutProgramme
    let cover: ProgrammeCoverPresentation
    let chips: [String]

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    /// Brand onyx and ink: the sleeve keeps its colours in every appearance,
    /// like the proof's `--zo-brand-onyx` and `--zo-brand-ink`.
    private let onyx = Color(zoHex: 0x020202)
    private let ink = Color(zoHex: 0xF7F6F1)

    var body: some View {
        Color.clear
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { proxy in
                    let unit = proxy.size.width / 100
                    ZStack(alignment: .topLeading) {
                        onyx
                        VStack(alignment: .leading, spacing: 1.5 * unit) {
                            Text(cover.weeks.formatted())
                                .font(Self.face(.timerHero, size: 24 * unit))
                                .foregroundStyle(ZOColor.Swatch.yellow.fill)
                                .lineLimit(1)
                                .minimumScaleFactor(0.4)
                            Text(localization.string(cover.weeks == 1 ? "week" : "weeks"))
                                .font(Self.face(.display, size: 5 * unit))
                                .foregroundStyle(ink)
                        }
                        .padding(.leading, 6 * unit)
                        .padding(.top, 5 * unit)

                        VStack(alignment: .leading, spacing: 3 * unit) {
                            Text(verbatim: programme.title)
                                .font(Self.face(.display, size: 9 * unit))
                                .tracking(-0.2 * unit)
                                .foregroundStyle(ink)
                                .lineLimit(3)
                                .minimumScaleFactor(0.6)
                                .fixedSize(horizontal: false, vertical: true)
                            ProgrammeCoverChipLayout(spacing: 2 * unit) {
                                ForEach(chips, id: \.self) { chip in
                                    Text(verbatim: chip)
                                        .font(Self.face(.section, size: 3.6 * unit))
                                        .foregroundStyle(ink)
                                        .lineLimit(1)
                                        .padding(.horizontal, 3 * unit)
                                        .frame(height: 7.5 * unit)
                                        .background(ink.opacity(0.14), in: Capsule())
                                }
                            }
                        }
                        .padding(6 * unit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: ZORadius.sheet, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(([programme.title, workoutCopy.quantity(cover.weeks, .weeks)] + chips)
                .joined(separator: ", "))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("workout.programmeCover")
    }

    /// The app's own variable face with a generated style's weight and width,
    /// at a size relative to the cover (the proof's `cqw`). The numeral uses
    /// the timer hero's 700 at 75% width, as `.zo-cover .big` does.
    private static func face(_ style: ZOTextStyle, size: CGFloat) -> Font {
        Font(CTFontCreateCopyWithAttributes(style.ctFont(for: .large), max(1, size), nil, nil))
    }
}

/// Wraps the cover's chips onto as many lines as they need.
private struct ProgrammeCoverChipLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = makeRows(for: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in makeRows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func makeRows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Proof 39's `.zo-chart`: the heaviest set of each session as one 2.5 pt
/// ink line; the best is a filled 6 pt dot, the others 3.5 pt rings; the
/// best and the latest carry their load; the first and last dates sit
/// beneath. Static, so Reduce Motion needs nothing.
private struct ExerciseTopSetChart: View {
    let points: [ExerciseHistoryPresentation.Point]
    /// The best set's session, so the filled dot matches the card above.
    let bestSessionID: UUID
    let load: (Load) -> String
    let locale: Locale

    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        let values = points.map(\.load.value)
        let best = points.firstIndex { $0.sessionID == bestSessionID } ?? -1
        let last = values.count - 1
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let inset: CGFloat = 14
                let top: CGFloat = 20
                let lower = values.min() ?? 0
                let upper = values.max() ?? 0
                let span = max(upper - lower, 1)
                let step = values.count > 1 ? (proxy.size.width - 2 * inset) / CGFloat(values.count - 1) : 0
                let position: (Int) -> CGPoint = { index in
                    CGPoint(x: inset + CGFloat(index) * step,
                            y: top + (proxy.size.height - top - 8) * CGFloat(1 - (values[index] - lower) / span))
                }
                ZStack {
                    Path { path in
                        for index in values.indices {
                            if index == 0 { path.move(to: position(index)) } else { path.addLine(to: position(index)) }
                        }
                    }
                    .stroke(theme.textPrimary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    ForEach(values.indices, id: \.self) { index in
                        Circle()
                            .fill(index == best ? theme.textPrimary : theme.surfacePrimary)
                            .overlay { Circle().stroke(theme.textPrimary, lineWidth: 2) }
                            .frame(width: index == best ? 12 : 7, height: index == best ? 12 : 7)
                            .position(position(index))
                        if index == best || index == last {
                            Text(verbatim: load(points[index].load))
                                .zoText(.mini)
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize()
                                .position(x: position(index).x, y: position(index).y - 14)
                        }
                    }
                }
            }
            HStack {
                Text(points.first?.completedAt.formatted(.dateTime.day().month(.abbreviated).locale(locale)) ?? "")
                Spacer(minLength: 0)
                Text(points.last?.completedAt.formatted(.dateTime.day().month(.abbreviated).locale(locale)) ?? "")
            }
            .zoText(.mini)
            .foregroundStyle(theme.textSecondary)
        }
    }
}

/// A MoveKit poster frame filling its frame, framed slightly above centre as
/// the proof's `.zo-media.pose` (object-position 50% 42%). Decoded at the
/// drawn size through the shared poster store. A missing poster stays an
/// honest no-video surface.
private struct WorkoutLibraryPoster: View {
    let exercise: MoveKitExercise?

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var poster: UIImage?
    @State private var didFinishLoading = false

    var body: some View {
        GeometryReader { proxy in
            let maxPixel = max(1, Int((max(proxy.size.width, proxy.size.height * 1936.0 / 1072.0)
                                       * displayScale).rounded(.up)))
            ZStack {
                theme.surfaceSecondary
                if let poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .offset(y: focusOffset(for: poster.size, in: proxy.size))
                } else if exercise == nil || didFinishLoading {
                    Image(systemName: "video.slash")
                        .zoIcon(ZOIcon.row)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .task(id: "\(exercise?.posterResource ?? "-"):\(maxPixel)") {
                poster = nil
                didFinishLoading = false
                guard let exercise else { return }
                let image = await CustomWorkoutPosterStore.shared.image(for: exercise.posterResource, maxPixel: maxPixel)
                guard !Task.isCancelled else { return }
                poster = image ?? UIImage(named: exercise.posterResource)
                didFinishLoading = true
            }
        }
        .accessibilityHidden(true)
    }

    /// object-position 42%: move the filled image down by 8% of its excess.
    private func focusOffset(for imageSize: CGSize, in frame: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 0 }
        let scale = max(frame.width / imageSize.width, frame.height / imageSize.height)
        let excess = imageSize.height * scale - frame.height
        return excess > 0 ? excess * 0.08 : 0
    }
}

private extension WorkoutProgramme {
    /// The first planned exercise with a real MoveKit poster, for the plan's
    /// picture. Nil when none has one: the thumbnail then stays an honest
    /// no-media surface.
    var posterMatch: MoveKitExerciseMatch? {
        exercisePlans.lazy.compactMap { MoveKitExerciseCatalog.programmePoster(for: $0.exerciseID) }.first
    }
}

/// Proof 38's small row button (`smallBtn`): `.zo-btn` at 40 pt tall, 16 pt
/// in, its own width. Primary is 17/22 semibold on the accent with its edge,
/// pressed on the accent's pressed fill. Secondary is 15/20 medium on
/// surface 1 inside a 1 pt strong separator, pressed on surface 2. Disabled
/// follows `.zo-btn[disabled]`. The press scale is dropped with Reduce
/// Motion. The shared `ZOButtonStyle` has no 40 pt size, so this stays local.
/// The hit area stays 44 pt.
private struct WorkoutLibraryCompactButtonStyle: ButtonStyle {
    let isPrimary: Bool

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        // Proof38 smallBtn overrides only width, height40 and horizontal16.
        // Shared ZOButtonStyle has no compact sizing API; retain those overrides.
        let radius = ZOThemeComponentShape(theme: theme.designTheme, role: .button,
            radius: ZORadius.button).resolvedRadius
        let shape = RoundedRectangle(cornerRadius: radius,
            style: theme.designTheme == .freak ? .circular : .continuous)
        let pressed = configuration.isPressed && isEnabled
        let button = Group {
            if isPrimary {
                configuration.label.zoThemeText(.primaryButton)
            } else {
                configuration.label.zoText(.label).fontWeight(.medium)
            }
        }
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        .animation(ZOControlFidelity.buttonForegroundAnimation(isPrimary ? .primary : .secondary, reduceMotion: reduceMotion)) {
            $0.foregroundStyle(!isEnabled && !(isPrimary && theme.designTheme == .freak)
                ? (contrast == .increased ? theme.textSecondary : theme.textTertiary)
                : (isPrimary ? theme.onAccent : theme.textPrimary))
        }
        .padding(.horizontal, ZOSpace.l)
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 64 : 40)
        .animation(ZOControlFidelity.buttonBackgroundAnimation(isPrimary ? .primary : .secondary, reduceMotion: reduceMotion)) {
            $0.background(background(pressed: pressed), in: shape)
        }
        .overlay { shape.strokeBorder(edge, lineWidth: ZOStroke.hairline) }
        .background {
            if isPrimary {
                Group {
                    switch theme.designTheme {
                    case .retro:
                        if theme.colorScheme == .dark {
                            ZStack {
                                shape.fill(Color(zoHex: 0xFF4D6D, alpha: 0.30)).blur(radius: 44)
                                shape.fill(Color(zoHex: 0xFF8A3D, alpha: 0.55)).blur(radius: 18)
                                shape.stroke(Color(zoHex: 0xFFE9A8, alpha: 0.60), lineWidth: 2)
                            }
                        } else {
                            shape.fill(theme.textPrimary).offset(x: 3, y: 3)
                        }
                    case .princess:
                        shape.fill(theme.accentFill.opacity(0.45)).blur(radius: 22).offset(y: 8)
                    case .core, .freak: EmptyView()
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        Group {
            if isPrimary && theme.designTheme == .freak {
                button.overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.45)).frame(height: ZOStroke.hairline)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .clipShape(ZOThemeComponentShape(theme: .freak, role: .button, radius: radius))
            } else {
                button
            }
        }
        .animation(reduceMotion ? nil : ZOMotion.brace(ZOMotion.micro)) {
            $0.scaleEffect(pressed && !reduceMotion ? ZOMotion.pressScale : 1)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
    }

    private func background(pressed: Bool) -> AnyShapeStyle {
        if isPrimary {
            if !isEnabled && theme.designTheme != .retro && theme.designTheme != .freak {
                return AnyShapeStyle(theme.surfaceTertiary)
            }
            if pressed && ZOControlFidelity.primaryPressedFillIsSolid(theme: theme.designTheme, scheme: theme.colorScheme) {
                return AnyShapeStyle(theme.accentPressed)
            }
            return theme.primaryActionBackground(pressed: pressed)
        }
        return AnyShapeStyle(pressed ? theme.surfaceSecondary : theme.surfacePrimary)
    }

    private var edge: Color {
        if isPrimary {
            switch theme.designTheme {
            case .core: return isEnabled ? theme.accentEdge : .clear
            case .princess: return theme.accentEdge
            case .retro, .freak: return .clear
            }
        }
        return theme.separatorStrong
    }
}

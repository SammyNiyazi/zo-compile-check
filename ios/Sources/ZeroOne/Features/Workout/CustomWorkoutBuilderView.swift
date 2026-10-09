import SwiftUI
import UIKit
import ImageIO
import CoreText

struct CustomWorkoutBuilderView: View {
    let repository: CustomWorkoutRepository
    let onStart: (CustomWorkout, WorkoutWarmUpLength) -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: CustomWorkout
    @State private var confirmed: CustomWorkout?
    @State private var isEditing = true
    @State private var isSaving = false
    @State private var nameError: String?
    @State private var exerciseError: String?
    @State private var loadErrors: Set<UUID> = []
    @State private var showsLeaveConfirmation = false
    @State private var removal: CustomWorkoutRemoval?
    @State private var removalExpiry: Task<Void, Never>?
    @State private var draftNotice: CustomWorkoutDraftNotice?
    @State private var draftNoticeExpiry: Task<Void, Never>?
    @State private var editingSelection: CustomWorkoutItemSelection?
    @State private var replaceAfterSheet: UUID?
    @State private var removeAfterSheet: UUID?
    @State private var reopenAfterPicker: UUID?
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var savedVersion = 0
    @State private var showsExercisePicker = false
    @State private var replacingItemID: UUID?
    @State private var showsDeleteConfirmation = false
    @State private var showsError = false
    @State private var errorMessage = ""
    @State private var selectedWarmUpLength: WorkoutWarmUpLength = .full
    @State private var rowHeights: [UUID: CGFloat] = [:]
    @State private var liftedID: UUID?
    @State private var dragSession: CustomWorkoutDragSession?
    @State private var cancelledDragID: UUID?
    @State private var dragScrollDistance: CGFloat = 0
    @State private var dragScrollDriver = CustomWorkoutDragScrollDriver()
    /// Resets on cancel, interruption or dismissal without touching draft.items; the
    /// lifted copy fades out (opacity only) rather than jumping.
    @GestureState(resetTransaction: Transaction(animation: ZOMotion.crossfade()))
    private var drag: CustomWorkoutRowDrag? = nil
    @FocusState private var nameFocused: Bool

    init(
        workout: CustomWorkout,
        isNew: Bool,
        repository: CustomWorkoutRepository,
        onStart: @escaping (CustomWorkout, WorkoutWarmUpLength) -> Bool
    ) {
        self.repository = repository
        self.onStart = onStart
        // This sheet owns a one-time editable draft; later repository changes do not
        // silently replace a person's unsaved input.
        _draft = State(initialValue: workout)
        _confirmed = State(initialValue: isNew ? nil : workout)
        _selectedWarmUpLength = State(initialValue: workout.warmUpLength ?? .full)
    }

    private typealias Metrics = CustomWorkoutBuilderMetrics

    var body: some View {
        builderDragEvents(builderEvents(builderPresentations(builderLayout)))
    }

    private var builderLayout: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isEditing { nameField } else { savedHeader }
                    summaryBadges
                        .padding(.top, Metrics.summaryTop)
                    sectionHeader(localization.string("Exercises"), caption: reorderCaption)
                    if draft.items.isEmpty {
                        Text(localization.string("Add your first exercise to build a session you can repeat."))
                            .zoText(.body)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, ZOSpace.s)
                    }
                    if let exerciseError { validationMessage(exerciseError).padding(.bottom, ZOSpace.s) }
                    if isEditing { editableRows } else { savedRows }
                    if isEditing {
                        Button {
                            showsExercisePicker = true
                        } label: {
                            Label {
                                Text(localization.string("Add exercises"))
                            } icon: {
                                Image(systemName: "plus").zoIcon(ZOIcon.row)
                            }
                            .labelStyle(ZOIconLabelStyle())
                        }
                        .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                        .accessibilityIdentifier("customWorkout.addExercise")
                        .padding(.top, Metrics.addTop)
                    }
                    sectionHeader(localization.string("Warm-up"))
                    ZOSegmentedControl("Warm-up length", selection: $selectedWarmUpLength, options: [
                        ZOSegment(value: WorkoutWarmUpLength.full, label: Text(localization.string("Full"))),
                        ZOSegment(value: WorkoutWarmUpLength.short, label: Text(localization.string("Short"))),
                        ZOSegment(value: WorkoutWarmUpLength.none, label: Text(localization.string("None")))
                    ])
                    .accessibilityIdentifier("customWorkout.warmUpLength")
                }
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.top, Metrics.contentTop)
                .padding(.bottom, ZOSpace.xxl)
                .background(CustomWorkoutDragScrollAttachment(driver: dragScrollDriver))
            }
            .scrollDismissesKeyboard(.interactively)
            // Disable the competing pan. The scoped driver still moves content
            // programmatically while the finger holds a row near the viewport edge.
            .scrollDisabled(drag != nil)
            .background(theme.backgroundPrimary)
            // Inside the safe area that the dock below adds, so the toast sits above the measured
            // dock and is hit-tested within its own bounds.
            .overlay(alignment: .bottom) {
                toast
                    .padding(.horizontal, ZOSpace.l)
                    .padding(.bottom, ZOSpace.m)
            }
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
            .toolbar(.hidden, for: .navigationBar)
        }
        // A downward drag on a lifted row must not start the sheet's swipe to dismiss.
        .interactiveDismissDisabled(drag != nil)
        .foregroundStyle(theme.textPrimary)
        .tint(theme.textPrimary)
    }

    /// Item editor, exercise picker, alert and confirmations.
    private func builderPresentations(_ content: some View) -> some View {
        content
        .sheet(item: $editingSelection, onDismiss: handleItemSheetDismiss) { selection in
            Group {
                CustomWorkoutItemSheet(
                    item: itemBinding(for: selection),
                    position: (draft.items.firstIndex(where: { $0.id == selection.id }) ?? 0) + 1,
                    loadError: loadErrors.contains(selection.id)
                        ? draft.items.first(where: { $0.id == selection.id }).flatMap(CustomWorkoutBuilderValidation.loadError(for:))
                        : nil,
                    onDone: { editingSelection = nil },
                    onReplace: {
                        replaceAfterSheet = selection.id
                        editingSelection = nil
                    },
                    onRemove: {
                        removeAfterSheet = selection.id
                        editingSelection = nil
                    }
                )
                .zeroOneTheme(theme)
                .preferredColorScheme(theme.colorScheme)
            }
            .zoSheet(theme)
            .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: $showsExercisePicker, onDismiss: handlePickerDismiss) {
            CustomWorkoutExercisePicker(isReplacing: replacingItemID != nil) { exercises in
                let outcome = CustomWorkoutBuilderPresentation.applyingPicked(exercises, replacing: replacingItemID, to: draft.items)
                draft.items = outcome.items
                // As before the redesign: the replaced row, or the first added one, opens for editing.
                reopenAfterPicker = outcome.openItemID
                // replacingItemID is cleared in handlePickerDismiss, after the cover has closed,
                // so the picker keeps its Replace title and single selection while it animates out.
            }
            .zeroOneTheme(theme)
            .preferredColorScheme(theme.colorScheme)
            .presentationBackground(theme.backgroundPrimary)
        }
        .alert(localization.string("Session change not confirmed"), isPresented: $showsError) {
            Button(localization.string("OK"), role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .confirmationDialog(localization.string("Delete this workout?"), isPresented: $showsDeleteConfirmation) {
            Button(localization.string("Delete workout"), role: .destructive) {
                if repository.remove(id: draft.id) {
                    draftSaveTask?.cancel()
                    if repository.draft?.workout.id == draft.id { _ = repository.discardDraft() }
                    dismiss()
                }
                else { showError(localization.string("We could not confirm the removal. Reopen the library before trying again.")) }
            }
        } message: {
            Text(localization.string("Past workout history will remain."))
        }
        .confirmationDialog(localization.string("Leave this workout?"), isPresented: $showsLeaveConfirmation) {
            Button(localization.string("Keep editing")) { }
            Button(localization.string("Leave and keep draft")) {
                draftSaveTask?.cancel()
                if repository.keepDraft(draft) { dismiss() }
                else { showError(localization.string("The draft could not be kept on this iPhone. Stay here and try again.")) }
            }
            Button(localization.string("Discard changes"), role: .destructive) {
                draftSaveTask?.cancel()
                if repository.discardDraft() { dismiss() }
                else { showError(localization.string("The draft could not be discarded. Stay here and try again.")) }
            }
        } message: {
            Text(localization.string("Your saved workout stays unchanged until you save these edits."))
        }
    }

    /// Draft, drag and scene handlers, split from body for the type checker (9 Oct compile check).
    private func builderEvents(_ content: some View) -> some View {
        content
        .onChange(of: draft) { _, changed in handleDraftChange(changed) }
        .onChange(of: selectedWarmUpLength) { _, length in
            if isEditing { draft.warmUpLength = length }
        }
        .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
    }

    /// Drag, selection and disappearance handlers, split again for the type checker.
    private func builderDragEvents(_ content: some View) -> some View {
        content
        .onChange(of: drag?.itemID) { _, id in
            if id == nil {
                cancelDrag()
                cancelledDragID = nil
            }
            withAnimation(reduceMotion ? nil : ZOMotion.land(ZOMotion.quick)) { liftedID = id }
        }
        .onChange(of: draft.items.map(\.id)) { _, _ in cancelDrag() }
        .onChange(of: isEditing) { _, _ in cancelDrag() }
        .onChange(of: showsExercisePicker) { _, shown in if shown { cancelDrag() } }
        .onChange(of: editingSelection) { _, selection in if selection != nil { cancelDrag() } }
        .onDisappear {
            cancelDrag()
            removalExpiry?.cancel()
            draftNoticeExpiry?.cancel()
        }
        .sensoryFeedback(.success, trigger: savedVersion)
        .sensoryFeedback(.selection, trigger: dragPreview?.target) { old, new in
            old != nil && new != nil && old != new
        }
    }

    private func handleDraftChange(_ changed: CustomWorkout) {
        if nameError != nil { nameError = CustomWorkoutBuilderValidation.nameError(for: changed, among: repository.workouts) }
        if exerciseError != nil { exerciseError = CustomWorkoutBuilderValidation.exercisesError(for: changed) }
        loadErrors = Set(loadErrors.filter { id in
            changed.items.first(where: { $0.id == id }).map { CustomWorkoutBuilderValidation.loadError(for: $0) != nil } ?? false
        })
        guard isEditing, changed != confirmed else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if repository.isDraftAvailable && !repository.keepDraft(changed) {
                showDraftNotice(localization.string("Changes could not be kept as a draft. You can still try saving this workout."))
            }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        if phase != .active { cancelDrag() }
        if phase != .active && isEditing && draft != confirmed {
            draftSaveTask?.cancel()
            _ = repository.keepDraft(draft)
        }
    }

    // MARK: Top bar, name and summary

    private var topBar: some View {
        ZStack {
            Text(isEditing ? localization.string(confirmed == nil ? "New workout" : "Edit workout") : localization.string("My workout"))
                .zoText(.section)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Metrics.topBarTitleInset)
            HStack {
                Button(localization.string(isEditing ? "Cancel" : "Done")) { requestClose() }
                    .buttonStyle(ZOButtonStyle(.quiet))
                    .padding(.leading, -ZOSpace.m)
                Spacer(minLength: 0)
                if !isEditing {
                    Button(localization.string("Edit")) { isEditing = true }
                        .buttonStyle(ZOButtonStyle(.quiet))
                        .padding(.trailing, -ZOSpace.m)
                }
            }
        }
        .frame(minHeight: Metrics.topBarMinHeight)
        .padding(.horizontal, ZOSpace.screenMargin)
        .background(theme.backgroundPrimary)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Metrics.fieldMessageTop) {
            HStack(spacing: Metrics.fieldGap) {
                TextField(text: $draft.name, prompt: Text(localization.string("Name your workout")).foregroundStyle(theme.textTertiary)) {
                    Text(localization.string("Workout name"))
                }
                .customWorkoutType(.fieldTitle)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($nameFocused)
                .accessibilityIdentifier("customWorkout.name")
                moreMenu
                    // .zo-field: the 20 pt glyph sits 10 pt after the text and 16 pt from the edge.
                    // The 44 pt hit area overhangs that layout instead of widening the gaps.
                    .padding(.horizontal, -Metrics.moreHitOverhang)
            }
            .padding(.horizontal, ZOSpace.l)
            .frame(minHeight: ZOSpace.rowMinHeight)
            .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .control, radius: ZORadius.control).resolvedRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .control, radius: ZORadius.control).resolvedRadius, style: .continuous)
                    .strokeBorder(fieldEdge, lineWidth: nameFocused && nameError == nil ? ZOStroke.focus : ZOStroke.control)
            }
            if let nameError { validationMessage(nameError) }
        }
    }

    private var fieldEdge: Color {
        if nameError != nil { return theme.destructivePrimary }
        return nameFocused ? theme.textPrimary : theme.separatorStrong
    }

    @ViewBuilder
    private var moreMenu: some View {
        if confirmed != nil {
            Menu {
                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label(localization.string("Delete workout"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .zoIcon(ZOIcon.row)
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(localization.string("More"))
        } else {
            // A workout that was never saved has no record to delete, so More stays visible but inactive.
            Button { } label: {
                Image(systemName: "ellipsis")
                    .zoIcon(ZOIcon.row)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityLabel(localization.string("More"))
            .accessibilityHint(localization.string("Available after you save this workout"))
        }
    }

    private var savedHeader: some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text(verbatim: draft.name)
                .zoThemeText(.title)
                .accessibilityAddTraits(.isHeader)
            Text(localization.string("Saved on this iPhone"))
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var summaryBadges: some View {
        CustomWorkoutSummaryBadges(workout: draft, warmUp: selectedWarmUpLength, localization: localization)
            .equatable()
    }

    private var reorderCaption: String? {
        guard isEditing, draft.items.count > 1 else { return nil }
        return localization.string(drag == nil ? "Hold the grip to reorder" : "Let go to drop it here")
    }

    private func sectionHeader(_ title: String, caption: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
            Text(title)
                .zoText(.section)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let caption {
                Text(caption)
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, Metrics.sectionInset)
        .padding(.top, Metrics.sectionTop)
        .padding(.bottom, ZOSpace.s)
    }

    // MARK: Rows and reordering

    private var dragPreview: CustomWorkoutDragPreview? {
        guard let drag, let session = dragSession, session.itemID == drag.itemID,
              session.originalOrder == draft.items.map(\.id),
              let source = session.originalOrder.firstIndex(of: drag.itemID) else { return nil }
        let ids = session.originalOrder
        let heights = ids.map { rowHeights[$0] ?? Metrics.rowMinHeight }
        let translation = drag.translation + dragScrollDistance
        let target = CustomWorkoutReorder.targetIndex(heights: heights, spacing: ZOSpace.s, source: source, translation: translation)
        return CustomWorkoutDragPreview(
            order: CustomWorkoutReorder.moved(ids, from: source, to: target),
            source: source,
            target: target,
            liftedOrigin: CustomWorkoutReorder.origin(of: source, heights: heights, spacing: ZOSpace.s) + translation
        )
    }

    private var editableRows: some View {
        let preview = dragPreview
        let displayIDs = preview?.order ?? draft.items.map(\.id)
        return VStack(spacing: ZOSpace.s) {
            ForEach(Array(displayIDs.enumerated()), id: \.element) { position, id in
                if let item = draft.items.first(where: { $0.id == id }) {
                    let isDragged = preview != nil && drag?.itemID == id
                    CustomWorkoutBuilderRow(
                        number: position + 1,
                        name: item.displayName,
                        caption: CustomWorkoutBuilderPresentation.rowCaption(item, localization: localization),
                        exercise: item.mediaExercise
                    )
                    // The dragged row keeps its gesture alive in place; the slot shows where it lands.
                    .opacity(isDragged ? 0 : 1)
                    .background { if isDragged { CustomWorkoutRowSlot() } }
                    .background(rowHeightReader(id))
                    .contentShape(RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: .continuous))
                    .onTapGesture { if drag == nil { editingSelection = CustomWorkoutItemSelection(id: id) } }
                    .gesture(reorderGesture(for: id))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(CustomWorkoutBuilderPresentation.rowAccessibilityLabel(item, localization: localization))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { editingSelection = CustomWorkoutItemSelection(id: id) }
                    .accessibilityAction(named: Text(localization.string("Move up"))) { move(id, by: -1) }
                    .accessibilityAction(named: Text(localization.string("Move down"))) { move(id, by: 1) }
                    .accessibilityAction(named: Text(localization.string("Remove"))) { remove(id) }
                }
            }
        }
        .coordinateSpace(.named(Metrics.rowSpace))
        .overlay(alignment: .topLeading) {
            if let preview, let drag, let item = draft.items.first(where: { $0.id == drag.itemID }) {
                CustomWorkoutBuilderRow(
                    number: preview.target + 1,
                    name: item.displayName,
                    caption: CustomWorkoutBuilderPresentation.rowCaption(item, localization: localization),
                    exercise: item.mediaExercise,
                    isLifted: liftedID == drag.itemID
                )
                .offset(y: preview.liftedOrigin)
                // Neighbour slots settle with the spring; the lifted row follows
                // the finger and actual scroll offset without positional lag.
                .animation(nil, value: preview.liftedOrigin)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : ZOMotion.land(ZOMotion.quick), value: displayIDs)
    }

    private var savedRows: some View {
        VStack(spacing: ZOSpace.s) {
            ForEach(Array(draft.items.enumerated()), id: \.element.id) { position, item in
                CustomWorkoutBuilderRow(
                    number: position + 1,
                    name: item.displayName,
                    caption: CustomWorkoutBuilderPresentation.rowCaption(item, localization: localization),
                    exercise: item.mediaExercise,
                    showsGrip: false
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(CustomWorkoutBuilderPresentation.rowAccessibilityLabel(item, localization: localization))
            }
        }
    }

    /// Measured row heights drive the drop target, so tall rows at large text sizes are passed
    /// by their own centre. Main-actor callbacks, written only when a height actually changes.
    private func rowHeightReader(_ id: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { recordRowHeight(proxy.size.height, for: id) }
                .onChange(of: proxy.size.height) { _, height in recordRowHeight(height, for: id) }
        }
    }

    private func recordRowHeight(_ height: CGFloat, for id: UUID) {
        guard height > 0, rowHeights[id] != height else { return }
        rowHeights[id] = height
    }

    private func reorderGesture(for id: UUID) -> some Gesture {
        LongPressGesture()
            // Global/window coordinates stay fixed while the rows scroll underneath the finger.
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($drag) { value, state, _ in
                guard isEditing, case .second(true, let movement) = value else { return }
                state = CustomWorkoutRowDrag(itemID: id, translation: movement?.translation.height ?? 0)
            }
            .onChanged { value in
                guard isEditing, scenePhase == .active, cancelledDragID != id,
                      case .second(true, let movement) = value else { return }
                if dragSession == nil {
                    dragScrollDriver.begin()
                    dragSession = CustomWorkoutDragSession(
                        itemID: id, originalOrder: draft.items.map(\.id),
                        initialContentOffset: dragScrollDriver.contentOffset
                    )
                    dragScrollDistance = 0
                }
                // Ordinary reordering remains available if the attachment is not ready.
                // Do not adopt a late offset baseline after the finger has already moved.
                guard let session = dragSession, session.itemID == id,
                      let initialOffset = session.initialContentOffset, let movement else { return }
                dragScrollDriver.track(
                    finger: movement.location,
                    shouldContinue: {
                        scenePhase == .active && isEditing && drag?.itemID == id && dragSession == session
                    },
                    didScroll: { offset in
                        guard dragSession == session else { return }
                        // Actual offset, including inset/boundary clamping, never requested distance.
                        let distance = offset - initialOffset
                        if dragScrollDistance != distance { dragScrollDistance = distance }
                    },
                    didInvalidate: { if dragSession == session { cancelDrag() } }
                )
            }
            .onEnded { value in
                defer { cancelDrag() }
                guard case .second(true, let movement?) = value,
                      let session = dragSession, session.itemID == id,
                      scenePhase == .active, isEditing, cancelledDragID != id else { return }
                let scrollDistance: CGFloat
                if let initialOffset = session.initialContentOffset {
                    guard !dragScrollDriver.isInvalidated, let offset = dragScrollDriver.contentOffset else { return }
                    scrollDistance = offset - initialOffset
                } else {
                    scrollDistance = 0
                }
                dragScrollDriver.stop()
                commitDrag(session: session, translation: movement.translation.height + scrollDistance)
            }
    }

    private func cancelDrag() {
        // An interrupted recognizer cannot restart or commit until GestureState resets.
        cancelledDragID = dragSession?.itemID ?? drag?.itemID ?? cancelledDragID
        dragScrollDriver.stop()
        dragSession = nil
        dragScrollDistance = 0
        liftedID = nil
    }

    /// A drop writes the draft once. A cancelled or interrupted gesture leaves the order untouched.
    private func commitDrag(session: CustomWorkoutDragSession, translation: CGFloat) {
        let ids = draft.items.map(\.id)
        guard ids == session.originalOrder, let source = ids.firstIndex(of: session.itemID) else { return }
        let heights = ids.map { rowHeights[$0] ?? Metrics.rowMinHeight }
        let target = CustomWorkoutReorder.targetIndex(heights: heights, spacing: ZOSpace.s, source: source, translation: translation)
        let order = CustomWorkoutReorder.moved(ids, from: source, to: target)
        guard order != ids, let reordered = CustomWorkoutReorder.reordered(draft.items, by: order) else { return }
        withAnimation(reduceMotion ? nil : ZOMotion.land(ZOMotion.quick)) { draft.items = reordered }
        announce(localization.format("Moved to position %1$lld of %2$lld.", .integer(target + 1), .integer(reordered.count)))
    }

    // MARK: Dock and toast

    private var dock: some View {
        VStack(spacing: ZOSpace.xs) {
            if isEditing && validationCount > 0 {
                Text(localization.format(validationCount == 1 ? "%1$lld detail needs attention" : "%1$lld details need attention",
                    .integer(validationCount)))
                    .zoText(.caption)
                    .foregroundStyle(theme.textPrimary)
            }
            if isEditing && !repository.isDraftAvailable && draft != confirmed {
                // Persistent after the toast expires: the repository cannot keep a draft right now.
                Text(localization.string("Changes are not kept as a draft on this iPhone right now. Save the workout to keep them."))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(localization.string(isEditing ? "Save workout" : "Start workout")) {
                if isEditing { save() } else { start() }
            }
            .buttonStyle(ZOButtonStyle(.primary, isLoading: isSaving))
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("customWorkout.saveAndStart")
            .disabled(!repository.isAvailable || isSaving)
            if isEditing {
                // Sharing belongs to batch E. Until then the position is held by an honest, inactive action.
                Button(localization.string("Share")) { }
                    .buttonStyle(ZOButtonStyle(.quiet))
                    .disabled(true)
                    .accessibilityHint(localization.string("Sharing a workout is not available yet."))
            }
        }
        .padding(.horizontal, ZOSpace.screenMargin)
        .padding(.top, ZOSpace.m)
        .padding(.bottom, ZOSpace.xs)
        .background(theme.backgroundPrimary)
    }

    @ViewBuilder
    private var toast: some View {
        if let removal {
            ZOToast(message: localization.format("%1$@ removed", .text(removal.item.displayName)),
                    actionTitle: localization.string("Undo")) { undoRemoval(removal.token) }
                .id(removal.token)
                .transition(toastTransition)
        } else if let draftNotice {
            ZOToast(message: draftNotice.message)
                .id(draftNotice.token)
                .transition(toastTransition)
        }
    }

    private var toastTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom))
    }

    // MARK: Actions

    private var validationCount: Int {
        (nameError == nil ? 0 : 1) + (exerciseError == nil ? 0 : 1) + loadErrors.count
    }

    private func save() {
        nameError = CustomWorkoutBuilderValidation.nameError(for: draft, among: repository.workouts)
        exerciseError = CustomWorkoutBuilderValidation.exercisesError(for: draft)
        loadErrors = Set(draft.items.filter { CustomWorkoutBuilderValidation.loadError(for: $0) != nil }.map(\.id))
        guard validationCount == 0 else {
            announce(localization.format("%1$lld details need attention. %2$@", .integer(validationCount),
                .text(localization.string(nameError ?? exerciseError ?? "Check the starting load."))))
            return
        }
        isSaving = true
        draftSaveTask?.cancel()
        guard repository.save(draft) else {
            isSaving = false
            // Saving cancels the delayed draft task. Keep the latest editable
            // copy now so a failed save does not strand only the older draft.
            if repository.isDraftAvailable { _ = repository.keepDraft(draft) }
            showError(localization.string("We could not confirm the save. Check the session details and local storage before trying again."))
            return
        }
        confirmed = repository.workouts.first(where: { $0.id == draft.id })
        draft = confirmed ?? draft
        clearRemoval()
        if !repository.discardDraft() {
            showError(localization.string("The workout was saved, but the unfinished draft could not be cleared from local storage."))
        }
        withAnimation(reduceMotion ? ZOMotion.crossfade(panel: true) : ZOMotion.land(ZOMotion.quick)) {
            isEditing = false
        }
        savedVersion += 1
        isSaving = false
        announce(localization.format("%1$@ saved. Start workout is ready.", .text(draft.name)))
    }

    private func start() {
        guard let saved = repository.workouts.first(where: { $0.id == draft.id }) else {
            showError(localization.string("The saved workout is unavailable. Try reopening My workouts."))
            return
        }
        if onStart(saved, selectedWarmUpLength) { dismiss() }
        else { showError(localization.string("The workout could not start. Your saved workout remains in My workouts.")) }
    }

    private func requestClose() {
        if isEditing && draft != confirmed && (!draft.items.isEmpty ||
            !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            showsLeaveConfirmation = true
        } else { dismiss() }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = draft.items.firstIndex(where: { $0.id == id }),
              draft.items.indices.contains(index + offset) else { return }
        let item = draft.items.remove(at: index)
        draft.items.insert(item, at: index + offset)
        announce(localization.format("Moved to position %1$lld of %2$lld.", .integer(index + offset + 1), .integer(draft.items.count)))
    }

    /// No confirmation for one exercise: the row leaves the draft and stays undoable for 5 seconds.
    private func remove(_ id: UUID) {
        guard isEditing, let index = draft.items.firstIndex(where: { $0.id == id }) else { return }
        let next = CustomWorkoutRemoval(item: draft.items[index], index: index)
        removalExpiry?.cancel()
        withAnimation(reduceMotion ? ZOMotion.crossfade() : ZOMotion.land(ZOMotion.quick)) {
            _ = draft.items.remove(at: index)
            removal = next
        }
        removalExpiry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(CustomWorkoutBuilderPresentation.undoSeconds))
            guard !Task.isCancelled, removal?.token == next.token else { return }
            withAnimation(reduceMotion ? ZOMotion.crossfade() : ZOMotion.leave(ZOMotion.quick)) { removal = nil }
        }
        announce(localization.format("%1$@ removed. Undo is available for 5 seconds.", .text(next.item.displayName)))
    }

    /// Only the latest removal can be undone, once; a stale or repeated tap does nothing.
    private func undoRemoval(_ token: UUID) {
        guard let current = removal, current.token == token else { return }
        removalExpiry?.cancel()
        removalExpiry = nil
        guard !draft.items.contains(where: { $0.id == current.item.id }) else {
            removal = nil
            return
        }
        let index = CustomWorkoutBuilderPresentation.restoredIndex(current.index, count: draft.items.count)
        withAnimation(reduceMotion ? ZOMotion.crossfade() : ZOMotion.land(ZOMotion.quick)) {
            draft.items.insert(current.item, at: index)
            removal = nil
        }
        announce(localization.format("%1$@ is back at position %2$lld.", .text(current.item.displayName), .integer(index + 1)))
    }

    private func clearRemoval() {
        removalExpiry?.cancel()
        removalExpiry = nil
        removal = nil
    }

    private func showDraftNotice(_ message: String) {
        let notice = CustomWorkoutDraftNotice(message: message)
        draftNoticeExpiry?.cancel()
        withAnimation(reduceMotion ? ZOMotion.crossfade() : ZOMotion.land(ZOMotion.quick)) { draftNotice = notice }
        announce(message)
        draftNoticeExpiry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(CustomWorkoutBuilderPresentation.undoSeconds))
            guard !Task.isCancelled, draftNotice?.token == notice.token else { return }
            withAnimation(reduceMotion ? ZOMotion.crossfade() : ZOMotion.leave(ZOMotion.quick)) { draftNotice = nil }
        }
    }

    private func itemBinding(for selection: CustomWorkoutItemSelection) -> Binding<CustomWorkoutItem> {
        let fallback = draft.items.first(where: { $0.id == selection.id }) ?? CustomWorkoutItem(id: selection.id, videoID: "")
        return Binding(
            get: { draft.items.first(where: { $0.id == selection.id }) ?? fallback },
            set: { updated in
                guard let index = draft.items.firstIndex(where: { $0.id == selection.id }) else { return }
                draft.items[index] = updated
            }
        )
    }

    private func handleItemSheetDismiss() {
        if let id = replaceAfterSheet {
            replaceAfterSheet = nil
            replacingItemID = id
            showsExercisePicker = true
        } else if let id = removeAfterSheet {
            removeAfterSheet = nil
            remove(id)
        }
    }

    private func handlePickerDismiss() {
        replacingItemID = nil
        if let id = reopenAfterPicker {
            reopenAfterPicker = nil
            if draft.items.contains(where: { $0.id == id }) { editingSelection = CustomWorkoutItemSelection(id: id) }
        }
    }

    private func validationMessage(_ text: String) -> some View {
        CustomWorkoutFieldMessage(text: localization.string(text))
    }

    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func showError(_ message: String) {
        errorMessage = message
        showsError = true
    }
}

struct CustomWorkoutWarmUpPicker: View {
    @Binding var selection: WorkoutWarmUpLength

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            ZOSegmentedControl("Warm-up length", selection: $selection, options: [ZOSegment(value: WorkoutWarmUpLength.full, label: Text("Full")), ZOSegment(value: WorkoutWarmUpLength.short, label: Text("Short")), ZOSegment(value: WorkoutWarmUpLength.none, label: Text("None"))])
            .accessibilityIdentifier("customWorkout.warmUpLength")

            Text(description)
                .zoText(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var description: String {
        switch selection {
        case .full:
            return "Recommended: easy movement, lighter practice, then working sets."
        case .short:
            return "A shorter movement and practice sequence before working sets."
        case .none:
            return "Go straight to set 1. A warm-up is encouraged, especially before heavier work."
        }
    }
}

// MARK: - Presentation facts (pure, unit tested)

/// Final proof38 geometry that has no generated role. Values come from components.css
/// (.zo-brow, .zo-slot, .zo-field, .zo-weekhead, .zo-excard, .zo-stepper, .zo-topbar).
enum CustomWorkoutBuilderMetrics {
    static let rowSpace = "customWorkoutRows"
    static let contentTop: CGFloat = 6
    static let topBarMinHeight: CGFloat = 52
    static let topBarTitleInset: CGFloat = 72
    static let summaryTop: CGFloat = 10
    static let badgeGap: CGFloat = 6
    static let sectionTop: CGFloat = 22
    static let sectionInset: CGFloat = 2
    static let addTop: CGFloat = 10
    static let fieldMessageTop: CGFloat = 6
    /// .zo-field gap and .zo-field-msg icon gap.
    static let fieldGap: CGFloat = 10
    static let fieldMessageGap: CGFloat = 6
    static let moreHitOverhang: CGFloat = (ZOSpace.hitTarget - ZOIcon.row) / 2
    /// proof.js picker: 10 pt above the muscle chips; .zo-weekhead 22 pt above, 8 pt below.
    static let pickerChipsTop: CGFloat = 10
    static let pickerHeadingBottom: CGFloat = 8
    static let rowMinHeight: CGFloat = 72
    static let rowLeading: CGFloat = 10
    static let rowVertical: CGFloat = 10
    static let rowTrailing: CGFloat = 6
    static let rowNumberWidth: CGFloat = 18
    static let rowThumbnail: CGFloat = 48
    static let sheetThumbnail: CGFloat = 64
    static let gripHitWidth: CGFloat = 36
    static let liftScale: CGFloat = 1.02
    static let liftRise: CGFloat = -4
    static let liftShadowY: CGFloat = 12
    /// CSS blur 28 equals a SwiftUI shadow radius of 14.
    static let liftShadowRadius: CGFloat = 14
    static let liftShadowOpacity: Double = 0.22
    static let slotStripe: CGFloat = 8
    static let slotStripeOpacity: Double = 0.05
    static let stepperMinHeight: CGFloat = 76
    static let gridGap: CGFloat = 10
    static let gridPosterHeight: CGFloat = 112
    static let cardTextTop: CGFloat = 8
    static let cardTextSide: CGFloat = 10
    static let pickMark: CGFloat = 26
    static let pickMarkInset: CGFloat = 8
    static let pickMarkRing: CGFloat = 2
    static let pickMarkAlpha: Double = 0.85
    static let restCaptionBottom: CGFloat = 6
    static let loadFieldWidth: CGFloat = 72
}

enum CustomWorkoutBuilderPresentation {
    static let undoSeconds = 5
    static let restPresets = [60, 90, 120, 180]
    /// The builder's existing rest choices before the redesign; still reachable through More.
    static let restChoices = [0, 30, 45, 60, 90, 120, 180, 300, 600]

    /// Chips always include the stored value, so a value outside the presets is shown, never rewritten.
    static func restChipValues(current: Int) -> [Int] {
        restPresets.contains(current) ? restPresets : restPresets + [current]
    }

    static func moreRestValues(current: Int) -> [Int] {
        Array(Set(restChoices + [current])).sorted()
    }

    static func restClock(_ seconds: Int) -> String {
        let remainder = seconds % 60
        return "\(seconds / 60):\(remainder < 10 ? "0" : "")\(remainder)"
    }

    static func restChipTitle(_ seconds: Int, localization: AppLocalization) -> String {
        seconds == 0 ? localization.string("No timed rest") : restClock(seconds)
    }

    /// "8 to 10", "8", "30 to 45 sec", with "per side" when typed so.
    static func workText(_ prescription: WorkingSetPrescription, localization: AppLocalization) -> String {
        let core: String
        if prescription.unit == .seconds {
            core = prescription.lowerBound == prescription.upperBound
                ? localization.format("%1$lld sec", .integer(prescription.lowerBound))
                : localization.format("%1$lld to %2$lld sec", .integer(prescription.lowerBound), .integer(prescription.upperBound))
        } else {
            core = prescription.lowerBound == prescription.upperBound
                ? "\(prescription.lowerBound)"
                : localization.format("%1$lld to %2$lld", .integer(prescription.lowerBound), .integer(prescription.upperBound))
        }
        return prescription.perSide ? localization.format("%1$@ per side", .text(core)) : core
    }

    /// "3 × 8 to 10 · rest 2:00"
    static func rowCaption(_ item: CustomWorkoutItem, localization: AppLocalization) -> String {
        let work = workText(item.prescription, localization: localization)
        return item.restSeconds == 0
            ? localization.format("%1$lld × %2$@ · no timed rest", .integer(item.sets), .text(work))
            : localization.format("%1$lld × %2$@ · rest %3$@", .integer(item.sets), .text(work), .text(restClock(item.restSeconds)))
    }

    /// "Dumbbell bench press, 3 sets of 8 to 10, rest 2 minutes"
    static func rowAccessibilityLabel(_ item: CustomWorkoutItem, localization: AppLocalization) -> String {
        let copy = WorkoutLocalization(localization: localization)
        let prescription = item.prescription
        var work = prescription.lowerBound == prescription.upperBound
            ? (prescription.unit == .seconds ? copy.quantity(prescription.lowerBound, .seconds) : "\(prescription.lowerBound)")
            : localization.format(prescription.unit == .seconds ? "%1$lld to %2$lld seconds" : "%1$lld to %2$lld",
                .integer(prescription.lowerBound), .integer(prescription.upperBound))
        if prescription.perSide { work = localization.format("%1$@ per side", .text(work)) }
        let rest = item.restSeconds == 0
            ? localization.string("no timed rest")
            : localization.format("rest %1$@", .text(copy.duration(item.restSeconds)))
        return localization.format("%1$@, %2$@ of %3$@, %4$@", .text(item.displayName),
            .text(copy.quantity(item.sets, .sets)), .text(work), .text(rest))
    }

    /// "Chest · Dumbbells · Bench": the authored or media descriptors, verbatim.
    static func detailLine(_ item: CustomWorkoutItem) -> String {
        let muscle = item.authoredExerciseID != nil
            ? item.authoredDefinition?.primaryMuscleNames.first
            : item.mediaExercise?.muscleFocus
        return ([muscle].compactMap { $0 } + item.equipmentIdentifiers)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The planning estimate from the existing deterministic estimator. No history,
    /// progression or storage is read or written; an invalid draft has no estimate.
    static func estimate(for workout: CustomWorkout, warmUp: WorkoutWarmUpLength) -> WorkoutTimeEstimate? {
        workout.makeSession(warmUpLengthOverride: warmUp, progressionAllowed: false)
            .flatMap { WorkoutTimeEstimator().estimate(for: $0) }
    }

    /// The sets badge. nil when an unvalidated older draft holds counts whose sum overflows;
    /// the badge is then left out rather than trapping or showing a made-up total.
    static func totalSets(_ items: [CustomWorkoutItem]) -> Int? {
        var total = 0
        for item in items {
            let next = total.addingReportingOverflow(item.sets)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }

    static func restoredIndex(_ original: Int, count: Int) -> Int {
        min(max(0, original), count)
    }

    /// The picker's result applied to the draft rows, unchanged from the builder before the redesign:
    /// a replacement keeps the row's UUID and its replace policy; otherwise the picks are appended in
    /// selection order (also when the row being replaced has gone). The row to open next is the
    /// replaced row or the first addition.
    static func applyingPicked(
        _ exercises: [MoveKitExercise], replacing id: UUID?, to items: [CustomWorkoutItem]
    ) -> CustomWorkoutPickerOutcome {
        var result = items
        if let id, let index = result.firstIndex(where: { $0.id == id }), let replacement = exercises.first {
            result[index] = result[index].replacing(with: replacement)
            return CustomWorkoutPickerOutcome(items: result, openItemID: id)
        }
        let additions = exercises.map { CustomWorkoutItem(videoID: $0.id) }
        result.append(contentsOf: additions)
        return CustomWorkoutPickerOutcome(items: result, openItemID: additions.first?.id)
    }
}

struct CustomWorkoutPickerOutcome: Equatable {
    let items: [CustomWorkoutItem]
    let openItemID: UUID?
}

/// A target shown as one value. Plus and minus shift both bounds together.
struct CustomWorkoutTargetRange: Equatable {
    let lower: Int
    let upper: Int?

    /// The stored target is inside the bounds and ordered. An older draft is decoded without
    /// validation, so a target can hold any Int, including Int.min or Int.max, or be inverted.
    func isValid(within bounds: ClosedRange<Int>) -> Bool {
        guard bounds.contains(lower) else { return false }
        guard let upper else { return true }
        return bounds.contains(upper) && upper >= lower
    }

    /// Keeps the width; refuses a step that would leave the bounds, so a range never narrows at an edge.
    /// An invalid or inverted stored target is refused as it is (never normalised), and the arithmetic
    /// reports overflow instead of trapping.
    func shifted(by delta: Int, within bounds: ClosedRange<Int>) -> CustomWorkoutTargetRange? {
        guard isValid(within: bounds) else { return nil }
        let newLower = lower.addingReportingOverflow(delta)
        guard !newLower.overflow, bounds.contains(newLower.partialValue) else { return nil }
        guard let upper else { return CustomWorkoutTargetRange(lower: newLower.partialValue, upper: nil) }
        let newUpper = upper.addingReportingOverflow(delta)
        guard !newUpper.overflow, bounds.contains(newUpper.partialValue) else { return nil }
        return CustomWorkoutTargetRange(lower: newLower.partialValue, upper: newUpper.partialValue)
    }

    /// The supplementary precise editor. Equal bounds become a scalar target.
    static func validated(lower: Int, upper: Int, within bounds: ClosedRange<Int>) -> CustomWorkoutTargetRange? {
        guard bounds.contains(lower), bounds.contains(upper), upper >= lower else { return nil }
        return CustomWorkoutTargetRange(lower: lower, upper: upper == lower ? nil : upper)
    }

    /// Choices for the precise editor's highest value. A stored lowest value outside the bounds
    /// (an older draft) never produces an inverted range; Apply stays unavailable until it is valid.
    static func upperChoices(lower: Int, within bounds: ClosedRange<Int>) -> ClosedRange<Int> {
        min(max(lower, bounds.lowerBound), bounds.upperBound) ... bounds.upperBound
    }

    static func current(for item: CustomWorkoutItem) -> CustomWorkoutTargetRange {
        if let seconds = item.durationSeconds { return CustomWorkoutTargetRange(lower: seconds, upper: item.durationUpperBound) }
        return CustomWorkoutTargetRange(lower: item.reps, upper: item.repUpperBound)
    }

    static func bounds(for item: CustomWorkoutItem) -> ClosedRange<Int> {
        item.durationSeconds == nil ? 1 ... 50 : 1 ... 86_400
    }

    func apply(to item: inout CustomWorkoutItem) {
        if item.durationSeconds != nil {
            item.durationSeconds = lower
            item.durationUpperBound = upper
        } else {
            item.reps = lower
            item.repUpperBound = upper
        }
    }
}

enum CustomWorkoutReorder {
    static func origin(of index: Int, heights: [CGFloat], spacing: CGFloat) -> CGFloat {
        heights.prefix(max(0, index)).reduce(0) { $0 + $1 + spacing }
    }

    /// The position the lifted row would take: one place for every other row whose centre it has passed.
    static func targetIndex(heights: [CGFloat], spacing: CGFloat, source: Int, translation: CGFloat) -> Int {
        guard heights.indices.contains(source) else { return 0 }
        let center = origin(of: source, heights: heights, spacing: spacing) + heights[source] / 2 + translation
        return heights.indices.filter { index in
            index != source && origin(of: index, heights: heights, spacing: spacing) + heights[index] / 2 < center
        }.count
    }

    static func moved<ID>(_ ids: [ID], from source: Int, to target: Int) -> [ID] {
        guard ids.indices.contains(source) else { return ids }
        var result = ids
        let id = result.remove(at: source)
        result.insert(id, at: min(max(0, target), result.count))
        return result
    }

    /// Applies a preview order only when it holds exactly the same rows; identities never change.
    static func reordered<Item: Identifiable>(_ items: [Item], by order: [Item.ID]) -> [Item]? {
        guard order.count == items.count, Set(order) == Set(items.map(\.id)) else { return nil }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let result = order.compactMap { byID[$0] }
        return result.count == items.count ? result : nil
    }
}

struct CustomWorkoutRemoval: Equatable {
    let token = UUID()
    let item: CustomWorkoutItem
    let index: Int
}

private struct CustomWorkoutDraftNotice: Equatable {
    let token = UUID()
    let message: String
}

private struct CustomWorkoutItemSelection: Identifiable, Equatable {
    let id: UUID
}

private struct CustomWorkoutDragSession: Equatable {
    let token = UUID()
    let itemID: UUID
    let originalOrder: [UUID]
    let initialContentOffset: CGFloat?
}

/// SwiftUI on iOS 17 does not expose pixel-based scroll positioning. This bridge
/// only reads the existing scroll view's public geometry and sets its offset.
/// It never takes the delegate, owns gestures, reorders items or stores a draft.
@MainActor
private final class CustomWorkoutDragScrollDriver {
    private weak var scrollView: UIScrollView?
    private var displayLink: CADisplayLink?
    private var finger: CGPoint = .zero
    private var lastTimestamp: CFTimeInterval?
    private var initialViewportSize: CGSize?
    private var initialInsets: UIEdgeInsets?
    private var lastReportedOffset: CGFloat?
    private var shouldContinue: (() -> Bool)?
    private var didScroll: ((CGFloat) -> Void)?
    private var didInvalidate: (() -> Void)?
    private(set) var isInvalidated = false

    var contentOffset: CGFloat? { scrollView?.contentOffset.y }

    func begin() {
        stop()
        isInvalidated = false
    }

    func attach(to view: UIView) {
        var ancestor = view.superview
        while let candidate = ancestor {
            if let scroll = candidate as? UIScrollView {
                if scrollView !== scroll {
                    invalidate()
                    scrollView = scroll
                }
                return
            }
            ancestor = candidate.superview
        }
    }

    func detach() {
        invalidate()
        scrollView = nil
    }

    func track(finger: CGPoint, shouldContinue: @escaping () -> Bool,
               didScroll: @escaping (CGFloat) -> Void, didInvalidate: @escaping () -> Void) {
        guard !isInvalidated, let scrollView, scrollView.window != nil else { return }
        self.finger = finger
        self.shouldContinue = shouldContinue
        self.didScroll = didScroll
        self.didInvalidate = didInvalidate
        guard displayLink == nil else { return }
        initialViewportSize = scrollView.bounds.size
        initialInsets = scrollView.adjustedContentInset
        let target = CustomWorkoutDragDisplayLinkTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(CustomWorkoutDragDisplayLinkTarget.tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
        initialViewportSize = nil
        initialInsets = nil
        lastReportedOffset = nil
        shouldContinue = nil
        didScroll = nil
        didInvalidate = nil
    }

    private func invalidate() {
        // Fence a late drop synchronously, but never write SwiftUI state from
        // updateUIView/dismantleUIView while SwiftUI is updating its hierarchy.
        isInvalidated = true
        let callback = didInvalidate
        stop()
        if let callback { Task { @MainActor in callback() } }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard shouldContinue?() == true, let scroll = scrollView, let window = scroll.window,
              window.windowScene?.activationState == .foregroundActive,
              scroll.bounds.size == initialViewportSize,
              scroll.adjustedContentInset == initialInsets else {
            invalidate()
            return
        }
        let elapsed = lastTimestamp.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastTimestamp = link.timestamp
        let insets = scroll.adjustedContentInset
        // The actual adjusted insets account for the top bar, dock and keyboard.
        let visibleBounds = scroll.bounds.inset(by: insets)
        let viewport = scroll.convert(visibleBounds, to: window).intersection(window.bounds)
        let velocity = CustomWorkoutEdgeScroll.velocity(finger: finger, viewport: viewport)
        if let next = CustomWorkoutEdgeScroll.nextOffset(
            current: scroll.contentOffset.y, contentHeight: scroll.contentSize.height,
            viewportHeight: scroll.bounds.height, topInset: insets.top, bottomInset: insets.bottom,
            velocity: velocity, elapsed: elapsed
        ) {
            // Essential direct manipulation, without animated travel under either motion setting.
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: false)
        }
        if lastReportedOffset != scroll.contentOffset.y {
            lastReportedOffset = scroll.contentOffset.y
            didScroll?(scroll.contentOffset.y)
        }
    }
}

/// CADisplayLink retains its target. A weak owner avoids a driver/link retain cycle.
@MainActor
private final class CustomWorkoutDragDisplayLinkTarget: NSObject {
    weak var owner: CustomWorkoutDragScrollDriver?

    init(owner: CustomWorkoutDragScrollDriver) { self.owner = owner }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.tick(link)
    }
}

private struct CustomWorkoutDragScrollAttachment: UIViewRepresentable {
    let driver: CustomWorkoutDragScrollDriver

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.driver = driver
        return view
    }

    func updateUIView(_ view: AttachmentView, context: Context) { driver.attach(to: view) }

    static func dismantleUIView(_ view: AttachmentView, coordinator: ()) { view.driver?.detach() }

    final class AttachmentView: UIView {
        weak var driver: CustomWorkoutDragScrollDriver?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { driver?.detach() } else { driver?.attach(to: self) }
        }
    }
}

/// Pure geometry policy shared by the actual display-link driver and its tests.
enum CustomWorkoutEdgeScroll {
    static let maximumSpeed: CGFloat = 260
    static let maximumFrameDuration: TimeInterval = 1.0 / 30.0

    static func velocity(finger: CGPoint, viewport: CGRect) -> CGFloat {
        guard !viewport.isNull, !viewport.isInfinite, viewport.width > 0, viewport.height > 0,
              finger.x.isFinite, finger.y.isFinite else { return 0 }
        let band = min(CGFloat(64), viewport.height / 4)
        guard viewport.insetBy(dx: -band, dy: -band).contains(finger) else { return 0 }
        if finger.y < viewport.minY + band {
            return -maximumSpeed * min(1, max(0, (viewport.minY + band - finger.y) / band))
        }
        if finger.y > viewport.maxY - band {
            return maximumSpeed * min(1, max(0, (finger.y - viewport.maxY + band) / band))
        }
        return 0
    }

    static func nextOffset(current: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat,
                           topInset: CGFloat, bottomInset: CGFloat, velocity: CGFloat,
                           elapsed: TimeInterval) -> CGFloat? {
        guard [current, contentHeight, viewportHeight, topInset, bottomInset, velocity].allSatisfy(\.isFinite),
              contentHeight >= 0, viewportHeight > 0, elapsed.isFinite, elapsed > 0, velocity != 0 else { return nil }
        let lower = -topInset
        let upper = max(lower, contentHeight - viewportHeight + bottomInset)
        let boundedSpeed = min(maximumSpeed, max(-maximumSpeed, velocity))
        let next = min(upper, max(lower, current + boundedSpeed * CGFloat(min(elapsed, maximumFrameDuration))))
        return abs(next - current) > 0.001 ? next : nil
    }
}

private struct CustomWorkoutRowDrag: Equatable {
    let itemID: UUID
    let translation: CGFloat
}

private struct CustomWorkoutDragPreview: Equatable {
    let order: [UUID]
    let source: Int
    let target: Int
    let liftedOrigin: CGFloat
}

/// Exercises, sets and the planning estimate, from the draft as it is now. Equatable so a drag,
/// which redraws the builder every frame, does not rebuild the estimate's session every frame.
private struct CustomWorkoutSummaryBadges: View, Equatable {
    let workout: CustomWorkout
    let warmUp: WorkoutWarmUpLength
    let localization: AppLocalization

    var body: some View {
        let copy = WorkoutLocalization(localization: localization)
        let estimate = CustomWorkoutBuilderPresentation.estimate(for: workout, warmUp: warmUp)
        HStack(spacing: CustomWorkoutBuilderMetrics.badgeGap) {
            ZOBadge(text: copy.quantity(workout.items.count, .exercises))
            if let sets = CustomWorkoutBuilderPresentation.totalSets(workout.items) {
                ZOBadge(text: copy.quantity(sets, .sets))
            }
            ZOBadge(text: estimate.map { localization.format("About %1$lld min", .integer($0.maximumMinutes)) }
                ?? localization.string("Time varies"))
                // The badge is an approximate planning figure; VoiceOver hears its upper-estimate meaning.
                .accessibilityLabel(estimate.map { localization.format("Estimated up to %1$lld minutes", .integer($0.maximumMinutes)) }
                    ?? localization.string("Time varies"))
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Type outside the generated roles

/// Proof-specified Instrument Sans instances with no generated role: the name field (600 20/24),
/// the row number (600 13/18 tabular) and a trailing row value (400 15/20). Same bundled variable
/// resource and axes as ZOTextStyle, scaled for Dynamic Type. Shared-helper request in C25-RESULT.md.
enum CustomWorkoutTextRole {
    case fieldTitle, rowNumber, trailingValue

    fileprivate var spec: (size: CGFloat, lineHeight: CGFloat, weight: CGFloat, textStyle: UIFont.TextStyle, tabular: Bool, fallback: ZOTextStyle) {
        switch self {
        case .fieldTitle: (size: 20, lineHeight: 24, weight: 600, textStyle: .title3, tabular: false, fallback: .section)
        case .rowNumber: (size: 13, lineHeight: 18, weight: 600, textStyle: .footnote, tabular: true, fallback: .caption)
        case .trailingValue: (size: 15, lineHeight: 20, weight: 400, textStyle: .subheadline, tabular: false, fallback: .label)
        }
    }
}

private enum CustomWorkoutVariableFont {
    static let width = 0x77647468   // 'wdth'
    static let weight = 0x77676874  // 'wght'
    static let descriptor: CTFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "InstrumentSans-Variable", withExtension: "ttf"),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        else { return nil }
        return descriptors.first
    }()
}

private struct CustomWorkoutTextModifier: ViewModifier {
    let role: CustomWorkoutTextRole
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    func body(content: Content) -> some View {
        let spec = role.spec
        if let resource = CustomWorkoutVariableFont.descriptor {
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
            let size = UIFontMetrics(forTextStyle: spec.textStyle).scaledValue(for: spec.size, compatibleWith: traits)
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(resource, [
                kCTFontVariationAttribute: [CustomWorkoutVariableFont.width: 100, CustomWorkoutVariableFont.weight: spec.weight]
            ] as CFDictionary)
            let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
            let base = Font(font)
            content
                .font(spec.tabular ? base.monospacedDigit() : base)
                .lineSpacing(max(0, spec.lineHeight * size / spec.size - natural))
        } else {
            content.zoText(spec.fallback)
        }
    }
}

extension View {
    fileprivate func customWorkoutType(_ role: CustomWorkoutTextRole) -> some View {
        modifier(CustomWorkoutTextModifier(role: role))
    }
}

/// .zo-field-msg: 500 13/18 in the error colour, a 16 pt icon 6 pt before the text.
private struct CustomWorkoutFieldMessage: View {
    let text: String
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: CustomWorkoutBuilderMetrics.fieldMessageGap) {
            Image(systemName: "exclamationmark.circle")
                .zoIcon(ZOIcon.inline)
                .accessibilityHidden(true)
            Text(text)
                .zoText(.caption)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.destructivePrimary)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Row, slot and glyph

private struct CustomWorkoutBuilderRow: View {
    let number: Int
    let name: String
    let caption: String
    let exercise: MoveKitExercise?
    var showsGrip = true
    var isLifted = false

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private typealias Metrics = CustomWorkoutBuilderMetrics

    var body: some View {
        HStack(spacing: ZOSpace.m) {
            Text(verbatim: "\(number)")
                .customWorkoutType(.rowNumber)
                .foregroundStyle(theme.textTertiary)
                .frame(width: Metrics.rowNumberWidth)
            CustomWorkoutExerciseThumbnail(exercise: exercise, width: Metrics.rowThumbnail, height: Metrics.rowThumbnail,
                cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .control, radius: ZORadius.control).resolvedRadius)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: name)
                    .zoText(.section)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: caption)
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsGrip {
                CustomWorkoutGripGlyph()
                    .stroke(style: StrokeStyle(lineWidth: CustomWorkoutGripGlyph.stroke(for: ZOIcon.row), lineCap: .round, lineJoin: .round))
                    .foregroundStyle(isLifted ? theme.textPrimary : theme.textTertiary)
                    .frame(width: ZOIcon.row, height: ZOIcon.row)
                    .frame(width: Metrics.gripHitWidth, height: ZOSpace.hitTarget)
                    .contentShape(Rectangle())
            }
        }
        .padding(.leading, Metrics.rowLeading)
        .padding(.vertical, Metrics.rowVertical)
        .padding(.trailing, showsGrip ? Metrics.rowTrailing : Metrics.rowLeading)
        .frame(minHeight: Metrics.rowMinHeight)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: .continuous))
        .overlay {
            if isLifted {
                RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: .continuous)
                    .inset(by: -ZOStroke.control / 2)
                    .stroke(theme.textPrimary, lineWidth: ZOStroke.control)
            }
        }
        .shadow(color: isLifted ? ZOColor.Swatch.yellow.on.opacity(Metrics.liftShadowOpacity) : .clear,
                radius: Metrics.liftShadowRadius, y: Metrics.liftShadowY)
        .scaleEffect(isLifted && !reduceMotion ? Metrics.liftScale : 1)
        .offset(y: isLifted && !reduceMotion ? Metrics.liftRise : 0)
    }
}

/// The dashed landing place: a 1.5 pt strong separator edge over faint 135° ink stripes.
private struct CustomWorkoutRowSlot: View {
    @Environment(\.zeroOneTheme) private var theme
    private typealias Metrics = CustomWorkoutBuilderMetrics

    var body: some View {
        Canvas { context, size in
            let period = 2 * Metrics.slotStripe * 2.squareRoot()
            let band = Metrics.slotStripe * 2.squareRoot()
            var path = Path()
            var start = band
            while start - size.height < size.width + period {
                path.move(to: CGPoint(x: start, y: 0))
                path.addLine(to: CGPoint(x: start + band, y: 0))
                path.addLine(to: CGPoint(x: start + band - size.height, y: size.height))
                path.addLine(to: CGPoint(x: start - size.height, y: size.height))
                path.closeSubpath()
                start += period
            }
            context.fill(path, with: .color(theme.textPrimary.opacity(Metrics.slotStripeOpacity)))
        }
        .clipShape(RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: .continuous).strokeBorder(theme.separatorStrong, lineWidth: ZOStroke.control)
        }
        .accessibilityHidden(true)
    }
}

/// icons.js grip: M5 9h14 M5 15h14 on the 24 grid, stroke 1.75, round caps.
private struct CustomWorkoutGripGlyph: Shape {
    static func stroke(for size: CGFloat) -> CGFloat { 1.75 * size / 24 }

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        var path = Path()
        for y: CGFloat in [9, 15] {
            path.move(to: CGPoint(x: rect.minX + 5 * unit, y: rect.minY + y * unit))
            path.addLine(to: CGPoint(x: rect.minX + 19 * unit, y: rect.minY + y * unit))
        }
        return path
    }
}

// MARK: - Exercise thumbnail

/// The MoveKit poster cropped to fill, focus 40% from the top (HANDOFF-ROUND-1 shared pieces).
/// Without a poster it shows the app's honest no-video state, never a drawn figure.
struct CustomWorkoutExerciseThumbnail: View {
    let exercise: MoveKitExercise?
    let width: CGFloat
    let height: CGFloat
    var cornerRadius: CGFloat = ZORadius.control

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var poster: UIImage?
    @State private var didFinishLoading = false

    init(exercise: MoveKitExercise?, size: CGFloat) {
        self.init(exercise: exercise, width: size, height: size)
    }

    init(exercise: MoveKitExercise?, width: CGFloat, height: CGFloat, cornerRadius: CGFloat = ZORadius.control) {
        self.exercise = exercise
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    /// Posters are 1936 × 1072 video frames; decode enough pixels for the filled crop.
    private static let posterAspect: CGFloat = 1936.0 / 1072.0
    private var maxPixel: Int { max(1, Int((max(width, height * Self.posterAspect) * displayScale).rounded(.up))) }
    private var taskID: String { "\(exercise?.posterResource ?? "-"):\(maxPixel)" }

    var body: some View {
        ZStack {
            theme.surfaceSecondary
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .offset(y: focusOffset(for: poster.size))
            } else if exercise == nil || didFinishLoading {
                Image(systemName: "video.slash")
                    .zoIcon(ZOIcon.row)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: taskID) {
            poster = nil
            didFinishLoading = false
            guard let exercise else { return }
            let thumbnail = await CustomWorkoutPosterStore.shared.image(for: exercise.posterResource, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            poster = thumbnail ?? UIImage(named: exercise.posterResource)
            didFinishLoading = true
        }
    }

    /// object-position 50% 40%: move the filled image down by a tenth of its vertical excess.
    private func focusOffset(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 0 }
        let scale = max(width / size.width, height / size.height)
        let excess = size.height * scale - height
        return excess > 0 ? excess * 0.1 : 0
    }
}

// MARK: - One exercise sheet

private struct CustomWorkoutItemSheet: View {
    @Binding var item: CustomWorkoutItem
    let position: Int
    let loadError: String?
    let onDone: () -> Void
    let onReplace: () -> Void
    let onRemove: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @AccessibilityFocusState private var titleFocused: Bool
    @State private var showsRangeEditor = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var actionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: ZOSpace.m))
            : AnyLayout(HStackLayout(spacing: ZOSpace.m))
    }
    private typealias Metrics = CustomWorkoutBuilderMetrics

    private var copy: WorkoutLocalization { WorkoutLocalization(localization: localization) }
    private var range: CustomWorkoutTargetRange { CustomWorkoutTargetRange.current(for: item) }
    private var bounds: ClosedRange<Int> { CustomWorkoutTargetRange.bounds(for: item) }
    private var isTimed: Bool { item.durationSeconds != nil }

    var body: some View {
        VStack(spacing: 0) {
            sheetBar
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.m) {
                    header
                    VStack(spacing: 0) {
                        CustomWorkoutValueStepper(
                            label: localization.string("Sets"),
                            value: "\(item.sets)",
                            accessibilityValue: copy.quantity(item.sets, .sets),
                            canDecrease: item.sets > 1,
                            canIncrease: item.sets < 12,
                            onDecrease: { item.sets -= 1 },
                            onIncrease: { item.sets += 1 }
                        )
                        separator
                        CustomWorkoutValueStepper(
                            label: localization.string(isTimed ? "Seconds" : "Reps"),
                            value: targetValue,
                            accessibilityValue: targetValue,
                            canDecrease: range.shifted(by: -1, within: bounds) != nil,
                            canIncrease: range.shifted(by: 1, within: bounds) != nil,
                            onDecrease: { shift(by: -1) },
                            onIncrease: { shift(by: 1) },
                            onEditValue: { showsRangeEditor = true },
                            editTitle: localization.string("Set the lowest and highest")
                        )
                    }
                    .padding(.horizontal, ZOSpace.l)
                    .zoThemeCardSurface()

                    restChips

                    VStack(spacing: 0) {
                        loadRow
                        separator
                        Toggle(isOn: Binding(get: { item.perSide == true }, set: { item.perSide = $0 })) {
                            Text(localization.string("Per side")).zoText(.section)
                        }
                        .frame(minHeight: ZOSpace.rowMinHeight)
                        separator
                        Toggle(isOn: Binding(
                            get: { item.durationSeconds != nil },
                            set: {
                                item.durationSeconds = $0 ? 30 : nil
                                item.durationUpperBound = nil
                            }
                        )) {
                            Text(localization.string("Timed, not reps")).zoText(.section)
                        }
                        .frame(minHeight: ZOSpace.rowMinHeight)
                    }
                    .padding(.horizontal, ZOSpace.l)
                    .zoThemeCardSurface()

                    if let loadError {
                        CustomWorkoutFieldMessage(text: localization.string(loadError))
                    }

                    // Side by side as drawn; stacked at accessibility text sizes so labels never truncate.
                    actionLayout {
                        Button(localization.string("Replace"), action: onReplace)
                            .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                        // Proof: a secondary button with only its label and icon in the error colour.
                        Button(action: onRemove) {
                            Label {
                                Text(localization.string("Remove"))
                            } icon: {
                                Image(systemName: "trash").zoIcon(ZOIcon.inline)
                            }
                            .labelStyle(ZOIconLabelStyle())
                            .foregroundStyle(theme.destructivePrimary)
                        }
                        .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                    }
                }
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.bottom, ZOSpace.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(theme.surfacePrimary)
        .onAppear { titleFocused = true }
        .sheet(isPresented: $showsRangeEditor) {
            CustomWorkoutRangeEditor(
                title: localization.string(isTimed ? "Seconds" : "Reps"),
                bounds: bounds,
                initial: range
            ) { applied in
                var updated = item
                applied.apply(to: &updated)
                item = updated
            }
            .zeroOneTheme(theme)
            .preferredColorScheme(theme.colorScheme)
            .zoSheet(theme)
            .presentationDetents([.medium])
        }
    }

    private var sheetBar: some View {
        HStack(spacing: ZOSpace.s) {
            Color.clear.frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget)
            Text(localization.format("Exercise %1$lld", .integer(position)))
                .zoText(.section)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            Button(action: onDone) {
                Image(systemName: "checkmark").zoIcon(ZOIcon.row)
            }
            .buttonStyle(CustomWorkoutSheetRoundStyle())
            .accessibilityLabel(localization.string("Done"))
        }
        .padding(.horizontal, ZOSpace.l)
        .frame(minHeight: ZOSpace.rowMinHeight)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            HStack(spacing: ZOSpace.m) {
                CustomWorkoutExerciseThumbnail(exercise: item.mediaExercise, width: Metrics.sheetThumbnail, height: Metrics.sheetThumbnail,
                    cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .control, radius: ZORadius.control).resolvedRadius)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: item.displayName)
                        .zoText(.section)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: CustomWorkoutBuilderPresentation.detailLine(item))
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let definition = item.authoredDefinition {
                // Authored coaching and pain guidance stay with the exercise they belong to.
                Text(verbatim: definition.shortCoachingCue)
                    .zoText(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: definition.painGuardrail)
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, ZOSpace.xs)
    }

    private var targetValue: String {
        isTimed
            ? CustomWorkoutBuilderPresentation.workText(WorkingSetPrescription(unit: .seconds, lowerBound: range.lower,
                upperBound: range.upper ?? range.lower, perSide: false), localization: localization)
            : CustomWorkoutBuilderPresentation.workText(WorkingSetPrescription(unit: .repetitions, lowerBound: range.lower,
                upperBound: range.upper ?? range.lower, perSide: false), localization: localization)
    }

    private func shift(by delta: Int) {
        guard let next = range.shifted(by: delta, within: bounds) else { return }
        var updated = item
        next.apply(to: &updated)
        item = updated
    }

    private var restChips: some View {
        VStack(alignment: .leading, spacing: Metrics.restCaptionBottom) {
            Text(localization.string("Rest after each set"))
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ZOSpace.s) {
                    ForEach(CustomWorkoutBuilderPresentation.restChipValues(current: item.restSeconds), id: \.self) { seconds in
                        ZOChip(title: CustomWorkoutBuilderPresentation.restChipTitle(seconds, localization: localization),
                               isSelected: item.restSeconds == seconds) { item.restSeconds = seconds }
                    }
                    Menu {
                        ForEach(CustomWorkoutBuilderPresentation.moreRestValues(current: item.restSeconds), id: \.self) { seconds in
                            Button {
                                item.restSeconds = seconds
                            } label: {
                                if item.restSeconds == seconds {
                                    Label(CustomWorkoutBuilderPresentation.restChipTitle(seconds, localization: localization), systemImage: "checkmark")
                                } else {
                                    Text(CustomWorkoutBuilderPresentation.restChipTitle(seconds, localization: localization))
                                }
                            }
                        }
                    } label: {
                        Text(localization.string("More"))
                    }
                    .menuStyle(.button)
                    .buttonStyle(ZOChipStyle(isSelected: false))
                    .accessibilityLabel(localization.string("More rest times"))
                }
                .padding(.vertical, ZOStroke.focus)
            }
        }
    }

    private var loadRow: some View {
        // At accessibility sizes the value and unit move under the label instead of squeezing it.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.s))
            : AnyLayout(HStackLayout(spacing: ZOSpace.m))
        return layout {
            VStack(alignment: .leading, spacing: 0) {
                Text(localization.string("Starting load")).zoText(.section)
                Text(localization.string("Optional. You can change it mid-set."))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: ZOSpace.m) {
                TextField(String(0), value: $item.targetLoad, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .customWorkoutType(.trailingValue)
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: Metrics.loadFieldWidth)
                    .accessibilityLabel(localization.string("Starting load"))
                Picker(localization.string("Unit"), selection: $item.loadUnit) {
                    Text(verbatim: "kg").tag(LoadUnit.kilograms)
                    Text(verbatim: "lb").tag(LoadUnit.pounds)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(theme.textSecondary)
            }
        }
        .frame(minHeight: ZOSpace.rowMinHeight)
        .padding(.vertical, ZOSpace.s)
    }

    private var separator: some View {
        Rectangle()
            .fill(theme.strokeSubtle)
            .frame(height: ZOStroke.hairline)
            .accessibilityHidden(true)
    }
}

/// .zo-stepper: caption label over a metric value, then 48 pt step buttons.
private struct CustomWorkoutValueStepper: View {
    let label: String
    let value: String
    let accessibilityValue: String
    let canDecrease: Bool
    let canIncrease: Bool
    let onDecrease: () -> Void
    let onIncrease: () -> Void
    var onEditValue: (() -> Void)? = nil
    var editTitle: String? = nil

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        HStack(spacing: ZOSpace.m) {
            valueStack
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDecrease) { Image(systemName: "minus").zoIcon(ZOIcon.row) }
                .buttonStyle(ZOButtonStyle(.step))
                .disabled(!canDecrease)
                .accessibilityLabel(localization.format("Decrease %1$@", .text(label)))
            Button(action: onIncrease) { Image(systemName: "plus").zoIcon(ZOIcon.row) }
                .buttonStyle(ZOButtonStyle(.step))
                .disabled(!canIncrease)
                .accessibilityLabel(localization.format("Increase %1$@", .text(label)))
        }
        .frame(minHeight: CustomWorkoutBuilderMetrics.stepperMinHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if canIncrease { onIncrease() }
            case .decrement: if canDecrease { onDecrease() }
            @unknown default: break
            }
        }
        .modifier(CustomWorkoutOptionalAction(title: editTitle, action: onEditValue))
        // Round 3 haptics map: a number that changes gives a selection tick.
        .sensoryFeedback(.selection, trigger: value)
    }

    @ViewBuilder
    private var valueStack: some View {
        let stack = VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            Text(verbatim: value)
                .zoThemeText(.metric)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        if let onEditValue {
            Button(action: onEditValue) { stack.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            stack
        }
    }
}

private struct CustomWorkoutOptionalAction: ViewModifier {
    let title: String?
    let action: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let title, let action {
            content.accessibilityAction(named: Text(title), action)
        } else {
            content
        }
    }
}

/// Supplementary precise editor for a target's lowest and highest values. Applies only a valid range.
private struct CustomWorkoutRangeEditor: View {
    let title: String
    let bounds: ClosedRange<Int>
    let initial: CustomWorkoutTargetRange
    let onApply: (CustomWorkoutTargetRange) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var lower: Int
    @State private var upper: Int
    @AccessibilityFocusState private var titleFocused: Bool

    init(title: String, bounds: ClosedRange<Int>, initial: CustomWorkoutTargetRange, onApply: @escaping (CustomWorkoutTargetRange) -> Void) {
        self.title = title
        self.bounds = bounds
        self.initial = initial
        self.onApply = onApply
        _lower = State(initialValue: initial.lower)
        _upper = State(initialValue: initial.upper ?? initial.lower)
    }

    private var validated: CustomWorkoutTargetRange? {
        CustomWorkoutTargetRange.validated(lower: lower, upper: upper, within: bounds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack {
                Button(localization.string("Cancel")) { dismiss() }
                    .buttonStyle(ZOButtonStyle(.quiet))
                Spacer(minLength: ZOSpace.s)
                Text(title)
                    .zoText(.section)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Spacer(minLength: ZOSpace.s)
                Button(localization.string("Apply")) {
                    guard let validated else { return }
                    onApply(validated)
                    dismiss()
                }
                .buttonStyle(ZOButtonStyle(.quiet))
                .disabled(validated == nil)
            }
            ZOStepper(LocalizedStringKey(localization.format("Lowest: %1$lld", .integer(lower))), value: $lower, in: bounds)
            ZOStepper(LocalizedStringKey(localization.format("Highest: %1$lld", .integer(upper))), value: $upper,
                      in: CustomWorkoutTargetRange.upperChoices(lower: lower, within: bounds))
            Text(localization.string("Use the same number for one fixed target."))
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, ZOSpace.screenMargin)
        .padding(.vertical, ZOSpace.l)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surfacePrimary)
        .onChange(of: lower) { _, value in if upper < value { upper = value } }
        .onAppear { titleFocused = true }
    }
}

/// .zo-sheet-bar .zo-btn.round: 44 pt, surface2. Shared-variant request in C25-RESULT.md.
private struct CustomWorkoutSheetRoundStyle: ButtonStyle {
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        return configuration.label
            .animation(ZOControlFidelity.buttonForegroundAnimation(.round, reduceMotion: reduceMotion)) {
                $0.foregroundStyle(theme.textPrimary)
            }
            .frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget)
            .animation(ZOControlFidelity.buttonBackgroundAnimation(.round, reduceMotion: reduceMotion)) {
                $0.background(theme.surfaceSecondary, in: Circle())
            }
            .animation(reduceMotion ? nil : ZOMotion.brace(ZOMotion.micro)) {
                $0.scaleEffect(ZOControlFidelity.pressScale(pressed: pressed, reduceMotion: reduceMotion))
            }
            .contentShape(Circle())
    }
}

// MARK: - Add or replace exercises

private struct CustomWorkoutExercisePicker: View {
    let isReplacing: Bool
    let onSelect: ([MoveKitExercise]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var searchText = ""
    @State private var selectedIDs: [String] = []
    @State private var muscle: String?
    @State private var equipment: String?
    @State private var previewExercise: MoveKitExercise?
    @FocusState private var searchFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private typealias Metrics = CustomWorkoutBuilderMetrics

    /// Two columns as drawn; one column at accessibility text sizes (HANDOFF-ROUND-3, phase 37).
    private var gridColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: Metrics.gridGap), GridItem(.flexible())]
    }

    private var results: [MoveKitExercise] {
        MoveKitExerciseCatalog.filter(query: searchText, muscle: muscle, equipment: equipment)
    }

    private var orderedSelection: [MoveKitExercise] {
        selectedIDs.compactMap { MoveKitExerciseCatalog.exercise(for: $0) }
    }

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    searchField
                    muscleChips
                        .padding(.top, Metrics.pickerChipsTop)
                    // Supplementary equipment filter, one chip row below the muscle chips.
                    equipmentMenu
                        .padding(.top, Metrics.pickerChipsTop)
                    HStack(alignment: .firstTextBaseline) {
                        Text(muscle ?? localization.string("All exercises"))
                            .zoText(.section)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: ZOSpace.s)
                        Text(localization.format("%1$lld of %2$lld", .integer(results.count), .integer(MoveKitExercise.all.count)))
                            .zoText(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.horizontal, Metrics.sectionInset)
                    .padding(.top, Metrics.sectionTop)
                    .padding(.bottom, Metrics.pickerHeadingBottom)
                    if results.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: Metrics.gridGap) {
                            ForEach(results) { exercise in card(exercise) }
                        }
                    }
                }
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.top, Metrics.contentTop)
                .padding(.bottom, ZOSpace.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(theme.backgroundPrimary)
        .safeAreaInset(edge: .bottom, spacing: 0) { dock }
        .sheet(item: $previewExercise) { exercise in
            CustomWorkoutExercisePreview(exercise: exercise)
                .zeroOneTheme(theme)
                .preferredColorScheme(theme.colorScheme)
                .zoSheet(theme)
                .presentationDetents([.large])
        }
    }

    private var topBar: some View {
        HStack(spacing: ZOSpace.m) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").zoIcon(ZOIcon.row)
            }
            .buttonStyle(ZOButtonStyle(.round))
            .accessibilityLabel(localization.string("Close"))
            Text(localization.string(isReplacing ? "Replace exercise" : "Add exercises"))
                .zoText(.section)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Color.clear.frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget)
        }
        .frame(minHeight: Metrics.topBarMinHeight)
        .padding(.horizontal, ZOSpace.screenMargin)
    }

    private var searchField: some View {
        HStack(spacing: Metrics.gridGap) {
            Image(systemName: "magnifyingglass")
                .zoIcon(ZOIcon.row)
                .foregroundStyle(theme.textSecondary)
            TextField(text: $searchText, prompt: Text(localization.format("Search %1$lld exercises", .integer(MoveKitExercise.all.count)))
                .foregroundStyle(theme.textTertiary)) {
                Text(localization.string("Search exercises"))
            }
            .zoText(.body)
            .focused($searchFocused)
            .submitLabel(.search)
            .autocorrectionDisabled()
        }
        .padding(.horizontal, ZOSpace.l)
        .frame(minHeight: ZOSpace.rowMinHeight)
        .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .control, radius: ZORadius.control).resolvedRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .control, radius: ZORadius.control).resolvedRadius, style: .continuous)
                .strokeBorder(searchFocused ? theme.textPrimary : theme.separatorStrong,
                              lineWidth: searchFocused ? ZOStroke.focus : ZOStroke.control)
        }
    }

    private var muscleChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZOSpace.s) {
                ZOChip(title: localization.string("All muscles"), isSelected: muscle == nil) { muscle = nil }
                ForEach(MoveKitExerciseCatalog.muscleFilters, id: \.self) { value in
                    ZOChip(title: value, isSelected: muscle == value) { muscle = muscle == value ? nil : value }
                }
            }
            .padding(.vertical, ZOStroke.focus)
        }
    }

    /// Supplementary: equipment stays filterable through a compact native menu.
    private var equipmentMenu: some View {
        Menu {
            Button(localization.string("All equipment")) { equipment = nil }
            ForEach(MoveKitExerciseCatalog.equipmentFilters, id: \.self) { value in
                Button(value) { equipment = value }
            }
        } label: {
            Label {
                Text(equipment ?? localization.string("All equipment"))
            } icon: {
                Image(systemName: "chevron.down").zoIcon(ZOIcon.inline)
            }
            .labelStyle(ZOIconLabelStyle())
        }
        .menuStyle(.button)
        .buttonStyle(ZOChipStyle(isSelected: equipment != nil))
        .accessibilityLabel(localization.string("Equipment"))
        .accessibilityValue(equipment ?? localization.string("All equipment"))
    }

    private func card(_ exercise: MoveKitExercise) -> some View {
        let picked = selectedIDs.contains(exercise.id)
        return Button {
            if isReplacing { selectedIDs = picked ? [] : [exercise.id] }
            else if let index = selectedIDs.firstIndex(of: exercise.id) { selectedIDs.remove(at: index) }
            else { selectedIDs.append(exercise.id) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: Metrics.gridPosterHeight)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        GeometryReader { proxy in
                            CustomWorkoutExerciseThumbnail(exercise: exercise, width: proxy.size.width,
                                                           height: Metrics.gridPosterHeight, cornerRadius: 0)
                        }
                    }
                    .clipped()
                VStack(alignment: .leading, spacing: 0) {
                    // At accessibility sizes the text grows instead of truncating.
                    Text(verbatim: exercise.name)
                        .zoText(.label)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                    Text(verbatim: "\(exercise.muscleFocus) · \(exercise.equipment)")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Metrics.cardTextTop)
                .padding(.horizontal, Metrics.cardTextSide)
                .padding(.bottom, Metrics.cardTextSide)
            }
            .background(theme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: .continuous))
            .overlay {
                if picked { RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: .continuous).strokeBorder(theme.textPrimary, lineWidth: ZOStroke.focus) }
            }
            .overlay(alignment: .topTrailing) {
                CustomWorkoutPickMark(isPicked: picked)
                    .padding(Metrics.pickMarkInset)
            }
        }
        .buttonStyle(ZOPressStyle())
        .contextMenu {
            Button {
                previewExercise = exercise
            } label: {
                Label(localization.string("Preview video"), systemImage: "play")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(exercise.name), \(exercise.muscleFocus), \(exercise.equipment)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityAction(named: Text(localization.string("Preview video"))) { previewExercise = exercise }
    }

    private var emptyState: some View {
        VStack(spacing: ZOSpace.m) {
            Image(systemName: "magnifyingglass")
                .zoIcon(ZOIcon.feature)
                .foregroundStyle(theme.textSecondary)
            Text(localization.string("No exercises match"))
                .zoText(.section)
            Text(localization.format("Change the search or filters to see more of the %1$lld exercises.", .integer(MoveKitExercise.all.count)))
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(localization.string("Show all exercises")) {
                searchText = ""
                muscle = nil
                equipment = nil
            }
            .buttonStyle(ZOButtonStyle(.secondary))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ZOSpace.x3)
    }

    private var dock: some View {
        Button(dockTitle) {
            onSelect(orderedSelection)
            dismiss()
        }
        .buttonStyle(ZOButtonStyle(.primary))
        .disabled(selectedIDs.isEmpty)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ZOSpace.screenMargin)
        .padding(.top, ZOSpace.m)
        .padding(.bottom, ZOSpace.xs)
        .background(theme.backgroundPrimary)
    }

    private var dockTitle: String {
        if isReplacing { return localization.string("Replace exercise") }
        guard !selectedIDs.isEmpty else { return localization.string("Add exercises") }
        return localization.format("Add %1$@", .text(WorkoutLocalization(localization: localization).quantity(selectedIDs.count, .exercises)))
    }
}

/// The pick mark sits on always-light posters, so it uses fixed brand colours (Onyx, white, warm white).
private struct CustomWorkoutPickMark: View {
    let isPicked: Bool
    private typealias Metrics = CustomWorkoutBuilderMetrics
    private static let onyx = ZOColor.Swatch.yellow.on
    private static let ring = Color(zoHex: 0xFFFFFF, alpha: CustomWorkoutBuilderMetrics.pickMarkAlpha)
    private static let brandInk = Color(zoHex: 0xF7F6F1)

    var body: some View {
        ZStack {
            Circle().fill(isPicked ? Self.onyx : Self.ring)
            if isPicked {
                Circle()
                    .inset(by: -Metrics.pickMarkRing / 2)
                    .stroke(Self.ring, lineWidth: Metrics.pickMarkRing)
                Image(systemName: "checkmark")
                    .zoIcon(ZOIcon.inline)
                    .foregroundStyle(Self.brandInk)
            } else {
                Circle().strokeBorder(Self.onyx, lineWidth: ZOStroke.control)
            }
        }
        .frame(width: Metrics.pickMark, height: Metrics.pickMark)
        .accessibilityHidden(true)
    }
}

/// Supplementary preview: the exercise's own bundled MoveKit demonstration.
private struct CustomWorkoutExercisePreview: View {
    let exercise: MoveKitExercise

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack(spacing: ZOSpace.s) {
                Color.clear.frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget)
                Text(verbatim: exercise.name)
                    .zoText(.section)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "checkmark").zoIcon(ZOIcon.row)
                }
                .buttonStyle(CustomWorkoutSheetRoundStyle())
                .accessibilityLabel(localization.string("Done"))
            }
            .frame(minHeight: ZOSpace.rowMinHeight)
            MoveKitVideoPlayer(exercise: exercise)
                .frame(maxWidth: .infinity)
                .aspectRatio(1936.0 / 1072.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: .continuous))
            Text(verbatim: "\(exercise.muscleFocus) · \(exercise.equipment)")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            Text(localization.string("Movement preview only. Follow your workout for sets, reps, and load."))
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ZOSpace.screenMargin)
        .background(theme.surfacePrimary)
        .onAppear { titleFocused = true }
    }
}

actor CustomWorkoutPosterStore {
    static let shared = CustomWorkoutPosterStore()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    func image(for resource: String, maxPixel: Int) -> UIImage? {
        guard maxPixel > 0 else { return nil }
        let key = "\(resource):\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        guard let url = Bundle.main.url(forResource: resource, withExtension: "jpg", subdirectory: "ExerciseVideos")
                ?? Bundle.main.url(forResource: resource, withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
              ) else { return nil }

        let image = UIImage(cgImage: thumbnail)
        cache.setObject(image, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
        return image
    }
}

import SwiftUI
import Observation

// The fixed list is also the stable tie-breaker. Only the three promoted positions move.
enum MainActionID: String, CaseIterable, Codable, Hashable {
    case workout, walk, water, meal, steps, music, assistant

    static let defaultTop: [Self] = [.workout, .water, .meal, .steps, .walk, .music, .assistant]

    var title: String {
        switch self {
        case .workout: "Workout"
        case .walk: "Walk or run"
        case .water: "Water"
        case .meal: "Meals"
        case .steps: "Steps"
        case .music: "Music"
        case .assistant: "Assistant"
        }
    }
}

struct MainActionUseEvent: Codable, Equatable {
    let id: UUID
    let action: MainActionID
    let date: Date
    let waterMilliliters: Int?
}

struct MainActionResetSnapshot {
    let uses: [MainActionUseEvent]
    let priorTop: [MainActionID]
}

struct MainActionPresentation {
    let top: [MainActionID]
    let isFirstUse: Bool
    let showsHoldChoice: Bool
    let showsAssistantNote: Bool
    let heading: String
}

struct MainActionAssistantNote {
    // Supply only for a genuinely paused session with a real, reviewable proposal.
    let sessionID: UUID
    let title: String
    let detail: String
    let actionTitle: String
    let onReview: () -> Void
}

private struct MainActionSavedState: Codable {
    var uses: [MainActionUseEvent] = []
    var pins: [MainActionID] = []
    var orderByUse = true
    var priorTop: [MainActionID] = []
    var openCount = 0
    var holdEnabled = false
    var holdChoiceMade = false
    var holdPromptOpens = 0
    var assistantNoteImpressions: [String: Int] = [:]
}

/// Local-only Study 12 ordering and preferences. The host records destination openings,
/// confirmed activity starts and meal saves across all entry points. Water receipts are
/// deduplicated across host and panel. Opening the panel or a logging form is not a use.
@MainActor
@Observable
final class MainActionStore {
    static let storageKey = "01.mainAction.study12.state"
    static let holdKey = "01.mainAction.holdEnabled"
    static let useWindow: TimeInterval = 14 * 24 * 60 * 60

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private var waterUseIDs: [HydrationQuickLogReceipt: UUID] = [:]
    @ObservationIgnored private var undoneUseIDs: Set<UUID> = []
    private var saved: MainActionSavedState

    init(defaults: UserDefaults = .standard, storageKey: String = "01.mainAction.study12.state") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let restored = try? JSONDecoder().decode(MainActionSavedState.self, from: data) {
            saved = restored
        } else {
            saved = MainActionSavedState()
        }
        var seen: Set<MainActionID> = []
        saved.pins = Array(saved.pins.filter { seen.insert($0).inserted }.prefix(3))
        if defaults.object(forKey: Self.holdKey) != nil {
            saved.holdEnabled = defaults.bool(forKey: Self.holdKey)
            saved.holdChoiceMade = true
        }
    }

    var pins: [MainActionID] { saved.pins }
    var orderByUse: Bool { saved.orderByUse }
    var holdEnabled: Bool { saved.holdEnabled }
    var holdChoiceMade: Bool { saved.holdChoiceMade }

    func count(for action: MainActionID, at date: Date = .now) -> Int {
        recentUses(at: date).filter { $0.action == action }.count
    }

    @discardableResult
    func recordUse(_ action: MainActionID, at date: Date = .now, waterMilliliters: Int? = nil) -> UUID {
        let event = MainActionUseEvent(id: UUID(), action: action, date: date, waterMilliliters: waterMilliliters)
        // A backdated event or clock correction must not erase newer uses.
        // Ranking still excludes future dates relative to its own evaluation time.
        let start = date.addingTimeInterval(-Self.useWindow)
        saved.uses = saved.uses.filter { $0.date >= start } + [event]
        persist()
        return event.id
    }

    func undoUse(_ id: UUID) {
        undoneUseIDs.insert(id)
        saved.uses.removeAll { $0.id == id }
        persist()
    }

    /// A saved meal keeps its ID so deletion can remove its use even after a relaunch.
    /// Loading or editing an existing meal must not call this method.
    func recordConfirmedMealUse(_ entry: NutritionEntry, at date: Date = .now) {
        guard !saved.uses.contains(where: { $0.id == entry.id }),
              !undoneUseIDs.contains(entry.id) else { return }
        let start = date.addingTimeInterval(-Self.useWindow)
        saved.uses = saved.uses.filter { $0.date >= start } + [
            MainActionUseEvent(id: entry.id, action: .meal, date: date, waterMilliliters: nil)
        ]
        persist()
    }

    @discardableResult
    func recordConfirmedWaterUse(_ receipt: HydrationQuickLogReceipt) -> UUID {
        if let existing = waterUseIDs[receipt] { return existing }
        let amount = receipt.savedMilliliters.subtractingReportingOverflow(receipt.previousMilliliters)
        let id = recordUse(.water, at: receipt.date, waterMilliliters: !amount.overflow && amount.partialValue > 0 ? amount.partialValue : nil)
        waterUseIDs[receipt] = id
        return id
    }

    /// Call only after the hydration store confirms the corresponding Undo.
    func undoConfirmedWaterUse(_ receipt: HydrationQuickLogReceipt) {
        guard let id = waterUseIDs.removeValue(forKey: receipt) else { return }
        undoUse(id)
    }

    func usualWaterMilliliters(at date: Date = .now) -> Int {
        let amounts = recentUses(at: date).compactMap { event -> Int? in
            guard event.action == .water, let amount = event.waterMilliliters, amount > 0 else { return nil }
            return amount
        }
        let counts = Dictionary(grouping: amounts, by: { $0 }).mapValues(\.count)
        // Prototype uses the most frequent logged amount, smaller amount on ties.
        return counts.keys.sorted {
            counts[$0, default: 0] == counts[$1, default: 0]
                ? $0 < $1 : counts[$0, default: 0] > counts[$1, default: 0]
        }.first ?? 250
    }

    func setOrderByUse(_ enabled: Bool) {
        saved.orderByUse = enabled
        persist()
    }

    @discardableResult
    func togglePin(_ action: MainActionID) -> Bool {
        if let index = saved.pins.firstIndex(of: action) {
            saved.pins.remove(at: index)
        } else {
            guard saved.pins.count < 3 else { return false }
            saved.pins.append(action)
        }
        persist()
        return true
    }

    func setHoldEnabled(_ enabled: Bool) {
        saved.holdEnabled = enabled
        defaults.set(enabled, forKey: Self.holdKey)
        saved.holdChoiceMade = true
        persist()
    }

    @discardableResult
    func resetUses() -> MainActionResetSnapshot {
        let backup = MainActionResetSnapshot(uses: saved.uses, priorTop: saved.priorTop)
        saved.uses = []
        saved.priorTop = []
        persist()
        return backup
    }

    func restoreUses(_ backup: MainActionResetSnapshot, at date: Date = .now) {
        let currentIDs = Set(saved.uses.map(\.id))
        let combined = backup.uses.filter {
            !currentIDs.contains($0.id) && !undoneUseIDs.contains($0.id)
        } + saved.uses
        let start = date.addingTimeInterval(-Self.useWindow)
        saved.uses = combined.filter { $0.date >= start && $0.date <= date }
        saved.priorTop = backup.priorTop
        persist()
    }

    func preview(
        available: Set<MainActionID>,
        active: MainActionID?,
        assistantNoteSessionID: UUID? = nil,
        supportsHold: Bool = false,
        at date: Date = .now
    ) -> MainActionPresentation {
        let counts = Dictionary(grouping: recentUses(at: date), by: \.action).mapValues(\.count)
        let learned = saved.orderByUse && counts.contains { available.contains($0.key) && $0.value >= 2 }
        let first = saved.openCount == 0 && counts.isEmpty && active == nil
        return MainActionPresentation(
            top: rank(available: available, active: active, counts: counts),
            isFirstUse: first,
            showsHoldChoice: supportsHold && !saved.holdChoiceMade && saved.holdPromptOpens < 3,
            showsAssistantNote: assistantNoteSessionID.map {
                saved.assistantNoteImpressions[$0.uuidString, default: 0] < 2
            } ?? false,
            heading: !saved.orderByUse ? (saved.pins.contains(where: available.contains) ? "Pinned" : "Quick access")
                : learned ? "Most used" : "Start here"
        )
    }

    // Called once for each actual opening. The returned snapshot stays fixed while the panel is open.
    func beginOpen(
        available: Set<MainActionID>,
        active: MainActionID?,
        assistantNoteSessionID: UUID? = nil,
        supportsHold: Bool = false,
        at date: Date = .now
    ) -> MainActionPresentation {
        let result = preview(
            available: available, active: active,
            assistantNoteSessionID: assistantNoteSessionID, supportsHold: supportsHold, at: date
        )
        saved.openCount += 1
        saved.priorTop = result.top
        if result.showsHoldChoice { saved.holdPromptOpens += 1 }
        if result.showsAssistantNote, let id = assistantNoteSessionID {
            saved.assistantNoteImpressions[id.uuidString, default: 0] += 1
        }
        saved.uses = recentUses(at: date)
        persist()
        return result
    }

    private func rank(
        available: Set<MainActionID>, active: MainActionID?, counts: [MainActionID: Int]
    ) -> [MainActionID] {
        var result: [MainActionID] = []
        if let active, available.contains(active) { result.append(active) }
        for pin in saved.pins where available.contains(pin) && !result.contains(pin) {
            if result.count < 3 { result.append(pin) }
        }
        let free = 3 - result.count
        if free > 0 && saved.orderByUse {
            let eligible = MainActionID.defaultTop
                .filter { available.contains($0) && !result.contains($0) && counts[$0, default: 0] >= 2 }
                .sorted { comesBefore($0, $1, counts: counts) }
            var chosen = Array(eligible.prefix(free))
            for incumbent in saved.priorTop where eligible.contains(incumbent) && !chosen.contains(incumbent) {
                if let index = chosen.indices.first(where: {
                    let challenger = chosen[$0]
                    return !saved.priorTop.contains(challenger)
                        && counts[challenger, default: 0] < counts[incumbent, default: 0] + 2
                }) {
                    chosen[index] = incumbent
                }
            }
            chosen.sort { comesBefore($0, $1, counts: counts) }
            for action in chosen where result.count < 3 && !result.contains(action) { result.append(action) }
        }
        for action in MainActionID.defaultTop where available.contains(action) && result.count < 3 && !result.contains(action) {
            result.append(action)
        }
        return result
    }

    private func comesBefore(
        _ left: MainActionID, _ right: MainActionID, counts: [MainActionID: Int]
    ) -> Bool {
        let leftCount = counts[left, default: 0], rightCount = counts[right, default: 0]
        return leftCount == rightCount
            ? (MainActionID.allCases.firstIndex(of: left) ?? Int.max)
                < (MainActionID.allCases.firstIndex(of: right) ?? Int.max)
            : leftCount > rightCount
    }

    private func recentUses(at date: Date) -> [MainActionUseEvent] {
        let start = date.addingTimeInterval(-Self.useWindow)
        return saved.uses.filter { $0.date >= start && $0.date <= date }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

struct MainActionControl: View {
    let action: () -> Void
    var size: CGFloat = 60
    var hasActivity = false
    var onHoldAssistant: (() -> Void)? = nil
    var actionStore: MainActionStore? = nil
    // Opt-in only: callers without these hooks retain the existing hold and AX behavior.
    var onContinuousHold: ((MainActionHoldEvent) -> Void)? = nil
    var holdCoordinateSpace: String = "rootVoiceHold"
    var onHoldBoundsChange: ((CGRect) -> Void)? = nil
    var onVoiceAccessibilityToggle: (() -> Void)? = nil
    var voiceAccessibilityValue = ""
    var continuousHoldEnabled = false
    var voiceDockPresented = false
    var voiceIsListening = false
    var voiceIsCapturing = false
    var voiceIsOverCancel = false
    var voiceVisualOffset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.zeroOneTheme) private var theme
    @AppStorage("01.mainAction.holdEnabled") private var holdEnabled = false
    @State private var didHandleHold = false
    @State private var showHoldRing = false
    @State private var holdProgress: CGFloat = 0
    @State private var ringDelay: Task<Void, Never>?
    @State private var localStore = MainActionStore()
    @State private var continuousHoldID: UUID?
    @GestureState private var continuousGestureActive = false

    private var store: MainActionStore { actionStore ?? localStore }

    @ViewBuilder
    var body: some View {
        if onHoldAssistant != nil {
            control
                .accessibilityAction(named: Text("Open 01 Assistant")) {
                    onHoldAssistant?()
                }
        } else {
            control
        }
    }

    @ViewBuilder
    private var control: some View {
        if (holdEnabled || continuousHoldEnabled) && onContinuousHold != nil {
            buttonBase
                .highPriorityGesture(continuousHoldGesture)
                .accessibilityHint(voiceDockPresented
                    ? "Double tap to begin, then double tap again to stop and review. Use Cancel voice request to discard."
                    : "Tap for actions, or hold for the Assistant.")
                .onChange(of: continuousGestureActive) { _, active in
                    // Contact begins before the .5-second threshold; a fresh short
                    // tap must not inherit consumption from an earlier held release.
                    if active { didHandleHold = false; return }
                    guard !active else { return }
                    cancelHoldPresentation()
                    guard let id = continuousHoldID else { return }
                    // A normal onEnded consumes the ID before the deferred fallback.
                    Task { @MainActor in
                        await Task.yield()
                        guard continuousHoldID == id, !continuousGestureActive else { return }
                        cancelContinuousHold()
                    }
                }
        } else if holdEnabled && onHoldAssistant != nil {
            buttonBase
                .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 22, pressing: { pressing in
                    ringDelay?.cancel()
                    if pressing {
                        didHandleHold = false
                        ringDelay = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            guard !Task.isCancelled else { return }
                            showHoldRing = true
                            withAnimation(reduceMotion ? nil : .linear(duration: 0.35)) { holdProgress = 1 }
                        }
                    } else {
                        showHoldRing = false
                        holdProgress = 0
                    }
                }, perform: {
                    guard scenePhase == .active, let onHoldAssistant else { return }
                    ringDelay?.cancel()
                    showHoldRing = false
                    holdProgress = 0
                    didHandleHold = true
                    onHoldAssistant()
                })
                .accessibilityHint("Tap for actions, or hold for the Assistant.")
        } else {
            buttonBase
                .accessibilityHint(hasActivity
                    ? "An activity is in progress. Opens quick actions."
                    : "Opens quick actions.")
        }
    }

    private var buttonBase: some View {
        Button {
            guard !didHandleHold else { didHandleHold = false; return }
            if voiceDockPresented { onVoiceAccessibilityToggle?() }
            else { action() }
        } label: {
            ZStack {
                Image("ZeroOneWordmark")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: size * 0.45, height: size * 0.45)
                    .opacity(voiceDockPresented ? 0 : 1)
                RootVoiceMark(size: 26, isListening: false)
                    .frame(width: 26, height: 26)
                    .opacity(voiceDockPresented ? 1 : 0)
            }
                .foregroundStyle(theme.backgroundPrimary)
                .frame(width: size, height: size)
                .background(theme.textPrimary, in: Circle())
                .background {
                    Circle().fill(theme.textPrimary.opacity(voiceIsCapturing ? 0.10 : 0))
                        .padding(-6)
                        .allowsHitTesting(false)
                }
                .opacity(voiceIsOverCancel ? 0.5 : 1)
                .overlay(alignment: .topTrailing) {
                    if hasActivity && !voiceDockPresented {
                        Circle()
                            .fill(theme.accentFill)
                            .frame(width: 10, height: 10)
                            .overlay { Circle().stroke(theme.backgroundPrimary, lineWidth: 2) }
                            .offset(x: 2, y: -2)
                            .accessibilityHidden(true)
                    }
                }
                .overlay {
                    if showHoldRing {
                        Circle()
                            .trim(from: 0, to: holdProgress)
                            .stroke(theme.textPrimary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .padding(-5)
                            .rotationEffect(.degrees(-90))
                            .transition(.opacity)
                            .accessibilityHidden(true)
                    }
                }
                // Only the circle decoration moves. The original Button and its
                // gesture frame retain the same identity and global touch ownership.
                .offset(y: voiceDockPresented ? voiceVisualOffset : 0)
        }
        .buttonStyle(ZOPressStyle(motionEnabled: !reduceMotion && !voiceDockPresented))
        .accessibilityLabel(voiceDockPresented ? "Push to talk" : "Open 01 quick actions")
        .accessibilityValue(voiceDockPresented ? voiceAccessibilityValue : "")
        .accessibilityIdentifier("mainAction.open")
        .accessibilityAction {
            if voiceDockPresented { onVoiceAccessibilityToggle?() }
            else { action() }
        }
        .accessibilityActions {
            if voiceDockPresented, let onVoiceAccessibilityToggle {
                Button("Start or stop voice request", action: onVoiceAccessibilityToggle)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { onHoldBoundsChange?(geometry.frame(in: .global)) }
                    .onChange(of: geometry.frame(in: .global)) { _, bounds in
                        onHoldBoundsChange?(bounds)
                    }
            }
            .allowsHitTesting(false)
        }
        .onDisappear { cancelHoldPresentation(); cancelContinuousHold() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelHoldPresentation(); cancelContinuousHold() }
        }
    }

    private var continuousHoldGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5, maximumDistance: 22)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($continuousGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                switch value {
                case .first(true):
                    if ringDelay == nil {
                        didHandleHold = false
                        ringDelay = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            guard !Task.isCancelled else { return }
                            showHoldRing = true
                            withAnimation(reduceMotion ? nil : .linear(duration: 0.35)) { holdProgress = 1 }
                        }
                    }
                case let .second(true, drag):
                    guard scenePhase == .active else { cancelContinuousHold(); return }
                    if continuousHoldID == nil {
                        let id = UUID()
                        continuousHoldID = id
                        // Consume any Button activation delivered for this held touch.
                        didHandleHold = true
                        cancelHoldPresentation()
                        onContinuousHold?(.began(id))
                    }
                    if let id = continuousHoldID, let drag {
                        onContinuousHold?(.moved(id, drag.location))
                    }
                default: break
                }
            }
            .onEnded { value in
                cancelHoldPresentation()
                guard let id = continuousHoldID else { return }
                continuousHoldID = nil
                if case let .second(true, drag) = value {
                    onContinuousHold?(.ended(id, drag?.location))
                } else {
                    onContinuousHold?(.cancelled(id))
                }
            }
    }

    private func cancelContinuousHold() {
        cancelHoldPresentation()
        guard let id = continuousHoldID else { return }
        continuousHoldID = nil
        onContinuousHold?(.cancelled(id))
    }

    private func cancelHoldPresentation() {
        ringDelay?.cancel()
        ringDelay = nil
        showHoldRing = false
        holdProgress = 0
    }
}

struct MainActionSurfaceView: View {
    let workoutTitle: String
    let workoutInProgress: Bool
    let workoutIsReady: Bool
    let waterTotalMilliliters: Int
    let canLogWater: Bool
    let onPrimaryWorkout: () -> Void
    let onWorkoutLibrary: () -> Void
    let onAddWater: (Int) -> HydrationQuickLogReceipt?
    let onUndoWater: (HydrationQuickLogGroup) -> Bool
    let onOpenWater: () -> Void
    let onOpenDiets: () -> Void
    let onOpenHistory: () -> Void
    let onOpenAssistant: () -> Void
    let onDismiss: () -> Void

    // Each destination callback owns dismissal and routing, like the required callbacks.
    // A nil route remains visibly unavailable and cannot be activated.
    var onConfirmedWater: ((HydrationQuickLogGroup) -> Void)? = nil
    var onOpenWalkOrRun: (() -> Void)? = nil
    var onOpenSteps: (() -> Void)? = nil
    var onOpenMusic: (() -> Void)? = nil
    var activeAction: MainActionID? = nil
    var supportsHoldAssistant = false
    var assistantNote: MainActionAssistantNote? = nil
    var actionStore: MainActionStore? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.zeroOneTheme) private var theme
    @AccessibilityFocusState private var primaryActionFocused: Bool
    @State private var waterUndoGroup: HydrationQuickLogGroup?
    @State private var waterFeedback: String?
    @State private var rowsRevealed = false
    @State private var closeRevealed = false
    @State private var localStore = MainActionStore()
    @State private var frozenPresentation: MainActionPresentation?
    @State private var showsEditor = false
    @State private var resetBackup: MainActionResetSnapshot?

    private var usualWaterMilliliters: Int { store.usualWaterMilliliters() }

    private var store: MainActionStore { actionStore ?? localStore }
    private var availableActions: Set<MainActionID> {
        var actions: Set<MainActionID> = [.workout, .water, .meal, .assistant]
        if onOpenWalkOrRun != nil { actions.insert(.walk) }
        if onOpenSteps != nil { actions.insert(.steps) }
        if onOpenMusic != nil { actions.insert(.music) }
        return actions
    }
    private var currentActiveAction: MainActionID? {
        activeAction ?? (workoutInProgress ? .workout : nil)
    }
    private var presentation: MainActionPresentation {
        frozenPresentation ?? store.preview(
            available: availableActions, active: currentActiveAction,
            assistantNoteSessionID: assistantNote?.sessionID,
            supportsHold: supportsHoldAssistant
        )
    }

    private var usesStackedActions: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Button(action: onDismiss) {
                    Color.black.opacity(0.48)
                        .ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close quick actions")
                .transition(.opacity.animation(.easeOut(duration: reduceMotion ? 0.15 : 0.2)))

                VStack(spacing: 12) {
                    VStack(spacing: 0) {
                        Capsule()
                            .fill(theme.textTertiary.opacity(0.55))
                            .frame(width: 40, height: 4)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 16)
                                    .onEnded { value in
                                        guard value.translation.height >= 72,
                                              abs(value.translation.width) <= value.translation.height else { return }
                                        onDismiss()
                                    }
                            )
                            .accessibilityHidden(true)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 22) {
                                actionGrid
                                    .modifier(ActionRowEntrance(isVisible: rowsRevealed, delay: 0.12, reduceMotion: reduceMotion))
                                quickActions
                                    .modifier(ActionRowEntrance(isVisible: rowsRevealed, delay: 0.085, reduceMotion: reduceMotion))
                                if presentation.showsAssistantNote, let assistantNote {
                                    assistantNoteRow(assistantNote)
                                        .modifier(ActionRowEntrance(isVisible: rowsRevealed, delay: 0.065, reduceMotion: reduceMotion))
                                }
                                if waterUndoGroup == nil {
                                    primaryAction
                                        .modifier(ActionRowEntrance(isVisible: rowsRevealed, delay: 0.05, reduceMotion: reduceMotion))
                                }
                                if presentation.showsHoldChoice {
                                    holdChoiceRow
                                }
                                if resetBackup != nil {
                                    Button("Undo reset learned order") { undoReset() }
                                        .frame(minHeight: 44)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 8)
                            .padding(.bottom, 14)
                        }
                        .scrollIndicators(.hidden)
                        .defaultScrollAnchor(.top)
                    }
                    .frame(maxWidth: 540)
                    .frame(maxHeight: max(200, min(600, geometry.size.height - 84)))
                    .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

                    Button(action: onDismiss) {
                        ZStack {
                            Image("ZeroOneWordmark")
                                .resizable()
                                .renderingMode(.template)
                                .scaledToFit()
                                .frame(width: 27, height: 27)
                                .opacity(closeRevealed ? 0 : 1)
                            Image(systemName: "xmark")
                                .zoIcon(ZOIcon.row)
                                .opacity(closeRevealed ? 1 : 0)
                                .rotationEffect(.degrees(reduceMotion || closeRevealed ? 0 : -60))
                        }
                        .foregroundStyle(theme.backgroundPrimary)
                        .frame(width: 60, height: 60)
                        .background(theme.textPrimary, in: Circle())
                        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.18), value: closeRevealed)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close 01 quick actions")
                    .accessibilityIdentifier("mainAction.close")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 9)
                .frame(maxWidth: .infinity)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .opacity
                                .combined(with: .offset(y: 12)),
                            removal: .opacity
                                .combined(with: .offset(y: 8))
                        )
                )
            }
        }
        .onAppear {
            if frozenPresentation == nil {
                frozenPresentation = store.beginOpen(
                    available: availableActions, active: currentActiveAction,
                    assistantNoteSessionID: assistantNote?.sessionID,
                    supportsHold: supportsHoldAssistant
                )
            }
            primaryActionFocused = true
        }
        .accessibilityAction(.escape) { onDismiss() }
        .task {
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
            closeRevealed = true
            // Keep the revealed state independent of the accessibility setting.
            // The modifier suppresses motion; toggling it must not hide the rows.
            rowsRevealed = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("01 quick actions")
        .accessibilityIdentifier("mainAction.surface")
        .sheet(isPresented: $showsEditor, onDismiss: refreshEditedPresentation) {
            Group {
                editSheet
            }
            .zoSheet()
        }
    }

    private var actionGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("All actions")
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Edit") { showsEditor = true }
                    .zoText(.section)
                    .foregroundStyle(theme.textPrimary)
                    .frame(minHeight: 44)
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 10),
                    count: usesStackedActions ? 1 : 4
                ),
                spacing: 16
            ) {
                ForEach(MainActionID.allCases, id: \.self) { id in
                    gridAction(
                        id.title, symbol: symbol(for: id),
                        action: availableActions.contains(id) ? { performGridAction(id) } : nil,
                        showsActivity: currentActiveAction == id,
                        unavailableLabel: id == .music ? "Concept" : "Unavailable",
                        spokenHint: id == .meal ? "Opens Diets to add or review meals." : nil
                    )
                }
            }
            Button(action: onOpenHistory) {
                Label("Workout history", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .zoText(.label)
            .foregroundStyle(theme.textSecondary)
        }
    }

    private var primaryAction: some View {
        let id = presentation.top.first ?? .workout
        return Button(action: performPrimaryAction) {
            HStack(alignment: .center, spacing: 14) {
                ZOAppIcon(id == .workout ? "play.fill" : symbol(for: id), size: ZOIcon.row)
                    .frame(width: 42, height: 42)
                    .foregroundStyle(theme.accentFill)
                    .background(Color.black, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(primaryEyebrow(for: id))
                        .zoText(.caption)

                    Text(primaryTitle(for: id))
                        .zoText(.title)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(primaryDetail(for: id))
                        .zoText(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .zoIcon(ZOIcon.row)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.black)
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(theme.accentFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(id == .water && canLogWater && waterUndoGroup != nil)
        .accessibilityFocused($primaryActionFocused)
        .accessibilitySortPriority(3)
        .accessibilityHint(id == .water && canLogWater ? "Saves \(usualWaterMilliliters) milliliters locally and shows Undo." : "Opens \(id.title).")
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel(presentation.heading)
                Spacer()
                if presentation.isFirstUse && store.orderByUse {
                    Text("Learns as you go")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }
                .accessibilityAddTraits(.isHeader)
            if usesStackedActions {
                VStack(spacing: 10) { quickActionButtons }
            } else {
                HStack(spacing: 10) { quickActionButtons }
            }
            if let waterFeedback {
                VStack(alignment: .leading, spacing: 10) {
                    Text(waterFeedback)
                        .zoText(.section)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
                    if let waterUndoGroup {
                        if usesStackedActions {
                            VStack(alignment: .leading, spacing: 4) {
                                waterFeedbackActions(waterUndoGroup)
                            }
                        } else {
                            HStack(spacing: 12) {
                                waterFeedbackActions(waterUndoGroup)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityElement(children: .contain)
            }
        }
    }

    @ViewBuilder
    private var quickActionButtons: some View {
        ForEach(Array(presentation.top.dropFirst()), id: \.self) { id in
            quickTile(for: id)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .zoText(.section)
            .foregroundStyle(theme.textPrimary)
    }

    private func symbol(for id: MainActionID) -> String {
        switch id {
        case .workout: "dumbbell"
        case .walk: "01.jog"
        case .water: "drop"
        case .meal: "fork.knife"
        case .steps: "shoeprints.fill"
        case .music: "music.note"
        case .assistant: "bubble.left"
        }
    }

    private func primaryEyebrow(for id: MainActionID) -> String {
        if currentActiveAction == id { return "PICK UP WHERE YOU LEFT OFF" }
        return presentation.isFirstUse ? "START HERE" : "READY WHEN YOU ARE"
    }

    private func primaryTitle(for id: MainActionID) -> String {
        switch id {
        case .workout:
            return workoutInProgress ? "Resume \(workoutTitle)" : (workoutIsReady ? "Start a workout" : "Choose a workout")
        case .walk: return currentActiveAction == .walk ? "Return to your walk or run" : "Start a walk or run"
        case .water: return canLogWater ? "Log \(usualWaterMilliliters) ml" : "Open water"
        case .meal: return "Open meals"
        case .steps: return "See your steps"
        case .music: return "Open music"
        case .assistant: return "Ask 01 Assistant"
        }
    }

    private func primaryDetail(for id: MainActionID) -> String {
        switch id {
        case .workout: return workoutInProgress ? "Your workout is in progress" : "Open your workouts"
        case .walk: return currentActiveAction == .walk ? "Activity in progress" : "Choose a walk or run"
        case .water: return canLogWater ? "\(waterTotalMilliliters) ml today" : "Review in Diets"
        case .meal: return "Open Diets"
        case .steps: return "Open steps"
        case .music: return "Open music"
        case .assistant: return "Local guidance"
        }
    }

    private func performPrimaryAction() {
        let id = presentation.top.first ?? .workout
        if id == .workout {
            onPrimaryWorkout()
        } else if id == .water && canLogWater {
            logQuickWater()
        } else {
            performGridAction(id)
        }
    }

    private func performGridAction(_ id: MainActionID) {
        guard availableActions.contains(id) else { return }
        // The destination owns the real-use event. Opening a meal/activity form is not a save/start.
        switch id {
        case .workout: onWorkoutLibrary()
        case .walk: onOpenWalkOrRun?()
        case .water: onOpenWater()
        case .meal: onOpenDiets()
        case .steps: onOpenSteps?()
        case .music: onOpenMusic?()
        case .assistant: onOpenAssistant()
        }
    }

    @ViewBuilder
    private func quickTile(for id: MainActionID) -> some View {
        if id == .water && canLogWater {
            actionTile(
                "+\(usualWaterMilliliters) ml", detail: "\(waterTotalMilliliters) ml today", symbol: "drop.fill",
                enabled: waterUndoGroup == nil,
                spokenLabel: "Water: log \(usualWaterMilliliters) milliliters",
                spokenHint: waterUndoGroup == nil
                    ? "Saves locally and shows Undo. \(waterTotalMilliliters) milliliters today."
                    : "Review the saved entry, then choose Add another \(usualWaterMilliliters) ml.",
                action: logQuickWater
            )
        } else {
            actionTile(
                id.title, detail: id == .meal ? "Open Diets" : "Open \(id.title)",
                symbol: symbol(for: id),
                spokenHint: id == .meal ? "Opens Diets to add or review meals." : "Opens \(id.title)."
            ) { performGridAction(id) }
        }
    }

    private func assistantNoteRow(_ note: MainActionAssistantNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "bubble.left")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title).zoText(.section)
                Text(note.detail).zoText(.caption)
            }
            Spacer(minLength: 0)
            Button(note.actionTitle) {
                store.recordUse(.assistant)
                note.onReview()
            }
            .zoText(.section)
            .frame(minHeight: 44)
        }
        .foregroundStyle(theme.textPrimary)
        .accessibilityElement(children: .contain)
    }

    private var holdChoiceRow: some View {
        Toggle(isOn: Binding(
            get: { store.holdEnabled },
            set: { store.setHoldEnabled($0) }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Hold 01 for the Assistant").zoText(.section)
                Text("A tap still opens these actions.")
                    .zoText(.caption)
            }
        }
        .tint(theme.accentForeground)
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(theme.strokeSubtle).frame(height: 1) }
    }

    private var editSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Anything in progress comes first, then your pins, then recent uses. The full list never moves.")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                    Toggle("Order by use", isOn: Binding(
                        get: { store.orderByUse }, set: { store.setOrderByUse($0) }
                    ))
                    .tint(theme.accentForeground)
                    if supportsHoldAssistant {
                        Toggle("Hold 01 for the Assistant", isOn: Binding(
                            get: { store.holdEnabled }, set: { store.setHoldEnabled($0) }
                        ))
                        .tint(theme.accentForeground)
                    }
                    sectionLabel("Pin up to three")
                    ForEach(MainActionID.allCases, id: \.self) { id in
                        let isPinned = store.pins.contains(id)
                        Button {
                            _ = store.togglePin(id)
                        } label: {
                            HStack {
                                Text(id.title)
                                Spacer()
                                Text("\(store.count(for: id)) uses in 14 days")
                                    .foregroundStyle(theme.textSecondary)
                                Image(systemName: isPinned ? "pin.fill" : "pin")
                            }
                            .frame(minHeight: 44)
                        }
                        .disabled(!availableActions.contains(id) || (!isPinned && store.pins.count >= 3))
                        .accessibilityLabel("\(isPinned ? "Unpin" : "Pin") \(id.title), \(store.count(for: id)) uses in 14 days")
                    }
                    Button("Reset learned order", role: .destructive) {
                        resetBackup = store.resetUses()
                    }
                    .frame(minHeight: 44)
                    .disabled(resetBackup != nil)
                    if resetBackup != nil {
                        Button("Undo reset", action: undoReset)
                            .frame(minHeight: 44)
                    }
                    Text("Your changes apply when you close this editor. Actions stay in place while you use the panel.")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(20)
            }
            .background(theme.backgroundPrimary)
            .navigationTitle("Edit 01 actions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showsEditor = false }
                }
            }
        }
        .zeroOneTheme(theme)
        .presentationDetents([.large])
    }

    private func undoReset() {
        guard let resetBackup else { return }
        store.restoreUses(resetBackup)
        self.resetBackup = nil
    }

    private func refreshEditedPresentation() {
        // Explicit edits can refresh the frozen order. Do not count another opening
        // or consume another Assistant-note / hold-discovery impression.
        let updated = store.preview(
            available: availableActions, active: currentActiveAction,
            assistantNoteSessionID: assistantNote?.sessionID,
            supportsHold: supportsHoldAssistant
        )
        frozenPresentation = MainActionPresentation(
            top: updated.top,
            isFirstUse: presentation.isFirstUse,
            showsHoldChoice: presentation.showsHoldChoice,
            showsAssistantNote: presentation.showsAssistantNote,
            heading: updated.heading
        )
    }

    private func logQuickWater() {
        guard let receipt = onAddWater(usualWaterMilliliters) else {
            waterFeedback = "Water save could not be confirmed. Check your total before trying again."
            return
        }
        waterUndoGroup = waterUndoGroup?.appending(receipt) ?? HydrationQuickLogGroup(receipt)
        store.recordConfirmedWaterUse(receipt)
        waterFeedback = "+\(receipt.savedMilliliters - receipt.previousMilliliters) ml saved. \(receipt.savedMilliliters) ml today."
        if let group = waterUndoGroup, let onConfirmedWater {
            onConfirmedWater(group)
            onDismiss()
        }
    }

    @ViewBuilder
    private func waterFeedbackActions(_ group: HydrationQuickLogGroup) -> some View {
        Button("Undo \(group.addedMilliliters) ml") {
            if onUndoWater(group) {
                group.receipts.forEach { store.undoConfirmedWaterUse($0) }
                waterUndoGroup = nil
                waterFeedback = "\(group.addedMilliliters) ml undone."
            } else {
                waterUndoGroup = nil
                waterFeedback = "Undo could not be confirmed. Check your water total."
            }
        }
        .frame(minHeight: 44)

        Button("Add another \(usualWaterMilliliters) ml") {
            logQuickWater()
        }
            .frame(minHeight: 44)
            .disabled(!canLogWater)
    }

    private func gridAction(
        _ title: String,
        symbol: String,
        action: (() -> Void)?,
        showsActivity: Bool = false,
        unavailableLabel: String = "Unavailable",
        spokenHint: String? = nil
    ) -> some View {
        Button { action?() } label: {
            VStack(spacing: 6) {
                ZOAppIcon(symbol, size: ZOIcon.row)
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 52, height: 52)
                    .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if showsActivity {
                            Circle().fill(theme.accentFill).frame(width: 10, height: 10)
                                .offset(x: 3, y: -3)
                                .accessibilityHidden(true)
                        }
                    }
                Text(title)
                    .zoText(.caption)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if action == nil {
                    Text(unavailableLabel)
                        .zoText(.mini)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityLabel(action == nil ? "\(title), \(unavailableLabel)" : title)
        .accessibilityHint(
            action == nil ? "This quick action is not available." : (spokenHint ?? "Opens \(title).")
        )
    }

    private func actionTile(
        _ title: String,
        detail: String,
        symbol: String,
        enabled: Bool = true,
        spokenLabel: String? = nil,
        spokenHint: String = "Performs this action now.",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZOAppIcon(symbol, size: ZOIcon.row)
                    .frame(width: 42, height: 42)
                    .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .zoText(.section)
                    Text(detail)
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .padding(.horizontal, 10)
            .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(spokenLabel ?? title)
        .accessibilityHint(spokenHint)
    }

}

private struct ActionRowEntrance: ViewModifier {
    let isVisible: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || isVisible ? 1 : 0)
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: 0.12),
                value: isVisible
            )
    }
}


struct AssistantActionSurfaceView: View {
    let context: AssistantContext
    let options: [AssistantActionOption]
    let voiceCoordinator: VoiceAssistantCoordinator
    let onSelect: (AssistantActionID) -> Void
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var typedRequest = ""
    @State private var lastSubmittedRequest: String?
    @State private var showsVoice = false
    @State private var requestCameFromConfirmedSpeech: Bool
    @FocusState private var requestFieldIsFocused: Bool

    private let contextualPolicy = ContextualAssistantPolicy()
    private let startingPrompts = [
        "What should I do now?",
        "I only have 30 minutes",
        "Add 250 ml water"
    ]

    init(
        context: AssistantContext,
        options: [AssistantActionOption],
        voiceCoordinator: VoiceAssistantCoordinator,
        initialRequest: String? = nil,
        initialRequestCameFromConfirmedSpeech: Bool = false,
        onSelect: @escaping (AssistantActionID) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.context = context
        self.options = options
        self.voiceCoordinator = voiceCoordinator
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        _lastSubmittedRequest = State(initialValue: initialRequest)
        #if DEBUG
        _showsVoice = State(initialValue: ProcessInfo.processInfo.environment["ZERO_ONE_VOICE_REVIEW_STATE"] != nil)
        #endif
        _requestCameFromConfirmedSpeech = State(initialValue: initialRequestCameFromConfirmedSpeech)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.xl) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What would help?")
                            .zoText(.display)
                            .foregroundStyle(theme.textPrimary)
                            .accessibilityAddTraits(.isHeader)

                        Text("Choose an action, or ask for a suggestion.")
                            .zoText(.body)
                            .foregroundStyle(theme.textSecondary)
                    }

                    contextualResponse

                    typedRequestControl

                    DisclosureGroup("Speak a request", isExpanded: $showsVoice) {
                        AssistantPushToTalkSection(
                            coordinator: voiceCoordinator,
                            onConfirm: submitConfirmedSpeech
                        )
                        .padding(.top, ZOSpace.s)
                    }
                    .zoText(.section)
                    .foregroundStyle(theme.textPrimary)

                    DisclosureGroup("All actions") {
                      VStack(spacing: 1) {
                        ForEach(options) { option in
                            Button {
                                onSelect(option.id)
                            } label: {
                                actionLabel(option)
                                .padding(.horizontal, ZOSpace.l)
                                .padding(.vertical, ZOSpace.m)
                                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                                .background(theme.surfacePrimary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.title)
                            .accessibilityHint(option.detail)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: ZORadius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: ZORadius.card, style: .continuous)
                            .stroke(theme.strokeSubtle, lineWidth: 1)
                    }
                      .padding(.top, ZOSpace.s)
                    }
                    .zoText(.section)
                    .foregroundStyle(theme.textPrimary)

                    DisclosureGroup("How this works") {
                        Text("01 uses your saved plan and activity to suggest supported actions. It does not provide an AI chat in this beta. Requests show a proposal; you choose whether to carry it out.")
                            .zoText(.body)
                            .foregroundStyle(theme.textSecondary)
                            .padding(.top, ZOSpace.s)
                    }
                    .foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, ZOSpace.xl)
                .padding(.top, ZOSpace.s)
                .padding(.bottom, ZOSpace.x4)
            }
            .scrollIndicators(.hidden)
            .background(theme.backgroundPrimary)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        voiceCoordinator.reset()
                        onDismiss()
                        dismiss()
                    }
                }
            }
        }
        .onChange(of: showsVoice) { _, isExpanded in
            if !isExpanded { voiceCoordinator.reset() }
        }
        .onDisappear { voiceCoordinator.reset() }
    }

    private var response: ContextualAssistantResponse {
        lastSubmittedRequest.map { contextualPolicy.response(to: $0, context: context) }
            ?? contextualPolicy.currentStateResponse(for: context)
    }

    private var contextualResponse: some View {
        let response = self.response
        let display = AssistantResponseCopy(response: response, context: context, localization: localization)
        return VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text(verbatim: display.eyebrow)
                .zoText(.caption)

                .foregroundStyle(theme.textSecondary)

            if requestCameFromConfirmedSpeech {
                Label("Confirmed speech request", systemImage: "waveform")
                    .zoText(.caption).labelStyle(ZOIconLabelStyle())
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityLabel("Response to confirmed speech request")
            }

            Text(verbatim: display.title)
                .zoText(.title)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: display.detail)
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(display.actionTitle) {
                onSelect(response.action)
            }
            .buttonStyle(ZOButtonStyle(.primary))
            .accessibilityHint("Performs the action shown above.")
        }
        .padding(ZOSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: ZORadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ZORadius.card, style: .continuous)
                .stroke(theme.strokeSubtle, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var typedRequestControl: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("Your request")
                .zoText(.caption)

                .foregroundStyle(theme.textSecondary)

            HStack(alignment: .bottom, spacing: ZOSpace.s) {
                TextField("Type a request", text: $typedRequest, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($requestFieldIsFocused)
                    .zoText(.body)
                    .foregroundStyle(theme.textPrimary)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.send)
                    .onSubmit(submitTypedRequest)
                    .accessibilityLabel("Local Assistant request")

                Button(action: submitTypedRequest) {
                    Image(systemName: "arrow.up")
                        .zoIcon(ZOIcon.inline)
                        .foregroundStyle(theme.backgroundPrimary)
                        .frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget)
                        .background(theme.textPrimary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(typedRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(typedRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                .accessibilityLabel("Submit local request")
            }
            .padding(.leading, ZOSpace.m)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(theme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: ZORadius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ZORadius.control, style: .continuous)
                    .stroke(theme.strokeSubtle, lineWidth: 1)
            }

            ScrollView(.horizontal) {
                HStack(spacing: ZOSpace.s) {
                    ForEach(startingPrompts, id: \.self) { prompt in
                        Button(localization.string(prompt)) {
                            submit(prompt)
                        }
                        .buttonStyle(.plain)
                        .zoText(.caption)
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, ZOSpace.m)
                        .frame(minHeight: ZOSpace.hitTarget)
                        .background(theme.surfacePrimary)
                        .clipShape(Capsule())
                        .overlay {
                            Capsule().stroke(theme.strokeSubtle, lineWidth: 1)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func submitTypedRequest() {
        let request = typedRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        submit(request)
        typedRequest = ""
        requestFieldIsFocused = false
    }

    private func submit(_ request: String) {
        lastSubmittedRequest = request
        requestCameFromConfirmedSpeech = false
        voiceCoordinator.reset()
    }

    private func submitConfirmedSpeech(_ transcript: String) {
        lastSubmittedRequest = transcript
        requestCameFromConfirmedSpeech = true
        voiceCoordinator.reset()
    }

    @ViewBuilder
    private func actionLabel(_ option: AssistantActionOption) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: ZOSpace.s) {
                HStack {
                    actionIcon(option)
                    Spacer(minLength: ZOSpace.s)
                    actionDisclosure
                }

                actionCopy(option)
            }
        } else {
            HStack(spacing: ZOSpace.m) {
                actionIcon(option)
                actionCopy(option)
                Spacer(minLength: ZOSpace.s)
                actionDisclosure
            }
        }
    }

    private func actionIcon(_ option: AssistantActionOption) -> some View {
        Image(systemName: option.systemImage)
            .zoIcon(ZOIcon.row)
            .foregroundStyle(theme.textSecondary)
            .frame(width: 28)
    }

    private func actionCopy(_ option: AssistantActionOption) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(option.title)
                .zoText(.section)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(option.detail)
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionDisclosure: some View {
        Image(systemName: "arrow.up.right")
            .zoIcon(ZOIcon.inline)
            .foregroundStyle(theme.textTertiary)
    }
}

struct AssistantFeedbackBanner: View {
    let feedback: AssistantActionFeedback

    var body: some View {
        ZOBanner(message: feedback.message, symbol: symbol, kind: kind)
            .accessibilityLabel(feedback.message)
    }

    private var kind: ZOBanner.Kind {
        switch feedback.kind {
        case .success: .success
        case .information: .information
        case .unavailable: .warning
        }
    }

    private var symbol: String {
        switch feedback.kind {
        case .success: "checkmark"
        case .information: "arrow.turn.down.right"
        case .unavailable: "exclamationmark"
        }
    }
}

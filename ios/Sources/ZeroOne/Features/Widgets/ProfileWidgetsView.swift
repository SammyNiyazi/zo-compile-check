import SwiftUI

struct ProfileWidgetsView: View {
    let inputs: DailyWidgetInputs?
    var goals: DailyGoalsRepository? = nil
    var hydration: HydrationViewModel? = nil
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast
    private var secondary: Color { contrast == .increased ? theme.textPrimary : theme.textSecondary }
    @State private var kind: DailyWidgetSnapshot.Kind = .together
    @State private var size: DailyWidgetSize = .medium
    @State private var options = DailyWidgetOptions()
    @State private var sharedSetupReady = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your day,\nat a glance.")
                        .zoThemeText(.display)
                        .accessibilityAddTraits(.isHeader)
                    Text("Choose what stays in view. Your steps, calories and water, separately or together.")
                        .zoText(.body).foregroundStyle(secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 145), spacing: 10)], spacing: 10) {
                    ForEach(DailyWidgetSnapshot.Kind.allCases) { option in
                        Button {
                            withAnimation(reduceMotion ? nil : ZOMotion.crossfade()) {
                                kind = option
                                size = option.validSize(size)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Label(localization.string(option.title), systemImage: option.symbol).zoText(.section).labelStyle(ZOIconLabelStyle())
                                Text(localization.string(option == .together ? "Medium or large" : "Small or medium"))
                                    .zoText(.caption).foregroundStyle(secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                            .padding(12)
                            .background(theme.surfacePrimary, in: ZORadius.cardShape)
                            .overlay { ZORadius.cardShape.stroke(kind == option ? theme.textPrimary : theme.strokeSubtle, lineWidth: kind == option ? 2 : 1) }
                        }
                        .buttonStyle(ZOPressStyle())
                        .accessibilityAddTraits(kind == option ? .isSelected : [])
                    }
                }
                ZOSegmentedControl("Widget size", selection: $size, options: kind.sizes.map { size in ZOSegment(value: size, label: Text(localization.string(size.title))) })
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    DailyWidgetProfilePreview(kind: kind, size: size, options: options,
                                              snapshot: inputs?.snapshot(at: context.date), accent: theme.accentPreference, designTheme: theme.designTheme)
                }
                Text("Preview only. These controls do not log water or start a walk. Home Screen sizes depend on your iPhone.")
                    .zoText(.caption).foregroundStyle(secondary)
                DailyWidgetOptionsEditor(kind: kind, options: $options)
                if let goals { DailyGoalsEditor(repository: goals, hydration: hydration) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Add it to your Home Screen").zoThemeText(.title)
                    if !sharedSetupReady {
                        Label("Widget setup is still being completed for this build.", systemImage: "info.circle")
                            .zoText(.body).labelStyle(ZOIconLabelStyle()).foregroundStyle(secondary)
                    }
                    Text("1. Touch and hold an empty area of your Home Screen.\n2. Open the widget gallery and search for 01.\n3. Choose a widget and size, then add it.\n4. Touch and hold it and choose Edit Widget for its options.")
                        .zoText(.body).lineSpacing(7)
                    Text("The choices above let you explore the design. Set each installed widget's options in Edit Widget; 01 cannot place a widget for you.")
                        .zoText(.caption).foregroundStyle(secondary)
                }
                .padding(ZOSpace.l).background(theme.surfacePrimary, in: ZORadius.cardShape)
            }.padding(20)
        }
        .navigationTitle("Widgets").navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(theme.textPrimary)
        .zoThemeScreenSurface()
        .task {
            sharedSetupReady = Bundle.main.object(forInfoDictionaryKey: "01DailyWidgetsEnabled") as? Bool == true
                && FileDailyWidgetSnapshotStore().isAvailable
        }
    }
}

private struct DailyWidgetProfilePreview: View {
    let kind: DailyWidgetSnapshot.Kind
    let size: DailyWidgetSize
    let options: DailyWidgetOptions
    let snapshot: DailyWidgetSnapshot?
    let accent: AccentPreference
    var designTheme: ZOTheme = .core
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        DailyWidgetFace(kind: kind, size: size, options: options, snapshot: snapshot, accent: accent, language: localization.language, designTheme: designTheme) {
            VStack(spacing: 7) {
                DailyWidgetActionLabel(waterAmount: options.validatedWaterAmount,
                                      prominent: WidgetMetricProgress(metric: snapshot?.waterMilliliters, target: snapshot?.waterGoalMilliliters)?.reached != true,
                                      accent: accent, language: localization.language, designTheme: designTheme)
                if size == .medium && kind == .water {
                    DailyWidgetActionLabel(waterAmount: options.secondaryWaterAmount, prominent: false, accent: accent, language: localization.language, designTheme: designTheme)
                }
            }.accessibilityHidden(true)
        } walkAction: {
            DailyWidgetActionLabel(title: "Start walk", symbol: "figure.walk", accent: accent, language: localization.language, designTheme: designTheme).accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: size == .small ? 176 : 380, minHeight: height, idealHeight: height)
        .background(DailyWidgetPalette(dark: colorScheme == .dark, accent: accent, designTheme: designTheme).background)
        .compositingGroup().clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).stroke(.primary.opacity(0.12)) }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.format("%1$@ %2$@ widget preview", .text(localization.string(size.title)), .text(localization.string(kind.title))))
    }

    private var height: CGFloat {
        let base: CGFloat = size == .large ? 370 : size == .small ? 176 : 185
        return typeSize.isAccessibilitySize ? base * 1.4 : base
    }
}

private struct DailyWidgetOptionsEditor: View {
    let kind: DailyWidgetSnapshot.Kind
    @Binding var options: DailyWidgetOptions
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    private var secondary: Color { contrast == .increased ? theme.textPrimary : theme.textSecondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Make it yours").zoThemeText(.title)
            if kind == .together {
                ForEach(DailyWidgetMetric.allCases) { metric in
                    Toggle(localization.string(metric.title), isOn: Binding(
                        get: { options.included.contains(metric) },
                        set: { options.set(metric, included: $0) }
                    ))
                    .disabled(options.included.contains(metric) && options.included.count == 1)
                }
                Text("Keep at least one metric.").zoText(.caption).foregroundStyle(secondary)
            }
            if kind == .calories || (kind == .together && options.included.contains(.calories)) {
                Picker("Calories", selection: $options.calories) {
                    ForEach(DailyWidgetCalories.allCases) { Text(localization.string($0.title)).tag($0) }
                }
                Text("Eaten is what you log in 01. Burned is Apple Health active energy, not resting energy. They are never subtracted from each other.")
                    .zoText(.caption).foregroundStyle(secondary)
            }
            if kind == .water || (kind == .together && options.included.contains(.water)) {
                Picker("Quick-add water", selection: $options.waterAmount) {
                    Text("250 ml").tag(250); Text("500 ml").tag(500); Text("750 ml").tag(750)
                }
            }
            if kind == .steps || (kind == .together && options.included.contains(.steps)) {
                Toggle("Show Start walk", isOn: $options.showsWalk)
                Text("Opens 01 first. Location is requested only when you choose to start recording.")
                    .zoText(.caption).foregroundStyle(secondary)
            }
        }.pickerStyle(.menu).toggleStyle(ZOToggleStyle())
    }
}


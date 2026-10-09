import SwiftUI

struct AppleHealthConnectionView: View {
    @Bindable var healthConnection: HealthConnectionRepository
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.calendar) private var calendar
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                permissionArtwork
                Text(LocalizedStringKey(statusTitle)).zoThemeText(.title).accessibilityAddTraits(.isHeader)
                Text(LocalizedStringKey(statusMessage)).zoText(.body).foregroundStyle(theme.textSecondary)
                if healthConnection.status == .connected { connectedContent(now: timeline.date) }
                if let issue = healthConnection.issue {
                    Text(localization.string(issue.message)).zoText(.body).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label("Private by design", systemImage: "lock").zoText(.section).labelStyle(ZOIconLabelStyle())
                Text("01 requests read access only. Health data stays on this iPhone and is not sent to a server, analytics service, or 01-controlled backup.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, ZOSpace.xl).padding(.vertical, ZOSpace.l)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            primaryAction.padding(.horizontal, ZOSpace.xl).padding(.vertical, ZOSpace.m).background(theme.backgroundPrimary)
        }
        .zoThemeScreenSurface()
        .background(theme.backgroundPrimary.ignoresSafeArea())
        .foregroundStyle(theme.textPrimary)
        .navigationTitle("Apple Health").navigationBarTitleDisplayMode(.inline)
        .task { await healthConnection.refreshIfConnected() }
    }

    private var permissionArtwork: some View {
        VStack(spacing: 20) {
            // Actual foundation access is Health -> 01, with no write scope.
            HStack(spacing: 14) {
                ZOAppIcon("heart", size: 32).foregroundStyle(artOnyx).frame(width: 72, height: 72)
                    .background(artInk, in: RoundedRectangle(cornerRadius: 18))
                ZOAppIcon("arrow.right", size: 24).foregroundStyle(Color(zoHex: 0xB5B4B1))
                Image("ZeroOneWordmark").resizable().renderingMode(.template).scaledToFit()
                    .foregroundStyle(artOnyx).frame(width: 34, height: 34).frame(width: 72, height: 72)
                    .background(artSignal, in: RoundedRectangle(cornerRadius: 18))
            }.accessibilityHidden(true)
            HealthReadScopeFlow(spacing: 8) {
                ForEach([HealthReadDataType.stepCount, .sleepAnalysis, .bodyMass, .height, .workouts, .activeEnergy, .distanceWalkingRunning], id: \.self) { type in
                    HStack(spacing: 6) {
                        ZOAppIcon(symbol(for: type), size: 16).foregroundStyle(artSignal).accessibilityHidden(true)
                        Text(LocalizedStringKey(permissionTitle(for: type)))
                            .zoProofText(.caption, size: 13, lineHeight: 18, weight: 600)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(minHeight: 34)
                    .foregroundStyle(artInk)
                    .background(artInk.opacity(0.10), in: RoundedRectangle(cornerRadius: 17))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 20)
        .background(artOnyx, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            if theme.colorScheme == .dark {
                RoundedRectangle(cornerRadius: 20).strokeBorder(Color(zoHex: 0x2D2D2B), lineWidth: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func connectedContent(now: Date) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.l) {
            Text("Manage read access in the Health app: open your profile, choose Apps, then 01. Completing setup does not mean every permission is enabled.")
                .zoText(.body).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Available context").zoText(.section)
                Spacer()
                if healthConnection.isRefreshing { ProgressView().accessibilityLabel("Refreshing Apple Health") }
            }
            if let context = healthConnection.context {
                let sleep = HealthSleepPresentation(context: context, status: healthConnection.status,
                    isStale: healthConnection.isContextStale, now: now, calendar: calendar)
                if !sleep.isCurrent {
                    Text(localization.format("Last available context · %1$@", .text(context.refreshedAt.formatted(
                        .dateTime.day().month(.abbreviated).hour().minute().locale(localization.locale)))))
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                }
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())]
                          : [GridItem(.flexible()), GridItem(.flexible())], spacing: ZOSpace.l) {
                    healthValue(sleep.isCurrent ? "Steps today" : "Last available steps", value: formattedValue(context.todaySteps, unit: nil))
                    healthValue(sleep.isCurrent ? "Active energy" : "Last available active energy", value: formattedValue(context.todayActiveEnergyKilocalories, unit: "kcal"))
                    healthValue("Last workout", value: context.mostRecentWorkout?.activityName ?? localization.string("No data available"))
                    healthValue(sleep.periodKey, value: sleep.duration.map {
                        localization.format("%1$@ hr", .text(($0 / 3_600).formatted(.number.precision(.fractionLength(1)).locale(localization.locale))))
                    } ?? localization.string("No data available"))
                }
            } else {
                Text("No readable data is currently available for these metrics. Apple Health controls which data 01 can see.")
                    .zoText(.body).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch healthConnection.status {
        case .notConnected:
            VStack(spacing: ZOSpace.xs) {
                Button("Connect Apple Health") { Task { await healthConnection.connect() } }
                    .buttonStyle(ZOButtonStyle(.primary)).accessibilityHint("Opens the Apple Health read-access request.")
                Button("Not now") { dismiss() }.frame(minHeight: 44).buttonStyle(.plain)
            }
        case .connecting:
            Button("Connecting") {}.buttonStyle(ZOButtonStyle(.primary)).disabled(true)
                .accessibilityLabel("Connecting to Apple Health")
        case .connected:
            Button("Refresh available data") { Task { await healthConnection.refresh() } }
                .buttonStyle(ZOButtonStyle(.secondary)).disabled(healthConnection.isRefreshing)
        case .unavailable:
            Button("Apple Health unavailable") {}.buttonStyle(ZOButtonStyle(.secondary)).disabled(true)
        }
    }

    private func healthValue(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text(LocalizedStringKey(label)).zoText(.caption).foregroundStyle(theme.textSecondary)
            Text(value).zoText(.section).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        switch healthConnection.status {
        case .notConnected: "One question for Apple Health"
        case .connecting: "Choose what 01 can read."
        case .connected: "Apple Health setup is complete."
        case .unavailable: "Apple Health is not available here."
        }
    }
    private var statusMessage: String {
        switch healthConnection.status {
        case .notConnected: "01 reads these to fill your day and your progress. Nothing leaves this iPhone."
        case .connecting: "The system sheet controls every permission. 01 never requests write access."
        case .connected: "Setup completed. Apple Health still controls which read samples 01 can see."
        case .unavailable: "This device cannot provide HealthKit data. All current offline beta flows remain available."
        }
    }
    private var artInk: Color { Color(zoHex: 0xF7F6F1) }
    private var artOnyx: Color { Color(zoHex: 0x020202) }
    private var artSignal: Color { Color(zoHex: 0xFFFE2A) }
    private func permissionTitle(for type: HealthReadDataType) -> String {
        switch type {
        case .stepCount: "Steps"
        case .sleepAnalysis: "Sleep"
        case .bodyMass: "Weight"
        case .height: "Height"
        case .workouts: "Workouts"
        case .activeEnergy: "Energy"
        case .distanceWalkingRunning: "Distance"
        }
    }
    private func symbol(for type: HealthReadDataType) -> String {
        switch type {
        case .stepCount: "shoeprints.fill"
        case .activeEnergy: "flame"
        case .workouts: "heart"
        case .sleepAnalysis: "moon"
        case .bodyMass: "scalemass"
        case .height: "ruler"
        case .distanceWalkingRunning: "01.jog"
        }
    }
    /// Fixed brand chips wrap within their actual proposal and grow vertically for large text.
    private struct HealthReadScopeFlow: Layout {
        let spacing: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = max(0, proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +))
            let measuredRows = rows(in: width, subviews: subviews)
            return CGSize(width: width, height: measuredRows.reduce(0) { $0 + $1.height }
                + CGFloat(max(0, measuredRows.count - 1)) * spacing)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var y = bounds.minY
            for row in rows(in: bounds.width, subviews: subviews) {
                var x = bounds.minX + (bounds.width - row.width) / 2
                for item in row.items {
                    subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                        anchor: .topLeading, proposal: ProposedViewSize(item.size))
                    x += item.size.width + spacing
                }
                y += row.height + spacing
            }
        }

        private struct Row {
            var items: [(index: Int, size: CGSize)] = []
            var width: CGFloat = 0
            var height: CGFloat = 0
        }

        private func rows(in width: CGFloat, subviews: Subviews) -> [Row] {
            var result: [Row] = []
            var row = Row()
            for index in subviews.indices {
                let natural = subviews[index].sizeThatFits(.unspecified)
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: min(natural.width, width), height: nil))
                if !row.items.isEmpty && row.width + spacing + size.width > width {
                    result.append(row); row = Row()
                }
                if !row.items.isEmpty { row.width += spacing }
                row.items.append((index, size)); row.width += size.width; row.height = max(row.height, size.height)
            }
            if !row.items.isEmpty { result.append(row) }
            return result
        }
    }

    private func formattedValue(_ value: Double?, unit: String?) -> String {
        guard let value, value.isFinite, value >= 0 else { return localization.string("No data available") }
        let number = value.formatted(.number.precision(.fractionLength(0)).locale(localization.locale))
        return unit.map { localization.format("%1$@ %2$@", .text(number), .text($0)) } ?? number
    }
}

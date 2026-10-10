import SwiftUI
import UIKit

/// Scan a barcode, then Found / Not found yet, then Photo of the label and Check
/// what it read (proof 54). Always dark, like every 01 camera.
struct FoodScanFlowView: View {
    @Bindable var model: FoodLogModel
    var startWithLabel = false
    let onAdded: ([NutritionEntry], FoodMeal) -> Void
    let onSearchInstead: () -> Void
    let onClose: () -> Void

    private enum Stage: Equatable { case barcode, label }
    private enum ScanResult: Identifiable, Equatable {
        case found(FoodItem), notFound(String)
        var id: String {
            switch self {
            case let .found(item): "found:" + item.id
            case let .notFound(code): "missing:" + code
            }
        }
    }

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage: Stage = .barcode
    @State private var cameraAllowed: Bool?
    @State private var recognised: String?
    @State private var isLooking = false
    @State private var result: ScanResult?
    @State private var message: String?
    @State private var typing = false
    @State private var typedNumber = ""
    @State private var labelBarcode: String?
    @State private var lines: [FoodDataScanner.TextLine] = []
    @State private var liveReading = NutritionLabelReading()
    @State private var captureRequest = 0
    @State private var isReading = false
    @State private var check: CheckItem?
    @State private var steadySince: Date?

    private struct CheckItem: Identifiable { let id = UUID(); let draft: FoodLabelDraft; let photo: UIImage? }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch cameraAllowed {
            case true?:
                if FoodDataScanner.isAvailable {
                    scanner.ignoresSafeArea()
                    overlay
                } else {
                    declined(unsupported: true)
                }
            case false?:
                declined(unsupported: false)
            case nil:
                ProgressView().tint(.white)
            }
        }
        .environment(\.colorScheme, .dark)
        .task {
            stage = startWithLabel ? .label : .barcode
            cameraAllowed = await FoodCameraAccess.request()
        }
        .sheet(item: $result, onDismiss: { recognised = nil }) { result in
            Group {
                switch result {
                case let .found(item):
                    FoodProductView(item: item, model: model, showsFoundBadge: true, onAdd: add, onClose: { self.result = nil })
                        .presentationDetents([.fraction(0.72), .large])
                case let .notFound(code):
                    notFound(code)
                        .presentationDetents([.fraction(0.5)])
                }
            }
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.disabled)
            .zeroOneTheme(theme)
            .preferredColorScheme(theme.colorScheme)
        }
        .sheet(item: $check) { check in
            FoodLabelCheckView(draft: check.draft, photo: check.photo) { item in
                model.saveToMyFoods(item)
                self.check = nil
                add(item, item.defaultAmount)
            } onCancel: { self.check = nil }
            .zeroOneTheme(theme)
            .preferredColorScheme(theme.colorScheme)
        }
        .alert(localization.string("Scan"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(localization.string("OK"), role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .alert(localization.string("Type the number"), isPresented: $typing) {
            TextField("5901234123457", text: $typedNumber).keyboardType(.numberPad)
            Button(localization.string("Look up")) { lookUp(typedNumber) }
            Button(localization.string("Cancel"), role: .cancel) {}
        } message: {
            Text("The digits under the barcode.")
        }
    }

    // MARK: Scanner

    private var scanner: some View {
        FoodDataScanner(mode: stage == .barcode ? .barcode : .label,
            isPaused: result != nil || check != nil || isLooking || isReading,
            captureRequest: captureRequest,
            onBarcode: { code in
                recognised = code
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                lookUp(code)
            },
            onText: { newLines in
                lines = newLines
                let reading = NutritionLabelParser.parse(lines: newLines.map { ($0.transcript, 1) })
                if reading.foundCount != liveReading.foundCount { steadySince = .now }
                liveReading = reading
                autoCaptureIfSteady()
            },
            onPhoto: readLabel)
        .id(stage)
    }

    @ViewBuilder private var overlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if stage == .barcode { barcodeFrame } else { labelChip }
            Spacer()
            bottomControls
        }
        .padding(.horizontal, ZOSpace.screenMargin)
        .padding(.bottom, ZOSpace.l)
        if stage == .label { labelBoxes.allowsHitTesting(false).ignoresSafeArea() }
    }

    private var topBar: some View {
        ZStack {
            Text(stage == .barcode ? "Scan a barcode" : "Nutrition label")
                .zoText(.section).foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button(action: onClose) { Image(systemName: "xmark").zoIcon(ZOIcon.row) }
                    .buttonStyle(ZOButtonStyle(.round))
                    .accessibilityLabel(Text(localization.string("Close")))
                Spacer()
            }
        }
        .padding(.top, ZOSpace.s)
    }

    private var barcodeFrame: some View {
        let found = recognised != nil
        return VStack(spacing: ZOSpace.l) {
            FoodScanCorners(radius: found ? 4 : 10)
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .frame(width: found ? 196 : 250, height: found ? 108 : 140)
                .animation(reduceMotion ? nil : .spring(duration: 0.24), value: found)
                .accessibilityElement()
                .accessibilityLabel(Text(localization.string(found ? "Barcode recognised" : "Barcode frame, point at the barcode")))
            chip(recognised.map { OpenFoodFactsClient.spacedBarcode($0) } ?? localization.string("Point at the barcode"),
                 busy: isLooking)
        }
        .frame(height: 220)
    }

    private var labelChip: some View {
        chip(localization.format(liveReading.foundCount == NutritionLabelReading.fieldCount ? "%1$lld of %2$lld found · hold still" : "%1$lld of %2$lld found",
                .integer(liveReading.foundCount), .integer(NutritionLabelReading.fieldCount)),
             busy: isReading, icon: liveReading.foundCount == NutritionLabelReading.fieldCount ? "checkmark" : nil)
            .padding(.top, 260)
    }

    private func chip(_ text: String, busy: Bool, icon: String? = nil) -> some View {
        HStack(spacing: ZOSpace.s) {
            if busy { ProgressView().controlSize(.small).tint(.white) }
            if let icon { Image(systemName: icon).zoIcon(ZOIcon.inline) }
            Text(text).zoText(.label).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, ZOSpace.m)
        .frame(minHeight: 36)
        .background(.black.opacity(0.55), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var labelBoxes: some View {
        let matched = Set(lines.filter { line in
            NutritionLabelParser.parse(lines: [(line.transcript, 1)]).foundCount > 0
        }.map(\.id))
        return Canvas { context, _ in
            for line in lines where matched.contains(line.id) && line.corners.count == 4 {
                var path = Path()
                path.addLines(line.corners)
                path.closeSubpath()
                context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
        }
    }

    @ViewBuilder private var bottomControls: some View {
        VStack(spacing: ZOSpace.m) {
            if stage == .barcode {
                HStack(spacing: ZOSpace.m) {
                    Button(localization.string("Search instead"), systemImage: "magnifyingglass", action: onSearchInstead)
                        .buttonStyle(ZOButtonStyle(.secondary))
                    Button(localization.string("Type the number")) { typedNumber = ""; typing = true }
                        .buttonStyle(ZOButtonStyle(.secondary))
                }
                Text("Read on this iPhone. Only the number is looked up.")
            } else {
                HStack {
                    Button(localization.string("Cancel")) { stage = .barcode; lines = []; liveReading = .init() }
                        .buttonStyle(ZOButtonStyle(.secondary))
                    Spacer()
                    Button { captureRequest += 1; isReading = true } label: {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                            .overlay(Circle().fill(.white).padding(6))
                    }
                    .buttonStyle(.plain)
                    .disabled(isReading)
                    .accessibilityLabel(Text(localization.string("Take the photo")))
                    Spacer()
                    Button(localization.string("Type it in")) { openCheck(FoodLabelDraft(reading: liveReading, barcode: labelBarcode), photo: nil) }
                        .buttonStyle(ZOButtonStyle(.secondary))
                }
                Text("Read on this iPhone. The photo stays here unless you share it.")
            }
        }
        .zoText(.caption)
        .foregroundStyle(.white.opacity(0.8))
        .multilineTextAlignment(.center)
    }

    // MARK: Results

    private func notFound(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text(OpenFoodFactsClient.spacedBarcode(code)).zoText(.caption).foregroundStyle(theme.textSecondary)
            Text("Not in the food database yet").zoText(.title).accessibilityAddTraits(.isHeader)
            Text("Take a photo of the nutrition label and 01 reads it for you. You check the numbers, and it's saved to your foods.")
                .zoText(.body).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(localization.string("Photo the label"), systemImage: "camera") {
                labelBarcode = code
                result = nil
                stage = .label
            }
            .buttonStyle(ZOButtonStyle(.primary))
            HStack(spacing: ZOSpace.m) {
                Button(localization.string("Type it in")) {
                    result = nil
                    openCheck(FoodLabelDraft(reading: NutritionLabelReading(), barcode: code), photo: nil)
                }
                .buttonStyle(ZOButtonStyle(.secondary))
                Button(localization.string("Search instead")) { result = nil; onSearchInstead() }
                    .buttonStyle(ZOButtonStyle(.secondary))
            }
        }
        .padding(ZOSpace.screenMargin)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surfacePrimary)
    }

    private func declined(unsupported: Bool) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Image(systemName: "camera").zoIcon(ZOIcon.feature).foregroundStyle(.white)
            Text(unsupported ? "This iPhone can't scan barcodes" : "Camera is off for 01")
                .zoText(.title).foregroundStyle(.white)
            Text(unsupported ? "You can type the number from under the barcode instead."
                 : "01 needs the camera to read a barcode or a label, on this iPhone. You can turn it on in Settings, or type the number.")
                .zoText(.body).foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Button(localization.string("Type the number")) { typedNumber = ""; typing = true }
                .buttonStyle(ZOButtonStyle(.primary))
            if !unsupported {
                Button(localization.string("Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(ZOButtonStyle(.secondary))
            }
            Button(localization.string("Close"), action: onClose).buttonStyle(ZOButtonStyle(.quiet))
        }
        .padding(ZOSpace.screenMargin)
        .frame(maxWidth: 520)
    }

    // MARK: Actions

    private func lookUp(_ raw: String) {
        guard !isLooking else { return }
        guard let code = OpenFoodFactsClient.normalizedBarcode(raw) else {
            message = localization.string("That isn't a barcode number. Check the digits under the bars.")
            return
        }
        isLooking = true
        Task {
            let outcome = await model.lookUp(barcode: code)
            isLooking = false
            switch outcome {
            case let .success(.found(item)): result = .found(item)
            case .success(.notFound), .success(.missingCalories): result = .notFound(code)
            case .failure(.offline):
                recognised = nil
                message = localization.string("No connection. Search your foods and basic foods instead, or try again.")
            case .failure:
                recognised = nil
                message = localization.string("Open Food Facts didn't answer. Try again in a moment.")
            }
        }
    }

    private func autoCaptureIfSteady() {
        guard stage == .label, !isReading, liveReading.foundCount == NutritionLabelReading.fieldCount,
              let since = steadySince, Date.now.timeIntervalSince(since) > 1 else { return }
        isReading = true
        captureRequest += 1
    }

    private func readLabel(_ photo: UIImage?) {
        guard let photo else {
            isReading = false
            message = localization.string("The photo couldn't be taken. Try again or type it in.")
            return
        }
        Task {
            let reading = await NutritionLabelReader.read(photo)
            isReading = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            openCheck(FoodLabelDraft(reading: reading, barcode: labelBarcode), photo: photo)
        }
    }

    private func openCheck(_ draft: FoodLabelDraft, photo: UIImage?) {
        check = CheckItem(draft: draft, photo: photo)
    }

    private func add(_ item: FoodItem, _ amount: Double) {
        do {
            let entry = try model.add(item, amount: amount)
            result = nil
            onAdded([entry], model.meal)
        } catch {
            message = localization.string("This food couldn't be saved. Check your meals before trying again.")
        }
    }
}

/// Four corner brackets of the barcode frame.
struct FoodScanCorners: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.22
        var path = Path()
        let r = min(radius, length / 2)
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0), (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * r))
            path.addQuadCurve(to: CGPoint(x: corner.x + dx * r, y: corner.y), control: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
        }
        return path
    }
}

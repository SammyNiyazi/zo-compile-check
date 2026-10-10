import AVFoundation
import ImageIO
import SwiftUI
import UIKit
import Vision
import VisionKit

/// VisionKit live scanner, barcodes (EAN-13, EAN-8, UPC-A, UPC-E) or label text.
/// Everything is read on this iPhone; only a barcode number is ever looked up.
struct FoodDataScanner: UIViewControllerRepresentable {
    enum Mode { case barcode, label }

    struct TextLine: Identifiable, Equatable {
        let id: UUID
        let transcript: String
        /// Corners in the scanner view's coordinates.
        let corners: [CGPoint]
    }

    let mode: Mode
    var isPaused = false
    var captureRequest = 0
    var onBarcode: (String) -> Void = { _ in }
    var onText: ([TextLine]) -> Void = { _ in }
    var onPhoto: (UIImage?) -> Void = { _ in }

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let types: Set<DataScannerViewController.RecognizedDataType> = mode == .barcode
            ? [.barcode(symbologies: [.ean13, .ean8, .upce])]
            : [.text()]
        let scanner = DataScannerViewController(recognizedDataTypes: types,
            qualityLevel: mode == .barcode ? .balanced : .accurate,
            recognizesMultipleItems: mode == .label, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: false, isHighlightingEnabled: false)
        scanner.delegate = context.coordinator
        scanner.view.backgroundColor = .black
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.parent = self
        if isPaused {
            if scanner.isScanning { scanner.stopScanning() }
        } else if !scanner.isScanning {
            try? scanner.startScanning()
        }
        if captureRequest != context.coordinator.lastCapture {
            context.coordinator.lastCapture = captureRequest
            Task { @MainActor in
                let photo = try? await scanner.capturePhoto()
                onPhoto(photo)
            }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: FoodDataScanner
        var lastCapture: Int
        private var reported: String?

        init(parent: FoodDataScanner) {
            self.parent = parent
            lastCapture = parent.captureRequest
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            handle(allItems)
        }

        func dataScanner(_ scanner: DataScannerViewController, didUpdate updated: [RecognizedItem], allItems: [RecognizedItem]) {
            handle(allItems)
        }

        func dataScanner(_ scanner: DataScannerViewController, didRemove removed: [RecognizedItem], allItems: [RecognizedItem]) {
            handle(allItems)
        }

        private func handle(_ items: [RecognizedItem]) {
            switch parent.mode {
            case .barcode:
                guard !parent.isPaused else { return }
                for item in items {
                    if case let .barcode(code) = item, let value = code.payloadStringValue,
                       let barcode = OpenFoodFactsClient.normalizedBarcode(value), barcode != reported {
                        reported = barcode
                        parent.onBarcode(barcode)
                        return
                    }
                }
            case .label:
                let lines: [TextLine] = items.compactMap { item in
                    guard case let .text(text) = item else { return nil }
                    let b = text.bounds
                    return TextLine(id: text.id, transcript: text.transcript,
                        corners: [b.topLeft, b.topRight, b.bottomRight, b.bottomLeft])
                }
                parent.onText(lines)
            }
        }

        /// A new scan of the same code after "Search instead" or a dismissed sheet.
        func reset() { reported = nil }
    }
}

/// Accurate text recognition on the captured still, with a confidence per line.
enum NutritionLabelReader {
    static func read(_ image: UIImage) async -> NutritionLabelReading {
        guard let cgImage = image.cgImage else { return NutritionLabelReading() }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.automaticallyDetectsLanguage = true
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
                try? handler.perform([request])
                let tokens: [NutritionLabelToken] = (request.results ?? []).compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let box = observation.boundingBox
                    return NutritionLabelToken(text: candidate.string,
                        box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
                        confidence: candidate.confidence)
                }
                continuation.resume(returning: NutritionLabelParser.parse(tokens))
            }
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

enum FoodCameraAccess {
    /// Asks once; a declined or restricted camera shows the declined-permission card.
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

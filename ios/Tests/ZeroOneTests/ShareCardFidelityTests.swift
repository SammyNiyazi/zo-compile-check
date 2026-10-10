import CoreText
import SwiftUI
import UIKit
import XCTest
@testable import ZeroOne

/// Native resource, pagination and print boundaries. Execution on Windows is UNRUN.
@MainActor
final class ShareCardFidelityTests: XCTestCase {
    func testPrintFontsUseActualVariableResourceAtFixedSizesAndWeights() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "InstrumentSans-Variable", withExtension: "ttf"))
        let sizes: [CGFloat] = [10.5 * 360 / 236, 30 * 360 / 236, 16 * 360 / 236,
                                11.5 * 360 / 236, 24, 11 * 360 / 236, 24.41, 17.55]
        for size in sizes {
            for weight in [CGFloat(500), 600, 700] {
                let font = SocialSharePrintTypography.font(size: size, weight: weight)
                XCTAssertEqual(CTFontGetSize(font), size, accuracy: 0.001)
                let actual = try XCTUnwrap(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
                XCTAssertEqual(actual.standardizedFileURL, url.standardizedFileURL)
                let variations = CTFontCopyVariation(font) as? [NSNumber: NSNumber] ?? [:]
                let axes = try XCTUnwrap(CTFontCopyVariationAxes(font) as? [[String: Any]])
                for (identifier, expected) in [(UInt32(0x77647468), CGFloat(100)), (UInt32(0x77676874), weight)] {
                    let axis = try XCTUnwrap(axes.first { ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value == identifier })
                    let defaultValue = try XCTUnwrap(axis[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)
                    let actualValue = variations[NSNumber(value: identifier)] ?? defaultValue
                    XCTAssertEqual(actualValue.doubleValue, Double(expected), accuracy: 0.001)
                }
                let measured = SocialSharePrintTypography.uiFont(size: size, weight: weight)
                XCTAssertEqual(measured.pointSize, size, accuracy: 0.001)
                XCTAssertEqual(CTFontCopyAttribute(measured as CTFont, kCTFontURLAttribute) as? URL, actual)
            }
        }
    }

    func testUnbrokenExtendedGraphemesContinueWithinTheFixedTextBudget() {
        let text = String(repeating: "👩🏽‍🚀е\u{301}漢💪", count: 180)
        let pages = SocialShareCardPage.make(preview: preview(note: text), headlineOverride: "")
        let fragments = pages.compactMap(\.text)
        XCTAssertGreaterThan(fragments.count, 1)
        XCTAssertEqual(fragments.joined(), text)
        let font = SocialSharePrintTypography.uiFont(size: 24, weight: 500)
        for fragment in fragments {
            XCTAssertFalse(fragment.isEmpty)
            let bounds = (fragment as NSString).boundingRect(
                with: CGSize(width: 311, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
            XCTAssertLessThanOrEqual(bounds.height, 300)
        }
    }

    func testOversizedExerciseNameAndEverySavedSetRemainInOrder() {
        let name = String(repeating: "Saved exercise 👩🏽‍🚀 голям напредък. ", count: 120)
        let sets = (1...9).map { CompletedSet(load: Load(Double($0)), reps: $0,
            completedAt: Date(timeIntervalSinceReferenceDate: Double($0)), isPerSide: false) }
        let block = SocialShareBlock(id: UUID(), exerciseID: ExerciseIDs.barbellBenchPress, name: name, sets: sets)
        let pages = SocialShareCardPage.make(preview: preview(blocks: [block]), headlineOverride: "")
        XCTAssertEqual(pages.compactMap(\.block).flatMap(\.sets), sets)
        XCTAssertTrue(pages.compactMap(\.block).allSatisfy { $0.sets.count <= 8 })
        XCTAssertEqual(pages.compactMap(\.text).joined(), String(repeating: name, count: sets.count))
        XCTAssertEqual(pages.compactMap(\.block).map(\.name), Array(repeating: "Saved exercise", count: sets.count))
    }

    func testRetainedCardPrintPixelsDoNotScaleWithHostAccessibilityText() throws {
        let page = SocialShareCardPage(block: nil, chips: [], text: "Saved session 💪\nголям напредък 8 × 40")
        for style in SocialShareCardStyle.allCases {
            let view = SocialShareCard(page: page, completedAt: Date(timeIntervalSinceReferenceDate: 1_000), visibility: .exact, style: style)
            let expected = try pixels(view, width: 360, height: 450, scheme: .light, type: .large)
            XCTAssertGreaterThan(Set(expected).count, 8)
            XCTAssertEqual(try pixels(view, width: 360, height: 450, scheme: .dark, type: .accessibility5), expected)
        }
    }

    func testRecapPrintPaletteAndFrozenEffectIgnoreHostAppearance() throws {
        // Typed pieces so the type checker finishes (9 Oct compile check); values unchanged.
        let metrics: [ZOShareMetric] = [.init(id: "workouts", value: "2", label: "workouts"), .init(id: "sets", value: "9", label: "sets")]
        let trainingDays: [ZOShareTrainingDay] = (0..<14).map { (day: Int) -> ZOShareTrainingDay in
            let start = Date(timeIntervalSinceReferenceDate: Double(day) * 86_400)
            return ZOShareTrainingDay(id: start, trained: day == 1 || day == 7)
        }
        let lifts: [ZOShareLiftPayload] = [.init(id: ExerciseIDs.barbellBenchPress, name: "Bench", values: "20 → 25 kg", startFraction: 0.4, currentFraction: 0.5)]
        let payload = ZOSharePayload(isOutdoor: false, title: "Fixture recap", date: "8 October",
            metrics: metrics,
            distance: nil, distanceUnit: nil, best: nil, railGroups: [], route: [], showsEndpoints: false,
            trainingDays: trainingDays,
            nameAndNumber: nil, bodyWeightChange: nil,
            lifts: lifts)
        let view = ZOSharePoster(payload: payload, layout: .recap, size: .story, photo: nil, localization: .english,
            reduceMotionOverride: false)
        let height = 300 / ZOShareSize.story.aspectRatio
        let expected = try pixels(view, width: 300, height: height, scheme: .dark, type: .large)
        XCTAssertGreaterThan(Set(expected).count, 8)
        XCTAssertEqual(try pixels(view, width: 300, height: height, scheme: .light, type: .accessibility5), expected)
    }

    private func preview(note: String = "", blocks: [SocialShareBlock] = []) -> SocialSharePreview {
        .init(workoutTitle: "Fixture", completedAt: Date(timeIntervalSinceReferenceDate: 1_000),
              headline: "", note: note, visibility: .exact, chips: [], blocks: blocks)
    }

    private func pixels<V: View>(_ view: V, width: CGFloat, height: CGFloat,
                                 scheme: ColorScheme, type: DynamicTypeSize) throws -> Data {
        var image: CGImage?
        let pixelWidth = width.rounded(.up), pixelHeight = height.rounded(.up)
        UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light).performAsCurrent {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, type).frame(width: pixelWidth, height: pixelHeight))
            renderer.scale = 1
            image = renderer.cgImage
        }
        let cgImage = try XCTUnwrap(image)
        XCTAssertEqual(cgImage.width, Int(pixelWidth))
        XCTAssertEqual(cgImage.height, Int(pixelHeight))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress,
                width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
                bytesPerRow: cgImage.width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        return Data(bytes)
    }
}

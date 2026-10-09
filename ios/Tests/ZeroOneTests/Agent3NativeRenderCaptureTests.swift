import SwiftUI
import XCTest
@testable import ZeroOne

/// Explicitly selected diagnostic artifacts, not product behavior assertions.
/// PNG attachments show synthetic component viewports. They cannot establish
/// system permission, owner/readiness, Files, microphone, navigation or device acceptance.
@MainActor
final class Agent3NativeRenderCaptureTests: XCTestCase {
    func testCaptureSelectedSyntheticViewports() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ZERO_ONE_AGENT3_RENDER_CAPTURE"] == "1" else {
            throw XCTSkip("Agent 3 renderer diagnostics require explicit opt-in.")
        }
        let encoded = try XCTUnwrap(environment["ZERO_ONE_AGENT3_RENDER_CASES"])
        let cases = try JSONDecoder().decode([CaptureCase].self, from: Data(encoded.utf8))
        guard !cases.isEmpty, cases.count <= 224,
              Set(cases.map(\.id)).count == cases.count else {
            throw CaptureError.invalidConfiguration
        }
        // Reject every malformed configuration before generating the first image.
        for configuration in cases { try configuration.validate() }

        for configuration in cases {
            let theme = try XCTUnwrap(DesignThemePreference(rawValue: configuration.theme))
            let language = try XCTUnwrap(AppLanguage(rawValue: configuration.language))
            let colorScheme: ColorScheme = configuration.appearance == "dark" ? .dark : .light
            let tokens = ZeroOneThemeTokens.resolve(designTheme: theme.designTheme, colorScheme: colorScheme)
            let content = try await surface(configuration.surface)
                .zeroOneTheme(tokens)
                .environment(\.locale, language.locale)
                .environment(\.zeroOneLocalization, AppLocalization(language: language))
                .environment(\.colorScheme, colorScheme)
                .environment(\.dynamicTypeSize, configuration.largeText ? .accessibility1 : .large)
                // accessibilityReduceMotion is read-only in SwiftUI; Reduce Motion captures need the Simulator setting.
                .frame(width: 390, height: 844, alignment: .top)
                .background(tokens.backgroundPrimary)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage, "Renderer returned no image for \(configuration.id)")
            _ = try XCTUnwrap(image.pngData(), "Renderer image is not encodable for \(configuration.id)")
            XCTContext.runActivity(named: configuration.id) { activity in
                let pixels = XCTAttachment(image: image)
                pixels.name = configuration.id + ".png"
                pixels.lifetime = .keepAlways
                activity.add(pixels)
                let receipt = XCTAttachment(string: """
                SYNTHETIC_COMPONENT_VIEWPORT
                Case: \(configuration.id)
                Viewport: 390x844 points, scale 3; this is not a captured device screen.
                Permission/readiness/Files/speech/provider success: NOT EXERCISED
                Navigation, keyboard, touch, VoiceOver, safe areas, offscreen scroll content: NOT EXERCISED
                Theme and locale are explicit environment inputs; no persisted preferences are changed.
                A generated PNG requires independent visual review; this test has no pixel acceptance assertions.
                """
                )
                receipt.name = configuration.id + "-scope.txt"
                receipt.lifetime = .keepAlways
                activity.add(receipt)
            }
        }
    }

    private enum Surface: String, Decodable {
        case exportDefault = "export-default"
        case previewEmpty = "preview-empty"
        case previewLong = "preview-long"
        case voiceConsent = "voice-consent"
        case voiceDenied = "voice-denied"
        case voiceUnavailable = "voice-unavailable"
        case voiceCancelled = "voice-cancelled"
    }

    private struct CaptureCase: Decodable {
        let id: String
        let surface: Surface
        let theme: String
        let appearance: String
        let language: String
        let largeText: Bool
        let reduceMotion: Bool

        func validate() throws {
            guard !id.isEmpty, id.count <= 160,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  DesignThemePreference(rawValue: theme) != nil,
                  AppLanguage(rawValue: language) != nil,
                  ["dark", "light"].contains(appearance) else {
                throw CaptureError.invalidConfiguration
            }
        }
    }

    private enum CaptureError: Error { case invalidConfiguration, disabledBoundary }

    private func surface(_ surface: Surface) async throws -> AnyView {
        switch surface {
        case .exportDefault:
            // Initial selection and privacy acknowledgement are the real view's
            // defaults. No export document or Files presentation is synthesized.
            return AnyView(LocalDataExportView(makeJSON: { _ in
                throw CaptureError.disabledBoundary
            }))
        case .previewEmpty, .previewLong:
            // Explicit synthetic values passed to the actual pure component.
            // No coordinator review, readiness grant, confirmation or write exists.
            let isLong = surface == .previewLong
            return AnyView(LocalDataImportPreviewCard(
                fileName: isLong
                    ? "SYNTHETIC-review-very-long-export-file-name-2026-10-08.json" : nil,
                foundTitle: "Workouts found", found: isLong ? 1_234_567 : 0,
                addedTitle: "New workouts", added: isLong ? 1_234_500 : 0,
                skippedTitle: "Identical workouts skipped", skipped: isLong ? 67 : 0
            ).padding(20))
        case .voiceConsent, .voiceDenied, .voiceUnavailable, .voiceCancelled:
            let access: SpeechAccessState = surface == .voiceDenied ? .denied
                : surface == .voiceUnavailable ? .unavailable : .notDetermined
            let coordinator = VoiceAssistantCoordinator(
                transcriptionService: ClosedDiagnosticSpeechService(accessState: access))
            if surface == .voiceCancelled { await coordinator.requestAccess() }
            return AnyView(AssistantPushToTalkSection(coordinator: coordinator, onConfirm: { _ in
                XCTFail("A closed diagnostic must never confirm speech.")
            }).padding(20))
        }
    }
}

/// Test-only and closed. Explicit implementations override the protocol's
/// permissive convenience defaults. It never returns granted or touches hardware.
@MainActor
private final class ClosedDiagnosticSpeechService: SpeechTranscriptionService {
    let accessState: SpeechAccessState
    init(accessState: SpeechAccessState) { self.accessState = accessState }
    func requestAccess() async -> SpeechAccessRequestOutcome { .cancelled }
    func startTranscription(
        onTranscript: @escaping @MainActor (String) -> Void,
        onAudioLevel: @escaping @MainActor (Double) -> Void,
        onFailure: @escaping @MainActor (VoiceInteractionError) -> Void
    ) async throws {
        throw VoiceInteractionError.speechRecognizerUnavailable
    }
    func stopTranscription() async -> String { "" }
    func cancelTranscription() {}
}

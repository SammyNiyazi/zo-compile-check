import AVFoundation
import Foundation

@MainActor
protocol WorkoutAudioSession: AnyObject {
    var category: AVAudioSession.Category { get }
    var mode: AVAudioSession.Mode { get }
    var categoryOptions: AVAudioSession.CategoryOptions { get }
    var routeSharingPolicy: AVAudioSession.RouteSharingPolicy { get }
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     policy: AVAudioSession.RouteSharingPolicy,
                     options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: WorkoutAudioSession {}

/// Silent demonstrations may repair the default session, but must never replace
/// a MusicKit or microphone owner's configuration. Only capture owns activation.
@MainActor
final class WorkoutAudioSessionController {
    static let shared = WorkoutAudioSessionController(session: AVAudioSession.sharedInstance())

    private struct Profile: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let policy: AVAudioSession.RouteSharingPolicy
        let options: AVAudioSession.CategoryOptions

        @MainActor init(_ session: WorkoutAudioSession) {
            category = session.category
            mode = session.mode
            policy = session.routeSharingPolicy
            options = session.categoryOptions
        }
    }

    private let session: WorkoutAudioSession
    private var previous: Profile?
    private var capture: Profile?
    private var activated = false

    init(session: WorkoutAudioSession) { self.session = session }

    func prepareForSilentPlayback() throws {
        guard session.category == .soloAmbient else { return }
        try session.setCategory(.ambient, mode: .default, policy: .default, options: [])
    }

    func beginCapture() throws {
        try endCapture()
        let previous = Profile(session)
        // duckOthers is supported by playAndRecord, not record.
        try session.setCategory(.playAndRecord, mode: .measurement, policy: .default, options: [.duckOthers])
        self.previous = previous
        capture = Profile(session) // Includes options implicitly added by iOS.
        do {
            try session.setActive(true, options: [])
            activated = true
        } catch {
            try? endCapture()
            throw error
        }
    }

    func endCapture() throws {
        guard let previous, let capture else { return }
        guard Profile(session) == capture else {
            // A later audio owner superseded us. Do not deactivate their session.
            clearCapture()
            return
        }
        if activated {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            activated = false
        }
        try session.setCategory(previous.category, mode: previous.mode,
                                policy: previous.policy, options: previous.options)
        clearCapture()
        // Do not invent the prior activation state. Its owner resumes explicitly.
    }

    private func clearCapture() {
        previous = nil
        capture = nil
        activated = false
    }
}

enum VoicePermissionStatus: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

enum SpeechAccessState: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case unavailable
}

enum SpeechAccessRequestOutcome: Equatable, Sendable {
    case granted
    case denied
    case cancelled
    case unavailable
}

enum VoiceInteractionError: Error, Equatable, Sendable {
    case microphoneDenied
    case speechRecognitionDenied
    case speechRecognizerUnavailable
    case audioInputUnavailable
    case interrupted
    case recognitionFailed
    case noSpeech

    var confirmation: AssistantConfirmation {
        switch self {
        case .microphoneDenied:
            .error("Enable microphone access in Settings.")
        case .speechRecognitionDenied:
            .error("Enable speech recognition in Settings.")
        case .speechRecognizerUnavailable:
            .error("Speech recognition is unavailable.")
        case .audioInputUnavailable:
            .error("No microphone is available.")
        case .interrupted:
            .error("Listening was interrupted.")
        case .recognitionFailed:
            .error("Couldn’t understand that.")
        case .noSpeech:
            .error("Didn’t catch that.")
        }
    }
}

@MainActor
protocol VoiceCaptureService: AnyObject {
    var permissionStatus: VoicePermissionStatus { get }

    func requestPermission() async -> VoicePermissionStatus

    func startCapture(
        onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onInterruption: @escaping @MainActor () -> Void
    ) throws

    func stopCapture()
}

@MainActor
final class NativeVoiceCaptureService: VoiceCaptureService {
    // Construct the audio graph only when voice capture starts, not while the app shell appears.
    private lazy var audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private let audioController = WorkoutAudioSessionController(session: AVAudioSession.sharedInstance())
    private var interruptionObserver: NSObjectProtocol?
    private var hasInstalledTap = false

    var permissionStatus: VoicePermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .notDetermined
        @unknown default: .denied
        }
    }

    func requestPermission() async -> VoicePermissionStatus {
        if permissionStatus != .notDetermined {
            return permissionStatus
        }

        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted ? .granted : .denied)
            }
        }
    }

    func startCapture(
        onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onInterruption: @escaping @MainActor () -> Void
    ) throws {
        stopCapture()

        try audioController.beginCapture()
        do {
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceInteractionError.audioInputUnavailable
            }

            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format, block: onBuffer)
            hasInstalledTap = true

            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: audioSession,
                queue: .main
            ) { notification in
                guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: typeValue) == .began else { return }
                Task { @MainActor in
                    onInterruption()
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stopCapture()
            throw error
        }
    }

    func stopCapture() {
        if hasInstalledTap {
            if audioEngine.isRunning { audioEngine.stop() }
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        // An idle stop has no audio-session side effect. A failed restoration
        // retains its lease so the next start retries before recording.
        try? audioController.endCapture()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }
}

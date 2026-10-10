import AVFoundation
import Foundation

/// The only boundary used by the service to construct recognition resources.
/// Tests supply inert sessions; the default driver still uses on-device Speech.
@MainActor
protocol SpeechRecognitionDriver: AnyObject {
    var isAvailable: Bool { get }
    var permissionStatus: VoicePermissionStatus { get }
    func requestPermission() async -> VoicePermissionStatus
    func makeSession() -> SpeechRecognitionSession
}

@MainActor
protocol SpeechRecognitionSession: AnyObject {
    var inputGate: SpeechBufferDeliveryGate { get }
    func startRecognition(onResult: @escaping (String?, Bool) -> Void)
    func cancel()
}

/// Capture calls this from its audio thread. Closing and appending use the same
/// lock, so an obsolete buffer cannot append after endAudio or touch a new request.
final class SpeechBufferDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var acceptsBuffers = true
    private let appendBuffer: (AVAudioPCMBuffer) -> Void
    private let finishAudio: () -> Void

    init(append: @escaping (AVAudioPCMBuffer) -> Void, endAudio: @escaping () -> Void) {
        appendBuffer = append
        finishAudio = endAudio
    }

    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsBuffers else { return false }
        appendBuffer(buffer)
        return true
    }

    func close() {
        lock.lock()
        guard acceptsBuffers else { lock.unlock(); return }
        acceptsBuffers = false
        // All accepted appends completed before this lock acquisition. Unlock
        // before endAudio, which may synchronously reenter cancellation.
        lock.unlock()
        finishAudio()
    }
}

/// MainActor delivery state and resources belong to one immutable reference.
/// No callback reads transcript, stopping state or recognition resources globally.
@MainActor
final class SpeechRequestIsolation {
    var transcript = ""
    var isStopping = false
    var captureStarted = false
    var session: SpeechRecognitionSession?
    var reviewTask: Task<Void, Never>?
}

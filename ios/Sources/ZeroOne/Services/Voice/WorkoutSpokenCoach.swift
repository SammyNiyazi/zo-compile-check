import AVFoundation
import Foundation
import Observation

/// Proof 37, 42, 45: "Say it in my AirPods". Off by default. Speaks the same
/// coach line the screen shows, with the iPhone's own voice, only while
/// headphones are the audio route. Other apps' music is lowered while it
/// speaks and comes back after. Nothing is recorded.
@MainActor
@Observable
final class WorkoutSpokenCoach {
    static let shared = WorkoutSpokenCoach()

    enum Speed: String, CaseIterable, Identifiable {
        case slower, normal, faster
        var id: String { rawValue }
        var title: String {
            switch self {
            case .slower: "Slower"
            case .normal: "Normal"
            case .faster: "Faster"
            }
        }
        var rate: Float {
            switch self {
            case .slower: AVSpeechUtteranceDefaultSpeechRate * 0.85
            case .normal: AVSpeechUtteranceDefaultSpeechRate
            case .faster: AVSpeechUtteranceDefaultSpeechRate * 1.15
            }
        }
    }

    static let enabledKey = "01.coach.speak"
    static let speedKey = "01.coach.speakSpeed"

    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var lastSpoken: String?
    @ObservationIgnored private var previous: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    @ObservationIgnored private let delegate = SpeechDelegate()

    init() {
        synthesizer.delegate = delegate
        delegate.onDone = { [weak self] in self?.finished() }
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var speed: Speed { Speed(rawValue: UserDefaults.standard.string(forKey: Self.speedKey) ?? "") ?? .normal }

    /// Headphones only: wired, Bluetooth, AirPods. Never the iPhone speaker.
    var headphonesConnected: Bool {
        let ports: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { ports.contains($0.portType) }
    }

    /// Says a new coach line once. The same line on a redraw is not repeated.
    func say(_ text: String, language: AppLanguage, force: Bool = false) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, force || (isEnabled && line != lastSpoken), headphonesConnected else { return }
        let session = AVAudioSession.sharedInstance()
        // The microphone owner (voice) keeps its session; 01 stays quiet then.
        guard session.category != .playAndRecord else { return }
        lastSpoken = line
        if previous == nil {
            previous = (session.category, session.mode, session.categoryOptions)
            do {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true)
            } catch {
                restore()
                return
            }
        }
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = AVSpeechSynthesisVoice(language: language == .bulgarian ? "bg-BG" : "en-US")
        utterance.rate = speed.rate
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// A new workout may repeat an earlier sentence.
    func reset() { lastSpoken = nil }

    private func restore() {
        guard let previous else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
        self.previous = nil
    }

    private func finished() {
        guard !synthesizer.isSpeaking else { return }
        isSpeaking = false
        restore()
    }
}

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onDone: (@MainActor () -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onDone?() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onDone?() }
    }
}

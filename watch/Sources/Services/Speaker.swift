import AVFoundation
import os

// TTS pattern proven in CarmellaABC: playback session, best en-US voice.
// Watch-speaker voices sound more robotic than iPhone; that is normal.
final class Speaker: NSObject {
    static let shared = Speaker()

    var muted = false

    private let synth = AVSpeechSynthesizer()
    private let log = Logger(subsystem: "com.donalleniii.wristdeck", category: "speech")

    private override init() {
        super.init()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    private lazy var voice: AVSpeechSynthesisVoice? = {
        let american = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        return american.first { $0.quality == .premium }
            ?? american.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    func speak(_ text: String, rate: Double) {
        guard !muted, !text.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Float(rate)
        synth.speak(utterance)
        log.info("speaking: \(text.prefix(80), privacy: .public)")
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}

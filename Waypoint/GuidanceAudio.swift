import AVFoundation
import Foundation

@MainActor
final class GuidanceAudio {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private let speech = AVSpeechSynthesizer()
    private var cueBuffer: AVAudioPCMBuffer?
    private var cuePlaying = false

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        engine.attach(player)
        engine.attach(environment)
        engine.connect(player, to: environment, format: format)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        player.renderingAlgorithm = .HRTF
        player.volume = 0.65
        let frames = AVAudioFrameCount(48_000 * 0.52)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(frames) {
                let t = Double(index) / 48_000
                let envelope = max(0, min(t / 0.035, (0.20 - t) / 0.06, 1))
                samples[index] = Float(envelope * (0.16 * sin(2 * .pi * 720 * t) + 0.07 * sin(2 * .pi * 1260 * t)))
            }
        }
        cueBuffer = buffer
    }

    private func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    func cue(offset: Double) throws {
        let radians = offset * .pi / 180
        player.position = AVAudio3DPoint(x: Float(sin(radians)), y: 0, z: Float(-cos(radians)))
        if cuePlaying && engine.isRunning { return }
        guard let cueBuffer else { return }
        try activate()
        if !engine.isRunning { try engine.start() }
        player.stop()
        player.scheduleBuffer(cueBuffer, at: nil, options: .loops)
        player.play()
        cuePlaying = true
    }

    func stopCue() {
        if cuePlaying { player.stop() }
        cuePlaying = false
    }

    func say(_ text: String) {
        try? activate()
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-SG") ?? AVSpeechSynthesisVoice(language: "en-US")
        speech.speak(utterance)
    }

    func stop() {
        stopCue()
        engine.stop()
        speech.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

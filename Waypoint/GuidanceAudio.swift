import AVFoundation
import Foundation

@MainActor
final class GuidanceAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let speech = AVSpeechSynthesizer()
    private let leftCue: AVAudioPCMBuffer
    private let rightCue: AVAudioPCMBuffer
    private var cueIsLeft: Bool?

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        leftCue = Self.makeCue(format: format, pitches: (660, 440))
        rightCue = Self.makeCue(format: format, pitches: (660, 990))
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.volume = 0.85
    }

    private static func makeCue(format: AVAudioFormat, pitches: (Double, Double)) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * 0.68)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        guard let samples = buffer.floatChannelData?[0] else { return buffer }
        for index in 0..<Int(frames) {
            let t = Double(index) / format.sampleRate
            let second = t >= 0.19
            let time = second ? t - 0.19 : t
            let pitch = second ? pitches.1 : pitches.0
            let envelope = max(0, min(time / 0.025, (0.15 - time) / 0.04, 1))
            samples[index] = Float(envelope * (0.29 * sin(2 * .pi * pitch * time)
                                               + 0.08 * sin(4 * .pi * pitch * time)))
        }
        return buffer
    }

    var outputName: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName)
        return outputs.isEmpty ? "No audio output" : outputs.joined(separator: ", ")
    }

    private func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    func cue(offset: Double) throws {
        let left = offset < 0
        let strength = min(1, max(0.55, abs(offset) / 75))
        player.pan = Float(left ? -strength : strength)
        if cueIsLeft == left && engine.isRunning && player.isPlaying { return }
        try activate()
        if !engine.isRunning { try engine.start() }
        player.stop()
        player.scheduleBuffer(left ? leftCue : rightCue, at: nil, options: .loops)
        player.play()
        cueIsLeft = left
    }

    func stopCue() {
        if cueIsLeft != nil { player.stop() }
        cueIsLeft = nil
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

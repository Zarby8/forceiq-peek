import AVFoundation
import PeakCore
import SwiftUI

// "What's my day" speech + the 5090 light's dot. See PeakCore DayBrief.swift / GPULight.swift.

extension Color {
    /// Brand.redHex (shapes only: the 5090 dot and its glow; never a text colour).
    static let peakRed: Color = { let c = Brand.rgb(Brand.redHex); return Color(.sRGB, red: c.r, green: c.g, blue: c.b) }()
}

/// Local macOS text-to-speech for the brief: AVSpeechSynthesizer with an on-device system voice. No cloud TTS; nothing
/// is recorded, written or uploaded (the synthesizer plays straight to this Mac's output).
@MainActor final class SpeechBriefSpeaker: NSObject, BriefSpeaking, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var done: (@MainActor () -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, done: @escaping @MainActor () -> Void) {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        self.done = done
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        finish()
    }

    private func finish() { let d = done; done = nil; d?() }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}

/// The 5090 light: a small dot (green, or red for held AND for unknown) with its label in pure white. The glow is on
/// the dot only (a shape); the text is never faded, dimmed or coloured.
struct GPULightDot: View {
    @ObservedObject var light: GPULightModel
    var body: some View {
        let s = light.shown
        let dot = s == .green ? Color.peakGreen : Color.peakRed
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 8, height: 8)
                .shadow(color: dot, radius: 3)
            Text(s.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white).lineLimit(1)
        }
        .help(GPUGate.refusal(s) ?? "No meeting within 2 h: 5090 GPU jobs may run.")
        .accessibilityElement(children: .combine)
    }
}

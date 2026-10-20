import AVFoundation
import Foundation
import PeakCore
import Speech

/// What the voice controller drives: Parakeet (PeakDictation) or, when that fails to load, Apple's on-device Speech.
protocol DictationEngine: Sendable {
    func begin(_ onUpdate: @escaping @Sendable (PeakDictation.Update) -> Void) async
    func append(_ chunk: [Float]) async
    func finish() async -> PeakDictation.Final
    func cancel() async
}

extension PeakDictation: DictationEngine {}

/// The fallback engine: SFSpeechRecognizer with `requiresOnDeviceRecognition = true`, always. If this Mac can't recognize on-device
/// the controller refuses the fallback (VoiceFallback.decide) instead of letting audio leave the Mac. Mic samples are appended to the
/// request in memory; nothing is written to disk. Partial results are shown as they arrive (Apple revises words, so there is no
/// confirmed-prefix filtering here); the final text goes to 3PO like a typed message. No name boost: that needs Peek's own models.
actor AppleSpeechDictation: DictationEngine {
    static let locale = Locale(identifier: "en-US")
    static var recognizer: SFSpeechRecognizer? { SFSpeechRecognizer(locale: locale) }
    static var onDeviceSupported: Bool { recognizer?.supportsOnDeviceRecognition ?? false }
    /// nil = not asked yet.
    static var authorized: Bool? {
        switch SFSpeechRecognizer.authorizationStatus() { case .authorized: return true; case .notDetermined: return nil; default: return false }
    }
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onUpdate: (@Sendable (PeakDictation.Update) -> Void)?
    private var latest = ""
    private var gotFinal = false
    private var waiter: CheckedContinuation<Void, Never>?

    func begin(_ onUpdate: @escaping @Sendable (PeakDictation.Update) -> Void) {
        self.onUpdate = onUpdate; latest = ""; gotFinal = false
        guard let r = Self.recognizer, r.supportsOnDeviceRecognition else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.addsPunctuation = true
        request = req
        task = r.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { await self?.handle(text: text, final: final, failed: failed) }
        }
    }

    private func handle(text: String?, final: Bool, failed: Bool) {
        if let text, !text.isEmpty { latest = text; onUpdate?(PeakDictation.Update(confirmed: text, isFinal: false)) }
        if final || failed { gotFinal = true; waiter?.resume(); waiter = nil }
    }

    func append(_ chunk: [Float]) {
        guard let request, !chunk.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)) else { return }
        buf.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
        request.append(buf)
    }

    func finish() async -> PeakDictation.Final {
        let t0 = Date()
        request?.endAudio()
        if !gotFinal {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiter = c
                Task { try? await Task.sleep(nanoseconds: 2_000_000_000); self.giveUpWaiting() }
            }
        }
        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        task = nil; request = nil
        onUpdate?(PeakDictation.Update(confirmed: text, isFinal: true))
        return PeakDictation.Final(text: text, raw: text, boosted: nil, decodeMs: Date().timeIntervalSince(t0) * 1000, boostMs: 0)
    }

    private func giveUpWaiting() { waiter?.resume(); waiter = nil }

    func cancel() { task?.cancel(); task = nil; request = nil; latest = "" }
}

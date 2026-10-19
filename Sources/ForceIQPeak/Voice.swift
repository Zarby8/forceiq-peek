import AVFoundation
import FluidAudio
import Foundation
import PeakCore
import SwiftUI

// ForceIQ Peek voice: toggle-only dictation into 3PO. FluidAudio v0.17.7 + Parakeet TDT 0.6B v3 on the ANE, re-decoded
// every 160 ms; only the LocalAgreement-2 prefix (confirmed words) is ever shown. On stop: one full decode, the Parakeet
// CTC 110M name boost against the live roster (spotter rescue OFF), then Peek's name guard + possessive restore
// (PeakCore VoiceNameGuard). The words then go to 3PO exactly like a typed message.
// Privacy: mic samples live only in memory ([Float]) and are dropped at stop. No AVAudioFile, no recorder, no temp files,
// nothing uploaded. Only the model weights touch disk, under <Peek root>/models.

// ───────────────────────────── audio sources ─────────────────────────────
/// 16 kHz mono Float32 chunks, in memory only.
protocol VoiceSource: AnyObject {
    func start(_ onChunk: @escaping @Sendable ([Float]) -> Void) throws
    func stop()
}

/// The mic: AVAudioEngine input tap → AVAudioConverter → 16 kHz mono.
final class MicSource: VoiceSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    func start(_ onChunk: @escaping @Sendable ([Float]) -> Void) throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, let conv = AVAudioConverter(from: fmt, to: Self.target) else {
            throw NSError(domain: "peak.voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input on this Mac."])
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: fmt) { buf, _ in
            if let s = Self.convert(buf, conv, rate: fmt.sampleRate) { onChunk(s) }
        }
        engine.prepare()
        try engine.start()
    }
    func stop() { engine.inputNode.removeTap(onBus: 0); engine.stop() }

    /// The one conversion path both the mic and the smoke feed go through.
    static func convert(_ buf: AVAudioPCMBuffer, _ conv: AVAudioConverter, rate: Double) -> [Float]? {
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / rate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        nonisolated(unsafe) var fed = false
        conv.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        guard let ch = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}

/// Live smoke only (demo mode + FORCEIQ_PEAK_VOICE_FEED): a recorded say/TTS clip played in real time, 1024-frame buffers
/// through the same AVAudioConverter + chunk path as the mic (a loopback for a headless Mac without mic access).
final class FeedSource: VoiceSource, @unchecked Sendable {
    let url: URL
    private var timer: DispatchSourceTimer?
    /// Speech onset in the clip (first 20 ms frame above -40 dBFS), seconds; for latency from onset.
    private(set) var onset: Double = 0
    private(set) var duration: Double = 0
    init(url: URL) { self.url = url }
    func start(_ onChunk: @escaping @Sendable ([Float]) -> Void) throws {
        let f = try AVAudioFile(forReading: url)               // read-only: the clip is the input, nothing is written
        let fmt = f.processingFormat
        guard let all = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else { return }
        try f.read(into: all)
        duration = Double(all.frameLength) / fmt.sampleRate
        if let ch = all.floatChannelData {
            let win = Int(fmt.sampleRate * 0.02)
            var i = 0
            while i + win < Int(all.frameLength) {
                var e: Float = 0; for k in i..<(i + win) { e += ch[0][k] * ch[0][k] }
                if 10 * log10(max(1e-12, e / Float(win))) > -40 { onset = Double(i) / fmt.sampleRate; break }
                i += win
            }
        }
        guard let conv = AVAudioConverter(from: fmt, to: MicSource.target) else { return }
        let n = AVAudioFrameCount(1_024)
        nonisolated(unsafe) var pos: AVAudioFramePosition = 0
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "peak.voice.feed", qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: Double(n) / fmt.sampleRate, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard pos < AVAudioFramePosition(all.frameLength) else { self?.timer?.cancel(); return }
            let len = min(n, AVAudioFrameCount(AVAudioFramePosition(all.frameLength) - pos))
            guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: len), let src = all.floatChannelData, let dst = b.floatChannelData else { return }
            b.frameLength = len
            for c in 0..<Int(fmt.channelCount) { dst[c].update(from: src[c].advanced(by: Int(pos)), count: Int(len)) }
            pos += AVAudioFramePosition(len)
            if let s = MicSource.convert(b, conv, rate: fmt.sampleRate) { onChunk(s) }
        }
        timer = t; t.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
}

// ───────────────────────────── the engine ─────────────────────────────
actor PeakDictation {
    struct Update: Sendable { var confirmed: String; var isFinal: Bool }
    struct Final: Sendable { var text: String; var raw: String; var boosted: String?; var decodeMs: Double; var boostMs: Double }

    private let asr = AsrManager(config: .default)
    private var loaded = false
    private var ctc: CtcModels?
    private var boosting: PeakBoost?
    private var ctcDir: URL?
    private var tokenizer: CtcTokenizer?
    private var roster: [String] = []
    private var common = CommonWords()
    private var samples: [Float] = []
    private var lastDecodedAt = 0
    private var previous = ""
    private var shown = ""
    private var running = false
    private var decodeTask: Task<Void, Never>?
    private var onUpdate: (@Sendable (Update) -> Void)?

    /// Every Hugging Face download resolves to the pinned commits (never a moving `main`).
    static func pinRevisions() {
        var o = ModelRegistry.revisionOverrides
        for p in VoiceModels.all { o[p.repo] = p.revision }
        ModelRegistry.revisionOverrides = o
    }

    static func modelsPresent(root: URL) -> Bool {
        AsrModels.modelsExist(at: VoiceModels.dir(VoiceModels.tdt, peakRoot: root)) && CtcModels.modelsExist(at: VoiceModels.dir(VoiceModels.ctc, peakRoot: root))
    }

    var isLoaded: Bool { loaded }

    /// Downloads (first enable only) into <Peek root>/models, then loads on the ANE. `progress(fraction, what)`.
    func prepare(root: URL, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard !loaded else { return }
        Self.pinRevisions()
        try FileManager.default.createDirectory(at: VoiceModels.root(root), withIntermediateDirectories: true)
        let tdtShare = Double(VoiceModels.tdt.approxMB) / Double(VoiceModels.tdt.approxMB + VoiceModels.ctc.approxMB)
        let tdtDir = VoiceModels.dir(VoiceModels.tdt, peakRoot: root), ctcDir = VoiceModels.dir(VoiceModels.ctc, peakRoot: root)
        let label = VoiceModels.tdt.label
        let models = try await AsrModels.downloadAndLoad(to: tdtDir, version: .v3, progressHandler: { p in
            switch p.phase {
            case .compiling: progress(-1, label)
            default: progress(p.fractionCompleted * tdtShare, label)
            }
        })
        try await asr.loadModels(models)
        if !CtcModels.modelsExist(at: ctcDir) { progress(tdtShare, VoiceModels.ctc.label) }
        ctc = try await CtcModels.downloadAndLoad(to: ctcDir, variant: .ctc110m)
        self.ctcDir = ctcDir
        tokenizer = try await CtcTokenizer.load(from: ctcDir)        // from <Peek root>/models, never Application Support
        progress(1, VoiceModels.ctc.label)
        loaded = true
        try await rebuildBoosting()
    }

    /// The coach's live roster: the boost terms and the name guard's own names.
    func setRoster(_ names: [String], dictionary: Set<String>) async {
        roster = names
        common = CommonWords(dictionary: dictionary, roster: names)
        try? await rebuildBoosting()
    }

    private func rebuildBoosting() async throws {
        guard let ctc, let ctcDir, let tokenizer, !roster.isEmpty else { boosting = nil; return }
        var texts: [String] = []
        for full in roster {
            texts.append(full)
            let parts = full.split(separator: " ")
            if parts.count > 1, let last = parts.last, last.count >= 3 { texts.append(String(last)) }   // surnames as said
        }
        let terms = texts.compactMap { t -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(t)
            return ids.isEmpty ? nil : CustomVocabularyTerm(text: t, weight: nil, aliases: nil, tokenIds: nil, ctcTokenIds: ids, minSimilarity: nil)
        }
        boosting = try await PeakBoost(vocabulary: CustomVocabularyContext(terms: terms), ctcModels: ctc, ctcDir: ctcDir,
                                       config: VocabularyRescorer.Config(spotterRescueEnabled: false))
    }

    func begin(_ onUpdate: @escaping @Sendable (Update) -> Void) {
        samples.removeAll(keepingCapacity: true); lastDecodedAt = 0; previous = ""; shown = ""; running = true
        self.onUpdate = onUpdate
    }

    func append(_ chunk: [Float]) {
        guard running else { return }
        samples += chunk
        // 160 ms cadence; a tick is skipped while a decode is still in flight (bounded ANE/CPU).
        guard samples.count - lastDecodedAt >= 2_560, decodeTask == nil else { return }
        lastDecodedAt = samples.count
        decodeTask = Task { await self.decodePartial() }
    }

    private func decodePartial() async {
        defer { decodeTask = nil }
        guard running, let text = try? await decode(samples).0.text else { return }
        let agreed = LiveWords.agreedPrefix(previous, text)
        previous = text
        let next = LiveWords.advance(shown: shown, agreed: agreed)
        if next != shown { shown = next; onUpdate?(Update(confirmed: shown, isFinal: false)) }
    }

    /// Stop → the final text (decode ≈ 40 ms + CTC rescore ≈ 100 ms on the M5). The audio is dropped right after.
    func finish() async -> Final {
        running = false
        _ = await decodeTask?.value
        defer { samples.removeAll(); previous = ""; shown = "" }
        let t0 = Date()
        guard samples.count > 1_600, let (r, audio) = try? await decode(samples) else { return Final(text: "", raw: "", boosted: nil, decodeMs: 0, boostMs: 0) }
        let t1 = Date()
        var boosted: String?
        if let boosting, let tt = r.tokenTimings, let out = await boosting.rescore(text: r.text, tokenTimings: tt, audioSamples: audio) {
            boosted = out.text
        }
        let text = VoiceNameGuard.finalize(original: r.text, boosted: boosted, common: common)
        let t2 = Date()
        onUpdate?(Update(confirmed: text, isFinal: true))
        return Final(text: text, raw: r.text, boosted: boosted, decodeMs: t1.timeIntervalSince(t0) * 1000, boostMs: t2.timeIntervalSince(t1) * 1000)
    }

    func cancel() { running = false; samples.removeAll(); previous = ""; shown = "" }

    private func decode(_ s: [Float]) async throws -> (ASRResult, [Float]) {
        var audio = s
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return (try await asr.transcribe(audio, decoderState: &state), audio)
    }
}

// ───────────────────────────── the controller (main actor) ─────────────────────────────
@MainActor final class VoiceController: ObservableObject {
    @Published private(set) var phase: VoicePhase = .off
    @Published private(set) var line = VoiceLine()
    @Published private(set) var showLine = false
    @Published private(set) var enabled = false
    /// The final words, pure white, held in the field for a beat before they go to 3PO like a typed message.
    @Published private(set) var handing = false
    let engine = PeakDictation()
    let root: URL
    weak var logger: PeakLogging?
    var roster: [String] = []
    var onListening: ((Bool) -> Void)?
    var onFinal: ((String) -> Void)?
    /// The "What's my day" brief is speaking: the same toggle interrupts it (DayBriefController.interruptIfSpeaking).
    /// true = the press stopped the speech and is consumed (the mic does not open).
    var interrupt: (() -> Bool)?
    /// Voice turned off: silence a brief that is speaking.
    var onDisabled: (() -> Void)?
    /// Live smoke only: the next clip to feed instead of the mic (demo mode).
    var feed: URL?
    private(set) var lastFeed: FeedSource?
    private var source: VoiceSource?
    private var hideTask: Task<Void, Never>?
    // live-smoke bookkeeping
    private var tStart = 0.0, tStop = 0.0, tFirst: Double?, cpuStart = 0.0
    private(set) var results: [(first: Double?, firstFromOnset: Double?, final: Double, cpu: Double)] = []

    init(root: URL, logger: PeakLogging?) { self.root = root; self.logger = logger }

    nonisolated static let dictionaryURL = URL(fileURLWithPath: "/usr/share/dict/web2")

    func configure(enabled on: Bool, roster names: [String]) {
        roster = names
        enabled = on
        guard on else {
            onDisabled?()
            if phase == .listening { toggle() }
            phase = .off; return
        }
        let r = names
        Task.detached(priority: .utility) { [engine] in
            let dict = CommonWords.load(VoiceController.dictionaryURL)
            await engine.setRoster(r, dictionary: dict)
        }
        if case .off = phase { phase = PeakDictation.modelsPresent(root: root) ? .loading : .needsModels }
        prepare()
    }

    /// First enable downloads the models (progress line); later launches only load them.
    func prepare() {
        guard enabled else { return }
        switch phase { case .ready, .listening, .finishing, .downloading: return; default: break }
        let present = PeakDictation.modelsPresent(root: root)
        phase = present ? .loading : .downloading(fraction: 0, what: VoiceModels.tdt.label)
        logger?.log("voice prepare models=\(present ? "present" : "download")")
        let started = Date()
        let root = self.root
        let me = WeakRef(self)
        Task { [engine] in
            do {
                try await engine.prepare(root: root) { f, what in
                    Task { @MainActor in
                        guard let self = me.value, !present else { return }
                        switch self.phase { case .downloading, .loading: break; default: return }
                        self.phase = (f < 0 || f >= 1) ? .loading : .downloading(fraction: f, what: what)
                    }
                }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                await MainActor.run {
                    guard let self = me.value else { return }
                    self.phase = self.enabled ? .ready : .off
                    self.logger?.log("voice ready ms=\(ms) models_mb=\(Self.modelsMB(root))")
                }
            } catch {
                await MainActor.run {
                    me.value?.phase = .failed("Voice couldn't get its speech model. Check the network and turn Voice on again.")
                    me.value?.logger?.log("voice prepare failed=\(type(of: error)) detail=\(String(describing: error).prefix(300))")
                }
            }
        }
    }

    static func modelsMB(_ root: URL) -> Int {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: VoiceModels.root(root), includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var n = 0
        for case let u as URL in e { n += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return n / 1_048_576
    }

    /// One control: a press starts, the next press stops. No hold-to-talk, no wake word, no silence auto-stop.
    func toggle() {
        if interrupt?() == true { logger?.log("voice toggle interrupted=brief"); return }
        guard enabled else { logger?.log("voice toggle refused=off"); return }
        switch phase {
        case .ready: start()
        case .listening: stop()
        case .needsModels, .failed: prepare()
        default: logger?.log("voice toggle ignored phase=busy")
        }
    }

    private func start() {
        if feed == nil {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined:
                let me = WeakRef(self)
                AVCaptureDevice.requestAccess(for: .audio) { ok in Task { @MainActor in if ok { me.value?.start() } else { me.value?.micDenied() } } }
                return
            default: micDenied(); return
            }
        }
        hideTask?.cancel()
        line = VoiceLine(); showLine = true
        tStart = now(); tFirst = nil; cpuStart = Self.cpuSeconds()
        let roster = self.roster
        let me = WeakRef(self)
        Task { [engine] in
            await engine.begin { u in Task { @MainActor in me.value?.received(u, roster: roster) } }
        }
        let src: VoiceSource = feed.map { FeedSource(url: $0) } ?? MicSource()
        do {
            try src.start { [engine] chunk in Task { await engine.append(chunk) } }
        } catch {
            phase = .failed("Peek couldn't open the microphone."); showLine = false
            logger?.log("voice mic failed"); return
        }
        source = src; lastFeed = src as? FeedSource
        phase = .listening
        onListening?(true)
        logger?.log("voice start source=\(feed == nil ? "mic" : "feed")")
    }

    private func micDenied() {
        phase = .failed("Peek can't hear the mic. Allow it in System Settings → Privacy & Security → Microphone, then press the mic again.")
        Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if case .failed = self.phase { self.phase = .ready } }
    }

    private func stop() {
        source?.stop(); source = nil
        tStop = now()
        phase = .finishing
        onListening?(false)
        Task { [weak self, engine] in
            let f = await engine.finish()
            await MainActor.run { [weak self] in self?.finished(f) }
        }
    }

    private func received(_ u: PeakDictation.Update, roster: [String]) {
        let shown = u.isFinal ? u.confirmed : LiveWords.display(u.confirmed)
        if !u.isFinal, tFirst == nil, !shown.isEmpty {
            tFirst = now() - tStart
        }
        line = VoiceLine(confirmed: shown, isFinal: u.isFinal, names: LiveWords.matchNames(shown, roster: roster))
    }

    private func finished(_ f: PeakDictation.Final) {
        let finalMs = (now() - tStop) * 1000
        let wall = max(0.001, now() - tStart)
        let cpu = (Self.cpuSeconds() - cpuStart) / wall * 100
        let onset = lastFeed.map { $0.onset } ?? 0
        let first = tFirst.map { $0 * 1000 }
        results.append((first, first.map { $0 - onset * 1000 }, finalMs, cpu))
        logger?.log(String(format: "voice turn first_confirmed_ms=%@ first_from_onset_ms=%@ final_ms=%.0f decode_ms=%.0f boost_ms=%.0f cpu_pct=%.1f words=%d boosted=%@ guarded=%@",
                           first.map { String(format: "%.0f", $0) } ?? "none", first.map { String(format: "%.0f", $0 - onset * 1000) } ?? "none",
                           finalMs, f.decodeMs, f.boostMs, cpu, f.text.split(separator: " ").count,
                           f.boosted == nil ? "no" : "yes", (f.boosted != nil && f.boosted != f.text) ? "yes" : "no"))
        phase = enabled ? .ready : .off
        let text = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            handing = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let self else { return }
                self.handing = false
                self.onFinal?(text)
            }
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { self?.showLine = false }
        }
    }

    func now() -> Double { Date().timeIntervalSince1970 }
    static func cpuSeconds() -> Double {
        var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }
}

// ───────────────────────────── views ─────────────────────────────
/// Confirmed words only, pure white at full opacity whether pending or final; client names underlined in gold.
/// Pending shows as a gold caret after the last word (never a dimmed or gray word).
struct LiveWordsText: View {
    let line: VoiceLine
    var size: CGFloat = 13
    var body: some View {
        let words = line.segments.reduce(Text("")) { acc, s in
            var t = Text(s.text).foregroundStyle(Color.white)
            if s.name { t = t.underline(true, color: .peakGold) }
            return acc + t
        }
        return (line.pending ? words + Text(" " + VoiceLine.pendingCaret).foregroundStyle(Color.peakGold) : words)
        .font(.system(size: size, weight: .medium))
        .animation(.easeOut(duration: 0.12), value: line)
    }
}

/// The 3PO field's mic button (voice enabled only). Green and breathing while listening; gold outline otherwise.
struct MicButton: View {
    @ObservedObject var voice: VoiceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let on = voice.phase.isListening
        let busy = voice.phase == .finishing || voice.phase == .loading
        Button { Haptic.tick(); voice.toggle() } label: {
            Image(systemName: on ? "mic.fill" : busy ? "ellipsis" : "mic")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(on ? Color.black : Color.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(on ? Color.peakGreen : Color.black))
                .overlay(Circle().stroke(on ? Color.peakGreen : Color.peakGold, lineWidth: 1))
                .overlay {
                    if on && !reduceMotion {
                        Circle().stroke(Color.peakGreen, lineWidth: 2)
                            .phaseAnimator([0.0, 1.0]) { v, p in v.scaleEffect(1 + 0.35 * p).opacity(1 - p) } animation: { _ in .easeOut(duration: 0.9) }
                    }
                }
        }
        .buttonStyle(.plain)
        .help(on ? "Stop (forceiq-peak://voice)" : "Talk to 3PO (forceiq-peak://voice)")
        .accessibilityLabel(on ? "Stop dictation" : "Start dictation")
    }
}

/// Under the collapsed notch / pill while dictating (e.g. started from Raycast): the confirmed words, on black.
struct VoiceStrip: View {
    @ObservedObject var voice: VoiceController
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(voice.phase.isListening ? Color.peakGreen : Color.peakGold).frame(width: 7, height: 7)
            if voice.line.isEmpty {
                Text(voice.phase.isListening ? "Listening" : "…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white)
            } else {
                LiveWordsText(line: voice.line, size: 12).lineLimit(2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(maxWidth: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(voice.phase.isListening ? Color.peakGreen : Color.peakGold, lineWidth: 1))
    }
}

/// A weak reference that can cross into a @Sendable progress callback (the object is main-actor isolated).
final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ v: T) { value = v }
}

/// FluidAudio's VocabularyBoostingSession, with the CTC tokenizer read from Peek's own model folder: the session reads it
/// from ~/Library/Application Support/FluidAudio, which Peek never downloads to. Same steps and thresholds as the
/// session (spot → constrained token rescore, vocabulary-size config, 0.5 s margin); spotter rescue stays off.
struct PeakBoost: Sendable {
    let vocabulary: CustomVocabularyContext
    let spotter: CtcKeywordSpotter
    let rescorer: VocabularyRescorer
    let sizeConfig: ContextBiasingConstants.VocabSizeConfig

    init(vocabulary: CustomVocabularyContext, ctcModels: CtcModels, ctcDir: URL, config: VocabularyRescorer.Config) async throws {
        self.vocabulary = vocabulary
        spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
        sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)
        rescorer = try await VocabularyRescorer.create(spotter: spotter, vocabulary: vocabulary, config: config, ctcModelDirectory: ctcDir)
    }

    func rescore(text: String, tokenTimings: [TokenTiming], audioSamples: [Float]) async -> VocabularyRescorer.RescoreOutput? {
        guard !tokenTimings.isEmpty, !audioSamples.isEmpty, !vocabulary.terms.isEmpty else { return nil }
        guard let spot = try? await spotter.spotKeywordsWithLogProbs(audioSamples: audioSamples, customVocabulary: vocabulary, minScore: nil),
              !spot.logProbs.isEmpty else { return nil }
        let out = rescorer.ctcTokenRescore(transcript: text, tokenTimings: tokenTimings, logProbs: spot.logProbs,
                                           frameDuration: spot.frameDuration, cbw: sizeConfig.cbw, marginSeconds: 0.5,
                                           minSimilarity: max(sizeConfig.minSimilarity, vocabulary.minSimilarity))
        return out.wasModified ? out : nil
    }
}

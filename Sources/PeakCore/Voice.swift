import Foundation

// ForceIQ Peak voice (toggle-only dictation into 3PO). Pure logic, unit-tested: the gate, the model pins, the live-words
// model (confirmed words only), the name guard (the CTC name boost never overwrites a common word; "'s" restored) and the
// latency bookkeeping. The engine (FluidAudio + Parakeet on the ANE) and the mic live in the app target (Voice.swift).
// Audio never leaves this Mac and is never written to disk; only the model weights are (under <Peak root>/models).

// ───────────────────────────── gate ─────────────────────────────
/// Voice is opt-in: off until the coach turns it on in Settings (settings.json `voice_enabled`). With no setting the
/// profile's `modules.voice` decides, and that is false by default too (profile.template.json).
public enum VoiceGate {
    public static func enabled(_ p: CoachProfile, setting: Bool?) -> Bool {
        guard p.configured else { return false }
        return setting ?? p.isEnabled(.voice)
    }
}

// ───────────────────────────── models (pinned) ─────────────────────────────
/// FluidAudio v0.17.7 (503b4bd1) + two Core ML repacks, each pinned to an immutable Hugging Face commit. No NVIDIA Open
/// Model License weights (no EOU, Nemotron or Unified): both are CC-BY-4.0 (credit in THIRD_PARTY_NOTICES.md).
public struct VoiceModelPin: Equatable, Sendable {
    public let repo: String          // Hugging Face repo FluidAudio downloads from
    public let folder: String        // folder under <Peak root>/models
    public let revision: String      // immutable HF commit
    public let upstream: String      // the NVIDIA model it repacks
    public let approxMB: Int
    public let label: String
}

public enum VoiceModels {
    public static let fluidAudioVersion = "0.17.7"
    public static let fluidAudioCommit = "503b4bd1bbf7220882de39fe8ae6716aae4132da"
    public static let tdt = VoiceModelPin(repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml", folder: "parakeet-tdt-0.6b-v3",   // FluidAudio's folderName for .v3
                                          revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe", upstream: "nvidia/parakeet-tdt-0.6b-v3",
                                          approxMB: 461, label: "Parakeet TDT 0.6B v3")
    public static let ctc = VoiceModelPin(repo: "FluidInference/parakeet-ctc-110m-coreml", folder: "parakeet-ctc-110m-coreml",
                                          revision: "accdafd8cf8a2ff1cabe3c11e54416b405d409aa", upstream: "NVIDIA Parakeet CTC 110M",
                                          approxMB: 98, label: "Parakeet CTC 110M (name boost)")
    public static let all = [tdt, ctc]
    /// <Peak root>/models: never a temp folder.
    public static func root(_ peakRoot: URL) -> URL { peakRoot.appendingPathComponent("models", isDirectory: true) }
    public static func dir(_ pin: VoiceModelPin, peakRoot: URL) -> URL { root(peakRoot).appendingPathComponent(pin.folder, isDirectory: true) }
}

/// What the voice engine is doing (drives the mic button, the progress line and the avatar).
public enum VoicePhase: Equatable, Sendable {
    case off                                   // voice not enabled
    case needsModels                           // enabled, models not on this Mac yet
    case downloading(fraction: Double, what: String)
    case loading                               // Core ML load (the first-ever ANE compile can take 10-40 s)
    case ready
    case listening
    case finishing                             // stop tapped: the final decode + name boost (~150 ms)
    case failed(String)

    public var isListening: Bool { self == .listening }
    public var canToggle: Bool {
        switch self { case .ready, .listening: return true; default: return false }
    }
    /// The one progress line (white text; gold only for a failure).
    public var line: String? {
        switch self {
        case .off, .ready, .listening, .finishing: return nil
        case .needsModels: return "Voice needs its speech model (about 560 MB, downloaded once into your Peak folder)."
        case .downloading(let f, let what): return "Downloading \(what): \(Int((max(0, min(1, f)) * 100).rounded())) %"
        case .loading: return "Loading the speech model on this Mac…"
        case .failed(let m): return m
        }
    }
}

// ───────────────────────────── live words ─────────────────────────────
/// One line of live dictation as shown in the notch / pill and the 3PO field. Only CONFIRMED words are shown (the prefix
/// two consecutive decodes agree on, LocalAgreement-2); the early guesses never reach the screen. Confirmed words are white
/// at reduced opacity until the final pass, then pure white. Client names get a gold underline.
public struct VoiceLine: Equatable, Sendable {
    public var confirmed: String = ""
    public var isFinal = false
    public var names: [String] = []
    public init(confirmed: String = "", isFinal: Bool = false, names: [String] = []) {
        self.confirmed = confirmed; self.isFinal = isFinal; self.names = names
    }
    public var isEmpty: Bool { confirmed.isEmpty }

    public struct Segment: Equatable, Sendable {
        public var text: String
        public var name: Bool
        public var final: Bool
    }
    /// The line split into runs: roster names (gold underline) and the rest. Every run is white; `final` picks the opacity.
    public var segments: [Segment] {
        var out: [Segment] = []
        var rest = Substring(confirmed)
        while !rest.isEmpty {
            var best: (Range<Substring.Index>, String)?
            for n in names where !n.isEmpty {
                if let r = rest.range(of: n, options: [.caseInsensitive]), Self.isWordBoundary(rest, r) {
                    if best == nil || r.lowerBound < best!.0.lowerBound { best = (r, n) }
                }
            }
            guard let (r, _) = best else { out.append(Segment(text: String(rest), name: false, final: isFinal)); break }
            if r.lowerBound > rest.startIndex { out.append(Segment(text: String(rest[rest.startIndex..<r.lowerBound]), name: false, final: isFinal)) }
            out.append(Segment(text: String(rest[r]), name: true, final: isFinal))
            rest = rest[r.upperBound...]
        }
        return out
    }
    /// A whole word, or the name followed by "'s" / "s" (the possessive / plural still underlines just the name).
    static func isWordBoundary(_ s: Substring, _ r: Range<Substring.Index>) -> Bool {
        guard r.lowerBound == s.startIndex || !s[s.index(before: r.lowerBound)].isLetter else { return false }
        guard r.upperBound < s.endIndex else { return true }
        let next = s[r.upperBound]
        if !next.isLetter { return true }
        if next == "s" || next == "S" {
            let after = s.index(after: r.upperBound)
            return after == s.endIndex || !s[after].isLetter
        }
        return false
    }
    /// Pending words stay pure white at full opacity (never dimmed, never gray). The only pending cue is this gold
    /// caret after the last word; it goes when the final pass lands.
    public static let pendingCaret = "\u{258D}"
    public static let pendingCaretHex = Brand.goldHex
    /// True until the final pass: the caret shows.
    public var pending: Bool { !isEmpty && segments.contains { !$0.final } }
}

public enum LiveWords {
    static func key(_ s: Substring) -> String { s.lowercased().trimmingCharacters(in: .punctuationCharacters) }

    /// LocalAgreement-2: the word prefix two consecutive decodes agree on (taken from the newer decode).
    public static func agreedPrefix(_ a: String, _ b: String) -> String {
        var out: [Substring] = []
        for (x, y) in zip(a.split(separator: " "), b.split(separator: " ")) {
            guard key(x) == key(y) else { break }
            out.append(y)
        }
        return out.joined(separator: " ")
    }

    /// Confirmed text never shrinks within one dictation (a later decode can only add words or keep them).
    public static func advance(shown: String, agreed: String) -> String {
        let s = shown.split(separator: " "), a = agreed.split(separator: " ")
        guard a.count > s.count else { return shown }
        for (x, y) in zip(s, a) where key(x) != key(y) { return shown }
        return agreed
    }

    /// A lone filler the decoder invents from the first 160 ms ("Okay.", "Um.") is held back until a second word confirms.
    static let fillers: Set<String> = ["okay", "ok", "um", "uh", "oh", "yeah", "stop", "hmm", "mm"]
    public static func display(_ confirmed: String) -> String {
        let w = confirmed.split(separator: " ")
        if w.count == 1, fillers.contains(key(w[0])) { return "" }
        return confirmed
    }

    /// Roster names in this text (also as "Name's" / "Names"), for the gold underline.
    public static func matchNames(_ text: String, roster: [String]) -> [String] {
        let words = Set(text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "'", with: "")
            .split { !$0.isLetter }.map(String.init))
        var out: [String] = []
        for full in roster {
            let parts = full.split(separator: " ").map { $0.lowercased() }
            for p in parts where p.count >= 3 && (words.contains(p) || words.contains(p + "s")) {
                if !out.contains(where: { $0.caseInsensitiveCompare(String(p)) == .orderedSame }) {
                    out.append(full.split(separator: " ").first { $0.lowercased() == p }.map(String.init) ?? p)
                }
            }
        }
        return out
    }
}

// ───────────────────────────── name guard ─────────────────────────────
/// Common English words the name boost must not overwrite. `hard` words are never replaced at all (months, weekdays,
/// numbers, function words and Peak's own command words). Any other dictionary word (macOS /usr/share/dict/web2, loaded
/// by the app) may only become a client name when it is a near-homophone of it ("Holiday" → "Halliday": similarity ≥ 0.7
/// and the same first letter). Roster names themselves are never treated as common words.
public struct CommonWords: Sendable {
    public static let hard: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "yesterday", "tonight",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "twenty", "thirty",
        "forty", "fifty", "hundred", "first", "second", "third", "last", "next",
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "do", "for", "from", "has", "have", "he", "her", "him",
        "his", "i", "if", "in", "into", "is", "it", "its", "me", "my", "no", "not", "of", "on", "or", "our", "out", "she", "so",
        "that", "the", "their", "them", "then", "there", "they", "this", "to", "up", "us", "was", "we", "what", "when", "where",
        "which", "who", "why", "will", "with", "you", "your",
        "open", "start", "stop", "show", "pull", "compare", "check", "mark", "move", "close", "save", "retry", "cancel", "pause",
        "play", "run", "send", "hit", "press", "click", "tap", "meeting", "session", "call", "package", "flow", "code", "button",
        "latest", "notes", "score", "scores", "shifts", "shift", "video", "upload", "title", "slide", "plan", "progress",
        "attendance", "recovery", "workouts", "roster", "filter", "group", "timer", "sync", "lunch", "after", "before", "about",
    ]
    let words: Set<String>
    let roster: Set<String>
    public init(dictionary: Set<String> = [], roster: [String] = []) {
        words = dictionary
        self.roster = Set(roster.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
    }
    /// Lowercased words from a word list file (one per line), e.g. /usr/share/dict/web2. Missing file → empty.
    public static func load(_ url: URL) -> Set<String> {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out = Set<String>(); out.reserveCapacity(240_000)
        for l in s.split(whereSeparator: \.isNewline) where !l.isEmpty { out.insert(l.lowercased()) }
        return out
    }
    public enum Kind: Equatable, Sendable { case hard, dictionary, other }
    public func kind(_ w: String) -> Kind {
        let k = w.lowercased()
        if roster.contains(k) { return .other }
        if Self.hard.contains(k) { return .hard }
        if words.contains(k) { return .dictionary }
        return .other
    }
}

public enum VoiceNameGuard {
    static func letters(_ s: String) -> [Character] { Array(s.lowercased().filter { $0.isLetter }) }
    static func stripPossessive(_ s: String) -> String {
        let l = s.lowercased()
        for suf in ["'s", "’s"] where l.hasSuffix(suf) { return String(s.dropLast(2)) }
        return s
    }
    static func trailingPunct(_ s: String) -> String { String(s.reversed().prefix { $0.isPunctuation && $0 != "'" && $0 != "’" }.reversed()) }

    /// 1 − edit distance / longer length, over letters only.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = letters(a), y = letters(b)
        if x.isEmpty || y.isEmpty { return 0 }
        var d = Array(0...y.count)
        for i in 1...x.count {
            var p = d[0]; d[0] = i
            for j in 1...y.count { let t = d[j]; d[j] = min(d[j] + 1, d[j - 1] + 1, p + (x[i - 1] == y[j - 1] ? 0 : 1)); p = t }
        }
        return 1 - Double(d[y.count]) / Double(max(x.count, y.count))
    }

    public enum Verdict: Equatable, Sendable { case same, accepted, rejectedCommon, rejectedDictionary, rejectedFar }

    /// May the boost put `boosted` where the decoder heard `original`?
    public static func verdict(original: String, boosted: String, common: CommonWords) -> Verdict {
        let o = stripPossessive(original), b = stripPossessive(boosted)
        if letters(o) == letters(b) { return .same }
        let bare = String(letters(o))
        switch common.kind(bare) {
        case .hard: return .rejectedCommon
        case .dictionary:
            let ok = similarity(o, b) >= 0.7 && letters(o).first == letters(b).first
            return ok ? .accepted : .rejectedDictionary
        case .other:
            return similarity(o, b) >= 0.4 ? .accepted : .rejectedFar       // the harness's --ctc-guard rule
        }
    }

    /// Word by word: keep the boost only where the guard accepts it; keep the decoder's punctuation.
    public static func guardReplacements(original: String, boosted: String, common: CommonWords) -> String {
        let o = original.split(separator: " ").map(String.init), b = boosted.split(separator: " ").map(String.init)
        guard o.count == b.count else { return original }        // the rescorer changed the word count: don't trust it
        return zip(o, b).map { ow, bw in
            switch verdict(original: ow, boosted: bw, common: common) {
            case .same, .accepted:
                let p = trailingPunct(ow)
                return trailingPunct(bw).isEmpty && !p.isEmpty ? bw + p : bw
            default: return ow
            }
        }.joined(separator: " ")
    }

    /// The CTC rescorer drops "'s" from names it boosts ("Halliday's" → "Halliday"); put it back where the decoder had it.
    public static func restorePossessives(original: String, boosted: String) -> String {
        let o = original.split(separator: " "), b = boosted.split(separator: " ")
        guard o.count == b.count else { return boosted }
        return zip(o, b).map { ow, bw in
            let ol = stripTrailing(String(ow)).lowercased(), bl = stripTrailing(String(bw)).lowercased()
            if (ol.hasSuffix("'s") || ol.hasSuffix("’s")) && !(bl.hasSuffix("'s") || bl.hasSuffix("’s")) {
                let trail = trailingPunct(String(bw))
                return String(bw.dropLast(trail.count)) + "'s" + trail
            }
            return String(bw)
        }.joined(separator: " ")
    }
    static func stripTrailing(_ s: String) -> String { String(s.dropLast(trailingPunct(s).count)) }

    /// The final pass: guard, then restore possessives (both against the un-boosted decode).
    public static func finalize(original: String, boosted: String?, common: CommonWords) -> String {
        guard let boosted, !boosted.isEmpty else { return original }
        return restorePossessives(original: original, boosted: guardReplacements(original: original, boosted: boosted, common: common))
    }
}

// ───────────────────────────── latency bookkeeping (live smoke) ─────────────────────────────
public enum VoiceStats {
    /// Nearest-rank percentile (p in 0…100).
    public static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let r = Int((p / 100 * Double(s.count)).rounded(.up))
        return s[max(0, min(s.count - 1, r - 1))]
    }
}

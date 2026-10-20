import Foundation

// Voice engine choice, the toggle state machine, and the live caption's text layout. Pure: no audio, no UI.
//
// Peek dictates with FluidAudio's Parakeet on the Neural Engine. If that engine fails to load, dictation falls back to Apple's
// on-device Speech recognizer, and ONLY the on-device one: if this Mac can't recognize on-device, the fallback is refused
// rather than sending audio to Apple's servers.

public enum VoiceEngineKind: String, Sendable { case parakeet, appleSpeech = "apple-speech" }

public enum VoiceFallbackDecision: Equatable, Sendable {
    case useAppleSpeech
    case unavailable(String)
}

public enum VoiceFallback {
    public static let notice = "Dictating with Apple Speech on this Mac: Peek's own speech model didn't load."
    public static let noOnDevice = "Voice couldn't load its speech model, and this Mac can't recognize speech on-device, so Peek won't send audio anywhere. Check the network and turn Voice on again."
    public static let speechDenied = "Voice couldn't load its speech model. Allow Speech Recognition for Peek in System Settings → Privacy & Security, then turn Voice on again."

    /// `authorized`: nil = not asked yet (Peek will ask when dictation starts), true / false = what macOS answered.
    public static func decide(recognizerExists: Bool, onDeviceSupported: Bool, authorized: Bool?) -> VoiceFallbackDecision {
        guard recognizerExists, onDeviceSupported else { return .unavailable(noOnDevice) }
        if authorized == false { return .unavailable(speechDenied) }
        return .useAppleSpeech
    }
}

/// One control: a press starts, the next press stops. No hold-to-talk, no wake word, no silence auto-stop.
public enum VoiceToggleAction: Equatable, Sendable { case interruptBrief, refuseOff, start, stop, prepare, ignoreBusy }

public enum VoiceToggle {
    public static func action(enabled: Bool, phase: VoicePhase, briefSpeaking: Bool) -> VoiceToggleAction {
        if briefSpeaking { return .interruptBrief }
        guard enabled else { return .refuseOff }
        switch phase {
        case .ready: return .start
        case .listening: return .stop
        case .needsModels, .failed: return .prepare
        default: return .ignoreBusy
        }
    }
}

/// The live words as they fit in the notch row. Reading order is left to right across the notch: the earliest words end at the
/// notch's left side, the rest continue on its right; once the text outgrows both sides the oldest words scroll off (whole
/// words only, with a leading ellipsis). On a display without a notch the pill shows one line of the newest words.
public enum LiveCaption {
    /// Character budgets used when no text measurer is available (tests, logic).
    public static let notchLeftChars = 17
    public static let notchRightChars = 20
    public static let pillChars = 54
    /// The room beside the notch in points (the peek is 540 pt wide around a 250 pt notch): 145 pt a side, less the padding next to
    /// the notch, the status dot on the left, and the caret on the right. The view measures real text against these.
    public static let notchLeftPoints: CGFloat = 106
    public static let notchRightPoints: CGFloat = 112
    public static let pillPoints: CGFloat = 372

    public typealias Measure = (String) -> CGFloat

    /// The newest whole words that fit `maxWidth` with a leading ellipsis (an overlong single word is cut by characters).
    public static func tail(_ text: String, maxWidth: CGFloat, measure: Measure) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, measure(t) > maxWidth else { return t }
        var out: [Substring] = []
        for w in t.split(separator: " ").reversed() {
            let candidate = "…" + ([w] + out).joined(separator: " ")
            if measure(candidate) > maxWidth { break }
            out.insert(w, at: 0)
        }
        if !out.isEmpty { return "…" + out.joined(separator: " ") }
        var s = String(t.suffix(max(1, t.count)))
        while s.count > 1, measure("…" + s) > maxWidth { s.removeFirst() }
        return "…" + s
    }

    public static func split(_ text: String, leftWidth: CGFloat, rightWidth: CGFloat, measure: Measure) -> (left: String, right: String) {
        var t = tail(text, maxWidth: leftWidth + rightWidth, measure: measure)
        while true {
            if measure(t) <= leftWidth { return (t, "") }
            let words = t.split(separator: " ").map(String.init)
            var left: [String] = []
            for w in words {
                let next = (left + [w]).joined(separator: " ")
                if measure(next) > leftWidth { break }
                left.append(w)
            }
            if left.isEmpty, let first = words.first {       // a first word wider than the left side: it alone scrolls off
                if words.count == 1 { return (tail(first, maxWidth: leftWidth, measure: measure), "") }
                t = "…" + words.dropFirst().joined(separator: " "); continue
            }
            let right = words.dropFirst(left.count).joined(separator: " ")
            if measure(right) <= rightWidth { return (left.joined(separator: " "), right) }
            // the right side is too full: the oldest word scrolls off and the rest re-flows
            let rest = Array(words.dropFirst())
            if rest.isEmpty { return (left.joined(separator: " "), tail(right, maxWidth: rightWidth, measure: measure)) }
            t = "…" + rest.joined(separator: " ").replacingOccurrences(of: "…", with: "")
        }
    }

    // character-budget forms (kept for logic tests and as the plain-text contract)
    public static func tail(_ text: String, maxChars: Int) -> String { tail(text, maxWidth: CGFloat(maxChars), measure: { CGFloat($0.count) }) }
    public static func split(_ text: String, leftChars: Int = notchLeftChars, rightChars: Int = notchRightChars) -> (left: String, right: String) {
        split(text, leftWidth: CGFloat(leftChars), rightWidth: CGFloat(rightChars), measure: { CGFloat($0.count) })
    }
}

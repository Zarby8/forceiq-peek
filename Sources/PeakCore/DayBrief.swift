import Foundation

// ForceIQ Peek "What's my day" brief (Chris 10.19.2026). Typed ("/day", "what's my day") or said through the existing
// voice toggle (toggle-only, no wake word; voice stays behind its flag, off by default). A few sentences, local only:
//   1. today's Command sessions, each naming its client (GET /api/peak/next-meeting `today`: the bookings read Peek
//      already makes through the engine's Command session);
//   2. BLOCKED items (GOAT approvals: failed jobs + duplicate-run blocks; GOAT live status: failed fixes + fixes needed);
//   3. decisions waiting on Chris (every other open GOAT approval).
// A read older than BriefClock.staleAfter (300 s, the engine's threepo_clock threshold) is labelled STALE with its read
// time and age. A source that can't be read is said plainly; nothing is ever filled in or guessed.
// Speech: local macOS TTS only (AVSpeechSynthesizer in the app), never cloud TTS; audio never leaves this Mac. Typed
// shows the text and speaks only when Voice is on; the same voice toggle interrupts it mid-speech.

// ───────────────────────────── clock + STALE labels ─────────────────────────────
public enum BriefClock {
    /// engine/threepo_clock.py DEFAULT_STALE_S: anything read longer ago than this is STALE.
    public static let staleAfter: TimeInterval = 300
    /// Chris's zone (engine/threepo_clock.py DEFAULT_TZ).
    public static var zone: TimeZone { TimeZone(identifier: "America/Detroit") ?? .current }

    /// "9:30 AM ET".
    public static func time(_ d: Date, tz: TimeZone = zone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "h:mm a"
        return f.string(from: d) + " " + zoneLabel(tz)
    }

    static func zoneLabel(_ tz: TimeZone) -> String {
        ["America/Detroit", "America/New_York", "America/Toronto", "US/Eastern"].contains(tz.identifier) ? "ET" : (tz.abbreviation() ?? tz.identifier)
    }

    /// threepo_clock.say_age: "45 s", "12 min", "4 h 12 min", "3 days".
    public static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 90 { return "\(s) s" }
        if s < 90 * 60 { return "\(Int((Double(s) / 60).rounded())) min" }
        if s < 36 * 3600 {
            let mins = Int((Double(s) / 60).rounded()), h = mins / 60, m = mins % 60
            return m == 0 ? "\(h) h" : "\(h) h \(m) min"
        }
        return "\(Int((Double(s) / 86400).rounded())) days"
    }

    public static func isStale(_ readAt: Date, now: Date) -> Bool { now.timeIntervalSince(readAt) > staleAfter }

    /// "STALE (read 7:02 AM ET, 12 min ago)".
    public static func staleLabel(_ readAt: Date, now: Date, tz: TimeZone = zone) -> String {
        "STALE (read \(time(readAt, tz: tz)), \(age(now.timeIntervalSince(readAt))) ago)"
    }
}

// ───────────────────────────── rows ─────────────────────────────
/// One of today's Command sessions. Always names its client (the engine drops rows without one; so does the parser).
public struct SessionRow: Equatable, Sendable {
    public let client: String
    public let scheduledAt: Date
    public let durationMinutes: Int
    public init(client: String, scheduledAt: Date, durationMinutes: Int) {
        self.client = client; self.scheduledAt = scheduledAt; self.durationMinutes = durationMinutes
    }
}

/// A BLOCKED item or a decision: what kind, for which client, and its title (used only when no client is named).
public struct BriefItem: Equatable, Sendable {
    public let kind: String
    public let client: String
    public let title: String
    public init(kind: String, client: String, title: String) { self.kind = kind; self.client = client; self.title = title }

    /// "Failed job for Test Client Alpha", or "Failed job: <title>" when the item names no client.
    public var phrase: String {
        let k = kind.trimmingCharacters(in: .whitespaces).isEmpty ? "Item" : kind
        if !client.trimmingCharacters(in: .whitespaces).isEmpty { return "\(k) for \(client)" }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? k : "\(k): \(t.count > 60 ? String(t.prefix(59)) + "…" : t)"
    }

    var key: String {
        let t = title.lowercased().replacingOccurrences(of: "_", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return client.lowercased() + "|" + t
    }
}

public extension EngineParse {
    /// next-meeting `today` → sessions; nil when the doc has no usable `today` (old engine, an error doc).
    static func today(_ o: [String: Any]) -> [SessionRow]? {
        guard (o["ok"] as? Bool) == true, let rows = o["today"] as? [Any] else { return nil }
        return rows.compactMap { r -> SessionRow? in
            guard let d = r as? [String: Any], let at = date(str(d["scheduled_at"])) else { return nil }
            let client = str(d["client"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !client.isEmpty else { return nil }
            return SessionRow(client: client, scheduledAt: at, durationMinutes: (d["duration_minutes"] as? Int) ?? 60)
        }.sorted { $0.scheduledAt < $1.scheduledAt }
    }

    /// A GOAT doc's own "at" (approvals listing time / live status write time): ISO with a zone, or naive local.
    static func docAt(_ o: [String: Any]) -> Date? {
        let s = str(o["at"])
        if let d = date(s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: String(s.prefix(19)))
    }

    /// GET /api/live `fixes_needed` (open high-severity GOAT alerts) → BLOCKED items.
    static func fixesNeeded(_ o: [String: Any]) -> [BriefItem] {
        ((o["fixes_needed"] as? [[String: Any]]) ?? []).map { f in
            let client = str(f["client"]).isEmpty ? (strs(f["clients"]).first ?? "") : str(f["client"])
            return BriefItem(kind: "Needs a fix", client: client, title: str(f["title"]))
        }
    }
}

// ───────────────────────────── sources ─────────────────────────────
public enum BriefSource<T: Equatable & Sendable>: Equatable, Sendable {
    case read(T, at: Date)
    case unavailable(String)
}

public struct DayBriefSources: Equatable, Sendable {
    public var sessions: BriefSource<[SessionRow]>
    public var blocked: BriefSource<[BriefItem]>
    public var decisions: BriefSource<[BriefItem]>
    public init(sessions: BriefSource<[SessionRow]>, blocked: BriefSource<[BriefItem]>, decisions: BriefSource<[BriefItem]>) {
        self.sessions = sessions; self.blocked = blocked; self.decisions = decisions
    }
}

public enum DayBriefSplit {
    /// approvals.py kinds that mean something is stuck rather than waiting for a choice.
    static let blockedKinds: Set<String> = ["failed_job", "duplicate"]

    public static func isBlocked(_ a: ApprovalRow) -> Bool {
        blockedKinds.contains(a.kind) || a.title.lowercased().hasPrefix("blocked")
    }

    /// BLOCKED: failed jobs / duplicate-run blocks (approvals), failed fixes and fixes needed (live). Deduped by
    /// client + title, since an open alert can show both as a fix needed and as a failed-job approval.
    public static func blocked(_ s: EngineSnapshot) -> [BriefItem] {
        var out: [BriefItem] = [], seen = Set<String>()
        func add(_ i: BriefItem) { if seen.insert(i.key).inserted { out.append(i) } }
        for a in s.approvals where !a.test && isBlocked(a) { add(BriefItem(kind: a.kindLabel.isEmpty ? "Blocked" : a.kindLabel, client: a.client, title: a.title)) }
        for f in s.fixes where f.state == "failed" { add(BriefItem(kind: "Failed fix", client: f.client, title: f.title)) }
        for f in s.fixesNeeded { add(f) }
        return out
    }

    /// Decisions waiting on Chris: every other open, real (non-test) approval.
    public static func decisions(_ s: EngineSnapshot) -> [BriefItem] {
        s.approvals.filter { !$0.test && !isBlocked($0) }.map { BriefItem(kind: $0.kindLabel.isEmpty ? "Decision" : $0.kindLabel, client: $0.client, title: $0.title) }
    }
}

/// The last good read of each source. A source that fails now falls back to its last good read, which then carries
/// its OLD read time (so it is labelled STALE once it's older than 300 s); with no good read it is unavailable.
public struct DayBriefCache: Sendable {
    var sessions: ([SessionRow], Date)?
    var blocked: ([BriefItem], Date)?
    var decisions: ([BriefItem], Date)?
    public init() {}

    public mutating func ingest(_ s: EngineSnapshot, now: Date) -> DayBriefSources {
        let taken = s.takenAt ?? now
        if let t = s.today { sessions = (t, taken) }
        let approvalsOK = !s.errors.contains("approvals"), liveOK = !s.errors.contains("live")
        let approvalsAt = s.approvalsAt ?? taken, liveAt = s.liveAt ?? taken
        if approvalsOK { decisions = (DayBriefSplit.decisions(s), approvalsAt) }
        if approvalsOK && liveOK { blocked = (DayBriefSplit.blocked(s), min(approvalsAt, liveAt)) }

        let sessionsWhy: String
        if s.commandSignIn != nil { sessionsWhy = "Command sign-in expired, so I can't read today's sessions" }
        else if s.meetingError != nil { sessionsWhy = "Command didn't answer, so I can't read today's sessions" }
        else { sessionsWhy = "this Mac's GOAT doesn't send today's sessions yet" }
        return DayBriefSources(
            sessions: sessions.map { .read($0.0, at: $0.1) } ?? .unavailable(sessionsWhy),
            blocked: blocked.map { .read($0.0, at: $0.1) } ?? .unavailable("GOAT's approvals or live status didn't answer, so I can't say what's BLOCKED"),
            decisions: decisions.map { .read($0.0, at: $0.1) } ?? .unavailable("GOAT's approvals didn't answer, so I can't list the decisions waiting on you"))
    }
}

// ───────────────────────────── composition ─────────────────────────────
public enum DayBriefComposer {
    /// Names listed before "and N more" (keeps the brief to a few sentences).
    public static let maxNamed = 3

    /// Three sentences: sessions, BLOCKED, decisions. Pure.
    public static func compose(_ src: DayBriefSources, now: Date, tz: TimeZone = BriefClock.zone) -> String {
        [sessions(src.sessions, now: now, tz: tz), blocked(src.blocked, now: now, tz: tz), decisions(src.decisions, now: now, tz: tz)]
            .joined(separator: " ")
    }

    static func stamp(_ at: Date, now: Date, tz: TimeZone) -> String {
        BriefClock.isStale(at, now: now) ? ", " + BriefClock.staleLabel(at, now: now, tz: tz) : ""
    }

    static func list(_ xs: [String]) -> String {
        let shown = Array(xs.prefix(maxNamed)), more = xs.count - shown.count
        if more > 0 { return shown.joined(separator: ", ") + " and \(more) more" }
        switch shown.count {
        case 0: return ""
        case 1: return shown[0]
        case 2: return "\(shown[0]) and \(shown[1])"
        default: return shown.dropLast().joined(separator: ", ") + " and " + shown.last!
        }
    }

    static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    static func sessions(_ s: BriefSource<[SessionRow]>, now: Date, tz: TimeZone) -> String {
        switch s {
        case .unavailable(let why): return "Sessions: \(why)."
        case .read(let rows, let at):
            let st = stamp(at, now: now, tz: tz)
            if rows.isEmpty { return "No Command sessions on today's schedule\(st)." }
            let n = rows.count
            return "\(n) Command session\(n == 1 ? "" : "s") today\(st): " + list(rows.map { "\($0.client) at \(BriefClock.time($0.scheduledAt, tz: tz))" }) + "."
        }
    }

    static func blocked(_ s: BriefSource<[BriefItem]>, now: Date, tz: TimeZone) -> String {
        switch s {
        case .unavailable(let why): return "BLOCKED: \(why)."
        case .read(let items, let at):
            let st = stamp(at, now: now, tz: tz)
            if items.isEmpty { return "Nothing is BLOCKED\(st)." }
            return "\(items.count) BLOCKED\(st): " + list(items.map(\.phrase)) + "."
        }
    }

    static func decisions(_ s: BriefSource<[BriefItem]>, now: Date, tz: TimeZone) -> String {
        switch s {
        case .unavailable(let why): return "Decisions: \(why)."
        case .read(let items, let at):
            let st = stamp(at, now: now, tz: tz)
            if items.isEmpty { return "No decisions waiting on you\(st)." }
            let n = items.count
            return "\(n) decision\(n == 1 ? "" : "s") waiting on you\(st): " + list(items.map(\.phrase)) + "."
        }
    }
}

// ───────────────────────────── the command ─────────────────────────────
public enum DayBriefCommand {
    static let rx = try! NSRegularExpression(pattern:
        #"^(?:/day|/brief|what(?:'s| is|s) my day(?: (?:look(?:ing)?|looks) like)?(?: today)?|what does my day look like(?: today)?|brief me(?: on my day)?)$"#)

    /// "/day", "what's my day", "What is my day looking like?", "hey 3po, what's my day". Lead-ins and punctuation are
    /// dropped; anything longer or different goes to 3PO as usual.
    public static func matches(_ text: String) -> Bool {
        var t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"^(?:(?:hey|ok|okay|so|um|uh|please|3po|threepio|three p o)[, ]+)+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[?.!,]+$"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return rx.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }
}

// ───────────────────────────── speech (the app's AVSpeechSynthesizer behind this seam) ─────────────────────────────
/// Local TTS. The app's implementation is AVSpeechSynthesizer (on-device voices); tests use a fake.
@MainActor public protocol BriefSpeaking: AnyObject {
    /// Speak `text`; call `done` once when it finishes or is stopped.
    func speak(_ text: String, done: @escaping @MainActor () -> Void)
    func stop()
}

/// Speaks a brief only when Voice is on; the voice toggle interrupts it (the press is consumed, so it doesn't also
/// open the mic). Logs carry states only, never the brief's words or a client name.
@MainActor public final class DayBriefController: ObservableObject {
    @Published public private(set) var speaking = false
    let speaker: BriefSpeaking
    public var voiceOn: () -> Bool
    weak var logger: PeakLogging?
    private var generation = 0

    public init(speaker: BriefSpeaking, voiceOn: @escaping () -> Bool, logger: PeakLogging? = nil) {
        self.speaker = speaker; self.voiceOn = voiceOn; self.logger = logger
    }

    /// The brief is already on screen. Speak it only if Voice is on. Returns whether it is being spoken.
    @discardableResult
    public func deliver(_ text: String) -> Bool {
        guard voiceOn(), !text.isEmpty else { logger?.log("brief spoken=0"); return false }
        if speaking { speaker.stop() }
        generation += 1
        let g = generation
        speaking = true
        logger?.log("brief spoken=1")
        speaker.speak(text) { [weak self] in
            guard let self, self.generation == g else { return }
            self.speaking = false
        }
        return true
    }

    /// The voice toggle was pressed. Mid-speech: stop talking and consume the press (true). Otherwise false, and the
    /// toggle does its usual start / stop.
    public func interruptIfSpeaking() -> Bool {
        guard speaking else { return false }
        generation += 1
        speaking = false
        speaker.stop()
        logger?.log("brief interrupted=toggle")
        return true
    }

    /// Voice turned off (or Peek quitting): silence at once.
    public func silence() {
        guard speaking else { return }
        generation += 1
        speaking = false
        speaker.stop()
        logger?.log("brief interrupted=voice-off")
    }
}

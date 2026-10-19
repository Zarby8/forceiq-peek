import Foundation

// Next-session pill + gap warnings (read-only). Behind settings.json `nextSessionPill`, OFF by default, no UI.
//
//   GET /api/peak/next-session      this Mac's engine only (engine/peaknextsession.py; local-only route, refuses phones)
//
// The engine reads Command (GET /schedule/bookings, GET /invoices/) through its existing Command session and back-off
// (#23), and Ghost (meeting packs + the client's games) with GETs only. Peek never sees a token and never writes, sends,
// books or invoices. The pill names the client and counts down locally (a coarse timer in the view; no animation loop);
// the feed is polled at most every 5 min (NextSessionModel.pollInterval) off the app's existing 30 s refresh tick, and
// kept in memory only. A dead (403) session stops asking for this run; an expired one (401 / dead) waits 30 min, and the
// engine's own gate already holds Command back.
//
// Gap warnings (each names the client): (a) the breakdown export for today's session, (b) the invoice for today's
// session, (c) an invoice unpaid 7+ days in Command. "present" turns the pill gold (the brand gold token); "unknown"
// (Command has no read endpoint, or didn't answer) is listed with its note and does not turn the pill gold.
// Each warning offers exactly two actions, both clipboard only: Ask TRON (a prompt for TRON, nothing is sent) and Copy.
// Logs carry counts and states only, never a client name or id.

public enum NextSessionGate {
    /// On only when settings.json `nextSessionPill` is true. Off: no fetch, no pill.
    public static func enabled(setting: Bool) -> Bool { setting }
}

public enum GapKind: String, Sendable, CaseIterable {
    case exportMissing = "export_missing", invoiceMissing = "invoice_missing", invoiceUnpaid = "invoice_unpaid"
}

public enum GapState: String, Sendable { case present, unknown }

/// The only things a gap warning may do. Both put text on the clipboard; neither sends, books, invoices or runs anything.
public enum NextSessionAction: String, Sendable, CaseIterable {
    case askTRON = "ask-tron", copy
    public var label: String { self == .askTRON ? "Ask TRON" : "Copy" }
}

public struct GapWarning: Equatable, Sendable, Identifiable {
    public let kind: GapKind
    public let state: GapState
    public let client: String
    public let text: String
    public let note: String
    public var id: String { "\(kind.rawValue):\(state.rawValue):\(text)" }
    /// Exactly these, in this order, on every warning.
    public static let actions: [NextSessionAction] = [.askTRON, .copy]
    public var actions: [NextSessionAction] { GapWarning.actions }
}

public struct NextSession: Equatable, Sendable {
    public let client: String
    public let scheduledAt: Date
    public let durationMinutes: Int
    public let sessionType: String
    public let today: Bool
}

public struct SinceLastMet: Equatable, Sendable {
    public let state: String              // ok | none | unknown
    public let lastMet: String?
    public let lines: [String]
    public let note: String
}

/// GET /api/peak/next-session, parsed. Rows without a client are dropped (every item names its client).
public enum NextSessionResult: Equatable, Sendable {
    case loaded(session: NextSession?, since: SinceLastMet?, warnings: [GapWarning])
    case signedOut(CommandSignInNotice)          // the existing "Command sign-in expired, tap to sign in" state
    case forbidden(String)                       // 403: dead state, not asked again this run
    case failed(String)

    public var outcome: String {
        switch self {
        case .loaded: return "ok"; case .signedOut: return "expired"; case .forbidden: return "forbidden"; case .failed: return "failed"
        }
    }

    static func clean(_ v: Any?) -> String {
        EngineParse.str(v).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    public static func parse(_ code: Int, _ d: Data) -> NextSessionResult {
        if code == 401 { return .signedOut(CommandSignInNotice()) }
        if code == 403 { return .failed("GOAT refused the next-session feed on this Mac.") }     // the engine's local-only gate
        if code == 404 { return .failed("This Mac's GOAT doesn't have the next-session feed yet.") }
        guard let o = EngineParse.obj(d) else { return .failed("Couldn't read the next session.") }
        if let n = EngineParse.commandSignIn(d) { return .signedOut(n) }
        if EngineParse.str(o["auth"]) == "expired" { return .signedOut(CommandSignInNotice()) }
        if EngineParse.str(o["auth"]) == "forbidden" {
            let m = clean(o["error"])
            return .forbidden(m.isEmpty ? "This Command sign-in can't read the schedule." : String(m.prefix(200)))
        }
        guard code == 200, (o["ok"] as? Bool) == true else {
            let m = clean(o["error"])
            return .failed(m.isEmpty ? "Command didn't answer for the schedule." : String(m.prefix(200)))
        }
        var session: NextSession?
        if let s = o["session"] as? [String: Any], case let c = clean(s["client"]), !c.isEmpty,
           let at = EngineParse.date(EngineParse.str(s["scheduled_at"])) {
            session = NextSession(client: c, scheduledAt: at, durationMinutes: (s["duration_minutes"] as? Int) ?? 60,
                                  sessionType: clean(s["session_type"]), today: (s["today"] as? Bool) ?? false)
        }
        var since: SinceLastMet?
        if session != nil, let s = o["since_last_met"] as? [String: Any] {
            let last = clean(s["last_met"])
            since = SinceLastMet(state: clean(s["state"]), lastMet: last.isEmpty ? nil : last,
                                 lines: EngineParse.strs(s["lines"]).map { String($0.prefix(200)) }.prefix(8).map { $0 },
                                 note: String(clean(s["note"]).prefix(200)))
        }
        var warnings: [GapWarning] = []
        for r in (o["warnings"] as? [Any]) ?? [] {
            guard let x = r as? [String: Any], let k = GapKind(rawValue: EngineParse.str(x["kind"])),
                  let st = GapState(rawValue: EngineParse.str(x["state"])) else { continue }     // "absent" is never a warning
            let c = clean(x["client"]), t = clean(x["text"])
            guard !c.isEmpty, !t.isEmpty else { continue }
            warnings.append(GapWarning(kind: k, state: st, client: c, text: String(t.prefix(200)), note: String(clean(x["note"]).prefix(240))))
        }
        return .loaded(session: session, since: since, warnings: warnings)
    }
}

/// The pill's countdown at minute granularity (the view ticks it every 30 s; no per-second redraw).
public enum NextSessionCountdown {
    public static func text(to start: Date, now: Date) -> String {
        let s = Int(start.timeIntervalSince(now))
        if s < 0 { return -s < 15 * 60 ? "started \((-s) / 60)m ago" : "started" }
        if s < 60 { return "now" }
        let m = s / 60, h = m / 60
        if h >= 24 { return "in \(h / 24)d \(h % 24)h" }
        return h > 0 ? "in \(h)h \(m % 60)m" : "in \(m)m"
    }
}

public extension NextSessionCountdown {
    /// The shortest readable countdown for the Studio Display pill: "now", "42m", "3h 10m", "2d 4h".
    static func compact(to start: Date, now: Date) -> String {
        let s = Int(start.timeIntervalSince(now))
        if s < 60 { return s > -15 * 60 ? "now" : "started" }
        let m = s / 60, h = m / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if h > 0 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        return "\(m)m"
    }
}

/// The next-session feed for this coach, in memory only. Polls sparingly off the app's existing refresh tick.
@MainActor public final class NextSessionModel: ObservableObject {
    nonisolated public static let path = "/api/peak/next-session"
    nonisolated public static let pollInterval: TimeInterval = 300            // every 5 min at most
    nonisolated public static let signedOutInterval: TimeInterval = 1800      // the engine's gate also holds Command back
    @Published public private(set) var result: NextSessionResult?
    @Published public private(set) var showingCard = false
    @Published public private(set) var lastAction: String? = nil
    public let enabled: Bool
    /// This coach's roster (the profile's): anything naming someone else is dropped here too.
    public let roster: [String]
    public private(set) var fetches = 0
    public private(set) var dead = false
    private var nextDue: Date? = nil
    private var inFlight = false
    let transport: ThreePOTransport
    weak var logger: PeakLogging?
    /// Clipboard only (the app's pasteboard; the demo keeps it in memory).
    public var onCopy: ((String) -> Void)?

    public init(transport: ThreePOTransport, enabled: Bool, roster: [String], logger: PeakLogging? = nil) {
        self.transport = transport; self.enabled = enabled; self.roster = roster; self.logger = logger
    }

    func mine(_ name: String) -> Bool {
        let n = DirectoryMatcher.normalize(name)
        return !n.isEmpty && roster.contains { DirectoryMatcher.normalize($0) == n }
    }

    /// One GET when enabled and due. Returns whether a request went out. Flag off: never.
    @discardableResult
    public func tick(now: Date = Date()) async -> Bool {
        guard enabled, !dead, !inFlight else { return false }
        if let d = nextDue, now < d { return false }
        inFlight = true; defer { inFlight = false }
        fetches += 1
        let (code, data) = await transport.get(Self.path)
        var r = NextSessionResult.parse(code, data)
        if case let .loaded(s, since, ws) = r {                       // roster scoping (belt and braces after the engine)
            let keep = s.map { mine($0.client) } ?? false
            r = .loaded(session: keep ? s : nil, since: keep ? since : nil, warnings: ws.filter { mine($0.client) })
        }
        result = r
        switch r {
        case .loaded, .failed: nextDue = now.addingTimeInterval(Self.pollInterval)
        case .signedOut: nextDue = now.addingTimeInterval(Self.signedOutInterval)
        case .forbidden: dead = true
        }
        if case .loaded = r {} else if showingCard { showingCard = false }
        logger?.log(logLine)
        return true
    }

    public var session: NextSession? { if case let .loaded(s, _, _) = result { return s }; return nil }
    public var since: SinceLastMet? { if case let .loaded(_, x, _) = result { return x }; return nil }
    public var warnings: [GapWarning] { if case let .loaded(_, _, w) = result { return w }; return [] }
    /// Gold when any gap is present ("unknown" alone stays green).
    public var gold: Bool { warnings.contains { $0.state == .present } }
    /// The pill shows only with the flag on and a session for one of this coach's clients.
    public var showsPill: Bool { enabled && session != nil }

    /// The Studio pill is ~196 pt wide: the first name and a compact countdown ("Spiros 3h 10m"), never an ellipsis over the time.
    public func compactPillText(now: Date) -> String? {
        guard let s = session else { return nil }
        return "\(WingStatus.firstName(s.client, limit: 9)) \(NextSessionCountdown.compact(to: s.scheduledAt, now: now))"
    }

    public func pillText(now: Date) -> String? {
        guard let s = session else { return nil }
        return "\(s.client) \(NextSessionCountdown.text(to: s.scheduledAt, now: now))"
    }

    public var logLine: String {
        let w = warnings
        return "next-session outcome=\(result?.outcome ?? "none") session=\(session != nil ? "yes" : "no") gaps=\(w.filter { $0.state == .present }.count) unknown=\(w.filter { $0.state == .unknown }.count) gold=\(gold ? "yes" : "no") fetches=\(fetches)"
    }

    /// A tap on the pill only opens the one-glance card (client, time, since last met, warnings). Nothing runs.
    public func openCard() { guard showsPill else { return }; showingCard = true; lastAction = nil; logger?.log("next-session card open") }
    public func closeCard() { showingCard = false; lastAction = nil }

    static func when(_ d: Date) -> String { DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short) }

    /// The prompt Ask TRON copies: what Peek saw, read-only, for TRON to advise on. Nothing is sent from Peek.
    public func tronPrompt(_ w: GapWarning) -> String {
        var lines = ["TRON, Peek flagged a gap (read-only check; nothing was sent or changed):",
                     "Client: \(w.client)", "Gap: \(w.text) [\(w.state.rawValue)]"]
        if !w.note.isEmpty { lines.append("Note: \(w.note)") }
        if let s = session, s.client == w.client { lines.append("Session: \(Self.when(s.scheduledAt)), \(s.durationMinutes) min") }
        lines.append("What should I do? Don't contact the family and don't change any booking or invoice without my OK.")
        return lines.joined(separator: "\n")
    }

    public func copyText(_ w: GapWarning) -> String { w.note.isEmpty ? w.text : "\(w.text). \(w.note)" }

    /// The only path to an action: Ask TRON or Copy on one warning. Clipboard only.
    @discardableResult
    public func perform(_ a: NextSessionAction, on w: GapWarning) -> String {
        guard w.actions.contains(a), warnings.contains(w) else { lastAction = "Not available."; return lastAction! }
        switch a {
        case .askTRON: onCopy?(tronPrompt(w)); lastAction = "Prompt for TRON copied. Paste it to TRON; nothing was sent."
        case .copy: onCopy?(copyText(w)); lastAction = "Copied. Nothing was sent."
        }
        logger?.log("next-session action=\(a.rawValue) kind=\(w.kind.rawValue) state=\(w.state.rawValue)")
        return lastAction!
    }
}

public extension DemoData {
    /// A mocked GET /api/peak/next-session (fake clients only): a session in 42 min today, the export unknown (Command has
    /// no endpoint), the invoice for today's session missing, one invoice unpaid 9 days, and one row for a client who is
    /// not on the demo roster (dropped by the roster filter).
    static func nextSessionJSON(now: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        let at = f.string(from: now.addingTimeInterval(42 * 60))
        return #"{"ok":true,"session":{"client":"Sample Skater","scheduled_at":"\#(at)","starts_in_s":2520,"duration_minutes":60,"session_type":"Breakdown","today":true},"since_last_met":{"state":"ok","last_met":"2026-10-12","lines":["Last met 2026-10-12.","2 games since then.","1 G, 1 A, 2 P since last met.","Latest: 2026-10-18 vs Demo Wolves, L 1-3."],"note":""},"warnings":[{"kind":"export_missing","state":"unknown","client":"Sample Skater","text":"Breakdown export for Sample Skater's session today: unknown","note":"Unknown: Command has no read endpoint for breakdown exports yet, so Peek can't tell. Requested from Command via TRON."},{"kind":"invoice_missing","state":"present","client":"Sample Skater","text":"Invoice missing for Sample Skater's session today","note":""},{"kind":"invoice_unpaid","state":"present","client":"Demo Player","text":"Demo Player: invoice unpaid 9 days ($400.00)","note":""},{"kind":"invoice_unpaid","state":"present","client":"Test Client Other","text":"Test Client Other: invoice unpaid 12 days ($400.00)","note":""}],"checks":{"export_missing":"unknown","invoice_missing":"present","invoice_unpaid":"present"}}"#
    }
}

/// The pill's look, from the brand tokens only (never a hex here: the palette moves in its own PR). White text on black;
/// the outline and its glow (a shape, never text) are gold while any gap is present, else green.
public enum NextSessionStyle {
    public static let textHex = Brand.whiteHex
    public static let goldHex = Brand.goldHex
    public static let okHex = Brand.greenHex
    public static let textOpacity: Double = 1.0
    /// The local countdown redraws this often (minute granularity text; nothing animates between ticks).
    public static let tickSeconds: Double = 30
    public static func outlineHex(gold: Bool) -> UInt32 { gold ? goldHex : okHex }
}

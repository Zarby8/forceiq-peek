import Foundation
import Combine

/// How 3PO reaches the local engine (app: EngineClient on 127.0.0.1; demo: a scripted turn; tests: a fake).
public protocol ThreePOTransport: Sendable {
    func stream(_ body: Data) -> AsyncStream<ThreePOEvent>
    func get(_ path: String) async -> (Int, Data)
    func post(_ path: String, _ body: Data) async -> (Int, Data)
}

/// A proposal's lifecycle in Peak. Describe first; Run = GOAT's preview; Confirm = a second explicit tap.
public enum ProposalPhase: Equatable, Sendable {
    case described
    case previewing
    case previewed(String)
    case confirming
    case done(String)
    case failed(String)
}

@MainActor public final class ThreePOStore: ObservableObject {
    @Published public private(set) var transcript = ThreePOTranscript()
    @Published public var draft = ""
    @Published public private(set) var phases: [String: ProposalPhase] = [:]
    @Published public private(set) var approvedPops = 0
    /// The mic is open (the voice module sets it; voice is behind its profile flag, off by default). Drives 'listening'.
    @Published public var micOn = false
    public var onOpenApp: ((String) -> Void)?           // intent open_app → the switcher (allow-listed apps only)
    public var onCopy: ((String) -> Void)?
    let transport: ThreePOTransport
    let session: String
    weak var logger: PeakLogging?
    var throttle: SpendThrottle

    public init(transport: ThreePOTransport, session: String = "peak", spendInterval: TimeInterval = 60, logger: PeakLogging? = nil) {
        self.transport = transport; self.session = session; self.logger = logger
        throttle = SpendThrottle(interval: spendInterval)
    }

    public var pick: ModelPick { transcript.models.pick }
    public var canSend: Bool { !transcript.streaming && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// An explicit send (Return / the send button). Text goes only to this Mac's engine.
    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        draft = ""
        await turn(text)
    }

    func turn(_ text: String) async {
        transcript.begin(text)
        logger?.log("3po send pick=\(pick.rawValue)")
        let body = (try? JSONSerialization.data(withJSONObject: ["text": text, "session": session, "model": pick.rawValue])) ?? Data()
        for await e in transport.stream(body) {
            transcript.apply(e)
            switch e {
            case .proposal(let c): if phases[c.id] == nil { phases[c.id] = .described }
            case .intent(let n, let app): if n == "open_app", let app { onOpenApp?(app) }
            case .done: logger?.log("3po done")
            case .error(let code, _): logger?.log("3po error code=\(code)")
            default: break
            }
        }
        transcript.endOfStream()
    }

    // ── models ──
    public func loadModels() async {
        let (c, d) = await transport.get("/api/3po/models")
        if c == 200, let m = ThreePOEvent.parseModels(d) { transcript.models = m }
    }

    /// ⌘0 Auto, ⌘1 Haiku, ⌘2 Sonnet, ⌘3 Opus. Unavailable models can't be picked.
    public func choose(_ p: ModelPick) async {
        guard p != pick, transcript.models.row(p)?.available ?? false else { return }
        let before = pick
        transcript.models.pick = p
        logger?.log("3po pick=\(p.rawValue)")
        let (c, d) = await transport.post("/api/3po/model", (try? JSONSerialization.data(withJSONObject: ["pick": p.rawValue])) ?? Data())
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if c != 200 || (o?["ok"] as? Bool) != true {
            transcript.models.pick = ModelPick(rawValue: (o?["pick"] as? String) ?? "") ?? before
        }
    }

    // ── spend (engine-cached; this asks at most once a minute) ──
    public func refreshSpend(now: Date = Date()) async {
        guard throttle.shouldFetch(now: now) else { return }
        let (c, d) = await transport.get("/api/3po/spend")
        if c == 200, let s = SpendDoc.parse(d) { transcript.spend = s }
    }

    // ── proposals: describe → Run (GOAT preview) → Confirm. Nothing runs without both taps. ──
    public func card(_ id: String) -> ProposalCard? {
        for m in transcript.messages.reversed() { if let c = m.proposals.first(where: { $0.id == id }) { return c } }
        return nil
    }

    public func run(_ id: String) async {
        guard let c = card(id), !c.viewOnly, let body = c.previewBody, phases[id] == .described || isFailed(id) else { return }
        phases[id] = .previewing
        logger?.log("3po proposal preview action=\(c.action)")
        let (code, d) = await transport.post("/api/act", body)
        phases[id] = code == 200 ? .previewed(Self.message(d, fallback: "GOAT's preview is ready. Confirm to run it.")) : .failed("GOAT didn't answer. Nothing ran.")
    }

    public func confirm(_ id: String) async {
        guard let c = card(id), !c.viewOnly, let body = c.confirmBody, case .previewed = phases[id] else { return }
        phases[id] = .confirming
        logger?.log("3po proposal confirm action=\(c.action)")
        let (code, d) = await transport.post("/api/act", body)
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if code == 200 && (o?["ok"] as? Bool) != false {
            phases[id] = .done(Self.message(d, fallback: "Done.")); approvedPops += 1
        } else {
            phases[id] = .failed(Self.message(d, fallback: "GOAT didn't run it."))
        }
    }

    public func cancel(_ id: String) { if phases[id] != nil { phases[id] = .described } }

    public func ask(_ id: String) async {
        guard let c = card(id), !transcript.streaming else { return }
        await turn("Before I run anything: explain this proposal (\(c.label)\(c.client.map { " for \($0)" } ?? "")), what it touches, and what could go wrong.")
    }

    public func copy(_ id: String) { if let c = card(id) { onCopy?(ProposalPolicy.prompt(c)) } }

    func isFailed(_ id: String) -> Bool { if case .failed = phases[id] { return true }; return false }

    static func message(_ d: Data, fallback: String) -> String {
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        let m = (o?["message"] as? String) ?? (o?["summary"] as? String) ?? ""
        return m.isEmpty ? fallback : String(m.prefix(300))
    }
}

/// Screenshots / the visual proof: a scripted turn, no engine, no tokens.
/// Knobs the demo tour turns (spend normal → 80 % gold; shift-download steps). Demo only.
public final class DemoKnobs: @unchecked Sendable {
    public var spendWarn = false
    public var statusReads = 0
    public var slowTurn = false          // the 3PO avatar tour: a longer think + a slower stream so every state shows
    public var quickTurn = false         // the 3PO send-latency tour: a short solo turn (think, stream, done; no card)
    public var flipTurn = false          // … with thinking ⇄ talking flips 60 ms apart (the coalescing check)
    public init() {}
}

public struct DemoThreePOTransport: ThreePOTransport {
    public let knobs: DemoKnobs
    public init(knobs: DemoKnobs = DemoKnobs()) { self.knobs = knobs }
    public func stream(_ body: Data) -> AsyncStream<ThreePOEvent> {
        AsyncStream { cont in
            let task = Task {
                var t0: TimeInterval = 0
                let script = knobs.quickTurn ? DemoData.threePOQuickTurn(flip: knobs.flipTurn) : DemoData.threePOTurn(slow: knobs.slowTurn)
                for (at, e) in script {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, at - t0) * 1_000_000_000)); t0 = at
                    cont.yield(e)
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
    public func get(_ path: String) async -> (Int, Data) {
        if path == "/api/3po/models" {
            return (200, Data(#"{"pick":"haiku","models":[{"alias":"haiku","label":"Haiku 5.5","available":true},{"alias":"sonnet","label":"Sonnet 5.5","available":true},{"alias":"opus","label":"Opus 5.5","available":true}]}"#.utf8))
        }
        if path == "/api/3po/spend", !knobs.spendWarn {
            return (200, Data(#"{"budget_usd":250,"warn_at":0.8,"show_account_line":true,"account":{"total_usd":118.6,"budget_usd":250,"warn":false,"by_model":{"opus":52.4,"sonnet":38.2,"haiku":19.5,"other":8.5}},"peak":{"total_usd":12.34,"budget_usd":250,"warn":false,"by_model":{"haiku":{"usd":9.24},"opus":{"usd":3.1}}},"hint":null}"#.utf8))
        }
        if path.hasPrefix("/api/peak/shift-drop/status/") {
            let steps = ["waiting", "identified", "staged", "running", "succeeded"]
            let s = steps[min(knobs.statusReads, steps.count - 1)]; knobs.statusReads += 1
            let msg = ["waiting": "Waiting for the shifts watcher.", "identified": "Identified; staging next.", "staged": "Staged for Dagu.",
                       "running": "Dagu run is running.", "succeeded": "Shift download finished."][s]!
            return (200, Data(#"{"ok":true,"state":"\#(s)","message":"\#(msg)"}"#.utf8))
        }
        if path == "/api/3po/spend" {
            return (200, Data(#"{"budget_usd":250,"warn_at":0.8,"show_account_line":true,"account":{"total_usd":211.4,"budget_usd":250,"warn":true,"by_model":{"opus":96.1,"sonnet":71.25,"haiku":30.05,"other":14.0}},"peak":{"total_usd":12.34,"budget_usd":250,"warn":false,"by_model":{"haiku":{"usd":9.24},"opus":{"usd":3.1}}},"hint":null}"#.utf8))
        }
        return (404, Data())
    }
    public func post(_ path: String, _ body: Data) async -> (Int, Data) {
        if path == "/api/3po/model" { return (200, Data(#"{"ok":true}"#.utf8)) }
        if path == "/api/act" { return (200, Data(#"{"ok":true,"message":"Demo mode: nothing ran."}"#.utf8)) }
        if path == "/api/peak/shift-drop/preview" {
            try? await Task.sleep(nanoseconds: 700_000_000)
            return (200, Data(#"{"ok":true,"token":"0123456789ac","kind":"shift","valid":true,"client":{"name":"Sample Skater"},"opponent":"Demo Hawks","game":1,"date":"10.18.2026","name":"SampleSkater_DemoHawks_10.18.2026.mp4","problems":[],"target_exists":false,"description":"Sample Skater vs Demo Hawks, 10.18.2026. Places an APFS clone of this film in ForceIQ Shifts for the shifts watcher; your original stays where it is. Undo removes the clone."}"#.utf8))
        }
        if path.hasSuffix("/preview") {
            try? await Task.sleep(nanoseconds: 700_000_000)
            return (200, Data(#"{"ok":true,"token":"0123456789ab","client":"Sample Skater","ready":true,"valid":true,"description":"Sample Skater vs Demo Hawks, 10.18.2026. Re-renders the title slide and folder image through the normal title pipeline and shows before and after. Apply replaces title.png, folder.png; every replaced file is backed up first and Undo puts it back."}"#.utf8))
        }
        if path.hasSuffix("/apply") || path.hasSuffix("/undo") {
            let confirmed = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["confirm"] as? Bool == true
            return (200, Data((confirmed ? #"{"ok":true,"message":"Demo mode: nothing changed."}"# : #"{"ok":true,"needs_confirm":true,"confirm_text":"Demo: confirm to apply (nothing changes in demo mode)."}"#).utf8))
        }
        return (404, Data())
    }
}

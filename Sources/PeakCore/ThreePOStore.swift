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
    /// Skill cards: described until the card's own Run tap (skillPhases[id] = .running), then done or failed.
    @Published public private(set) var skillPhases: [String: SkillPhase] = [:]
    /// The 3PO tab's two panes: the chat and this coach's memory (engine/threepo_memory.py, plain local files).
    public enum Pane: String, Sendable { case chat, memory }
    @Published public var pane: Pane = .chat
    @Published public private(set) var memory = MemoryDoc()
    @Published public private(set) var memoryLoad: MemoryLoad = .idle
    @Published public var showForgotten = false
    @Published public private(set) var forgetting: Set<String> = []
    /// The mic is open (the voice module sets it; voice is behind its profile flag, off by default). Drives 'listening'.
    @Published public var micOn = false
    public var onOpenApp: ((String) -> Void)?           // intent open_app → the switcher (allow-listed apps only)
    public var onCopy: ((String) -> Void)?
    /// Client commands ("Open <client>'s FLOW package…", "Start a meeting with <client>"): the roster, the next meeting and
    /// the flags. nil = commands off (everything goes to 3PO).
    public var commandContext: (() -> ClientCommandContext?)?
    /// Run on a command card (an explicit tap): opens Command's UI / brings FLOW forward; returns the line to show.
    public var onCommandRun: ((ProposalCard) -> String)?
    var pendingPicks: [String: ClientCommand] = [:]
    /// Command meeting link (flag on): a pick card's button labels → the directory client each one stands for.
    var pendingLinkPicks: [String: (ClientCommand, [String: DirectoryClient])] = [:]
    /// This coach's Command directory, in memory only, briefly (DirectoryCache). Read only with the flag on.
    public let directory = DirectoryCache()
    /// The engine said the Command sign-in is dead: surface the existing sign-in row (Peak's home). Never a retry loop.
    public var onCommandSignIn: ((CommandSignInNotice) -> Void)?
    var localSeq = 0
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
        if let ctx = commandContext?(), let cmd = ClientCommands.parse(text) {
            if cmd.kind == .startMeeting && ctx.usesMeetingLink {
                await meetingLink(cmd, ctx, said: text)
            } else {
                local(cmd, ctx, said: text)
            }
            return
        }
        await turn(text)
    }

    /// forceiq-peak://ask?q=… lands here, whether the chat is open or collapsed: the text goes in the field and the Chat
    /// pane shows. NEVER sent: only an explicit tap (Return / the send button) calls send(). Logs the event name only.
    public func prefill(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = t
        if pane != .chat { pane = .chat }
        logger?.log("3po prefill")
    }

    /// The dictated words, handed over exactly like a typed message (draft → send). If 3PO is mid-reply, they wait in the
    /// field for the coach to send.
    public func sendDictation(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = t
        logger?.log("3po dictation words=\(t.split(separator: " ").count)")
        if canSend { await send() }
    }

    func nextLocalID() -> String { localSeq += 1; return String(format: "cmd%09d", localSeq) }

    func local(_ cmd: ClientCommand, _ ctx: ClientCommandContext, said: String?) {
        let r = ClientCommands.route(cmd, ctx, id: nextLocalID())
        transcript.local(user: said, reply: r.reply, cards: [r.card])
        phases[r.card.id] = .described
        if r.card.origin == .pick { pendingPicks[r.card.id] = cmd }
        logger?.log("3po command kind=\(cmd.kind.rawValue) card=\(r.card.origin.rawValue) local=1")
    }

    /// "Start a meeting with <client>" with the Command meeting link on: resolve the name in this coach's Command
    /// directory (one GET through the engine unless a fresh copy is in memory). Exact + unique → the link card; several,
    /// partial or fuzzy → a pick card; none → not found; a directory problem → one plain card. Nothing opens here: only an
    /// explicit Run tap on the link card does. Logs carry counts and the outcome only (never a name or an id).
    func meetingLink(_ cmd: ClientCommand, _ ctx: ClientCommandContext, said: String?) async {
        let (dir, cached) = await directory.load(transport)
        let id = nextLocalID()
        guard case .clients(let clients, let dropped) = dir, !clients.isEmpty else {
            let c = ClientCommands.directoryProblemCard(cmd, dir, id: id)
            transcript.local(user: said, reply: c.reason, cards: [c])
            phases[c.id] = .described
            if case .signedOut(let n) = dir { onCommandSignIn?(n) }
            logger?.log("3po meeting-link directory=\(dir.outcome) cached=\(cached ? 1 : 0)")
            return
        }
        let m = DirectoryMatcher.match(cmd.spokenClient, in: clients)
        logger?.log("3po meeting-link match=\(m.outcome) clients=\(clients.count) dropped=\(dropped) candidates=\(Self.count(m)) cached=\(cached ? 1 : 0)")
        switch m {
        case .unique(let client):
            if let c = ClientCommands.meetingLinkCard(cmd, client: client, ctx, id: id, exact: true) {
                transcript.local(user: said, reply: "Here's what that does for \(client.displayName). Nothing opens until you tap Run.", cards: [c])
                phases[c.id] = .described
            } else {
                let c = ClientCommands.notFoundCard(cmd, id: id)
                transcript.local(user: said, reply: c.reason, cards: [c]); phases[c.id] = .described
            }
        case .ambiguous(let list):
            let labels = DirectoryMatcher.labels(list)
            let c = ClientCommands.meetingLinkPickCard(cmd, labels: labels.map(\.0), id: id)
            transcript.local(user: said, reply: list.count > 1 ? "More than one client could be \u{201C}\(cmd.spokenClient)\u{201D}. Which one?"
                                                               : "Is this the client you meant? Pick to continue.", cards: [c])
            phases[c.id] = .described
            pendingLinkPicks[c.id] = (cmd, Dictionary(labels, uniquingKeysWith: { a, _ in a }))
        case .none:
            let c = ClientCommands.notFoundCard(cmd, id: id)
            transcript.local(user: said, reply: c.reason, cards: [c])
            phases[c.id] = .described
        }
    }

    static func count(_ m: DirectoryMatch) -> Int {
        switch m { case .unique: return 1; case .ambiguous(let l): return l.count; case .none: return 0 }
    }

    /// A pick card's client tapped: the confirm card for that client (nothing runs).
    public func pickClient(_ id: String, _ client: String) {
        if let pend = pendingLinkPicks[id] {
            let (cmd, map) = pend
            guard phases[id] == .described, let picked = map[client], let ctx = commandContext?() else { return }
            pendingLinkPicks[id] = nil
            phases[id] = .done("Picked \(picked.displayName).")
            guard let c = ClientCommands.meetingLinkCard(cmd, client: picked, ctx, id: nextLocalID(), exact: false) else { return }
            transcript.local(user: nil, reply: "Here's what that does for \(picked.displayName). Nothing opens until you tap Run.", cards: [c])
            phases[c.id] = .described
            logger?.log("3po meeting-link picked=1")
            return
        }
        guard let cmd = pendingPicks[id], let ctx = commandContext?(), phases[id] == .described else { return }
        pendingPicks[id] = nil
        phases[id] = .done("Picked \(client).")
        let c = ClientCommands.card(cmd, client: client, ctx, id: nextLocalID())
        transcript.local(user: nil, reply: "Here's what that does for \(client). Nothing runs until you tap Run.", cards: [c])
        phases[c.id] = .described
        logger?.log("3po command kind=\(cmd.kind.rawValue) card=command picked=1")
    }

    func turn(_ text: String, body custom: Data? = nil) async {
        transcript.begin(text)
        logger?.log("3po send pick=\(pick.rawValue)")
        let body = custom ?? (try? JSONSerialization.data(withJSONObject: ["text": text, "session": session, "model": pick.rawValue])) ?? Data()
        var memoryChanged = false
        for await e in transport.stream(body) {
            transcript.apply(e)
            switch e {
            case .proposal(let c): if phases[c.id] == nil { phases[c.id] = .described }
            case .skill(let c): if skillPhases[c.id] == nil { skillPhases[c.id] = .described }
            case .memory(let m): if m.op != "list" && (m.status == "saved" || m.status == "forgotten") { memoryChanged = true }
            case .intent(let n, let app): if n == "open_app", let app { onOpenApp?(app) }
            case .done: logger?.log("3po done")
            case .error(let code, _): logger?.log("3po error code=\(code)")
            default: break
            }
        }
        transcript.endOfStream()
        if memoryChanged { await loadMemory() }
    }

    // ── memory: view + soft forget (the file is never deleted) ──
    public func loadMemory() async {
        memoryLoad = .loading
        let (c, d) = await transport.get("/api/3po/memory")
        if c == 200, let m = MemoryDoc.parse(d) { memory = m; memoryLoad = .loaded } else { memoryLoad = .failed("Couldn't read 3PO's memory on this Mac.") }
    }

    /// An explicit Forget tap. Soft: the engine marks the fact forgotten; nothing is deleted.
    public func forget(_ id: String) async {
        guard let f = memory.facts.first(where: { $0.id == id }), !f.forgotten, !forgetting.contains(id) else { return }
        forgetting.insert(id)
        logger?.log("3po memory forget")
        let (c, d) = await transport.post("/api/3po/memory", (try? JSONSerialization.data(withJSONObject: ["op": "forget", "id": id])) ?? Data())
        forgetting.remove(id)
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if c == 200 && (o?["ok"] as? Bool) == true, let i = memory.facts.firstIndex(where: { $0.id == id }) {
            memory.facts[i].forgotten = true
        }
        await loadMemory()
    }

    /// Tap-to-pick when a remembered fact's client was unclear: re-sends the same fact with the picked roster client.
    public func pickMemoryClient(_ client: String, for messageID: Int) async {
        guard !transcript.streaming, let m = transcript.messages.first(where: { $0.id == messageID }), let ev = m.memory, ev.needsPick,
              ev.candidates.contains(client), let text = ev.text, !text.isEmpty else { return }
        let body = try? JSONSerialization.data(withJSONObject: ["text": "remember \(text)", "client": client, "session": session, "model": pick.rawValue])
        await turn("Remember for \(client): \(text)", body: body)
    }

    // ── skill cards: description → Run (explicit tap) ──
    public func skillCard(_ id: String) -> SkillCard? {
        for m in transcript.messages.reversed() { if let c = m.skills.first(where: { $0.id == id }) { return c } }
        return nil
    }

    public func runSkill(_ id: String) async {
        guard !transcript.streaming, let c = skillCard(id), c.canRun, skillPhases[id] == .described || isSkillFailed(id),
              let body = SkillPolicy.runBody(c, session: session, pick: pick) else { return }
        skillPhases[id] = .running
        logger?.log("3po skill run kind=\(c.kind)")
        await turn("Run: \(c.name)", body: body)
        let reply = transcript.messages.last(where: { $0.role == .threePO })
        skillPhases[id] = (reply?.error).map { .failed($0) } ?? .done
    }

    public func pickSkillClient(_ id: String, client: String) async {
        guard !transcript.streaming, let c = skillCard(id), let body = SkillPolicy.pickBody(c, client: client, session: session, pick: pick) else { return }
        await turn("\(c.name) for \(client)", body: body)
    }

    /// Ask for a skill's DESCRIPTION card by slug (the /skills list, the snapshot). Never sets "run".
    public func describeSkill(_ slug: String) async {
        guard !transcript.streaming, !slug.isEmpty else { return }
        let body = try? JSONSerialization.data(withJSONObject: ["text": "/skill \(slug)", "session": session, "model": pick.rawValue, "skill": slug])
        await turn("/skill \(slug)", body: body)
    }

    public func askSkill(_ id: String) async {
        guard let c = skillCard(id), !transcript.streaming else { return }
        await turn(SkillPolicy.askText(c))
    }

    public func copySkill(_ id: String) { if let c = skillCard(id) { onCopy?(c.prompt) } }

    func isSkillFailed(_ id: String) -> Bool { if case .failed = skillPhases[id] { return true }; return false }

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
        if let c = card(id), c.origin == .command {               // Peak's own command card: one explicit tap opens the UI
            guard !c.viewOnly, phases[id] == .described || isFailed(id) else { return }
            logger?.log("3po command run action=\(c.action)")
            phases[id] = .done(onCommandRun?(c) ?? "Nothing ran.")
            return
        }
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
        if path == "/api/3po/memory" {
            return (200, Data(#"{"ok":true,"owner":"demo","facts":[{"id":"m_demo00000001","text":"Sample Skater's games are on Saturdays","client":"Sample Skater","clients":["Sample Skater"],"ts":"2026-10-19T02:30:00-04:00","forgotten":false},{"id":"m_demo00000002","text":"the NAS is slow on Monday mornings","client":null,"clients":[],"ts":"2026-10-18T09:00:00-04:00","forgotten":false},{"id":"m_demo00000003","text":"Sample Skater prefers early ice","client":"Sample Skater","clients":["Sample Skater"],"ts":"2026-10-12T09:00:00-04:00","forgotten":true,"forgotten_at":"2026-10-18T10:00:00-04:00"}]}"#.utf8))
        }
        if path == DirectoryCache.path {            // the meeting-link smoke: a mocked Command directory, fake clients only
            return (200, Data(DemoData.directoryJSON.utf8))
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
        if path == "/api/3po/memory" { return (200, Data(#"{"ok":true,"status":"forgotten","message":"Demo mode: nothing changed."}"#.utf8)) }
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

public extension DemoData {
    /// A mocked GET /api/peak/client-directory (generated UUIDs, obviously fake names). One row has a non-UUID id and is
    /// dropped by the parser; one id has stray case / whitespace and is normalised.
    static let directoryJSON = #"{"ok":true,"count":4,"dropped":0,"clients":[{"id":" 756D57AD-2DED-4D28-B704-EDFFF0137BC7 ","display_name":"Test Client Alpha"},{"id":"c8191fda-c7f4-410e-ad9e-e8d3fca3f17b","display_name":"Test Client Bravo"},{"id":"c56788b1-9a49-4633-aaf9-3d2054a225b3","display_name":"Test Client Charlie"},{"id":"client-42","display_name":"Test Client Delta"}]}"#
}

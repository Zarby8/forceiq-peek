import Foundation

// ForceIQ Peek 3PO: the client side of engine/threepo.py's SSE contract (POST /api/3po/stream; GET /api/3po/models|spend).
// Pure logic, unit-tested: the SSE parser, the event decoder, the transcript reducer, model picks, the proposal policy
// and the spend meter. Nothing here talks to the network or runs a card.

// ───────────────────────────── SSE ─────────────────────────────
/// Incremental text/event-stream parser: feed bytes as they arrive, get complete (event, data) frames.
public struct SSEParser: Sendable {
    private var buffer = Data()
    private var event = ""
    private var data: [String] = []
    public init() {}

    public mutating func feed(_ chunk: Data) -> [(event: String, data: String)] {
        buffer.append(chunk)
        var out: [(String, String)] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            let line = String(decoding: lineData, as: UTF8.self)
            if line.isEmpty {
                if !data.isEmpty { out.append((event.isEmpty ? "message" : event, data.joined(separator: "\n"))) }
                event = ""; data = []
            } else if line.hasPrefix(":") {
                continue
            } else if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                var v = String(line.dropFirst(5)); if v.hasPrefix(" ") { v.removeFirst() }
                data.append(v)
            }
        }
        return out
    }
}

// ───────────────────────────── model picks (Auto + Haiku / Sonnet / Opus solo; ⌘0 / ⌘1 / ⌘2 / ⌘3) ─────────────────────────────
public enum ModelPick: String, CaseIterable, Sendable {
    case auto, haiku, sonnet, opus
    public var defaultLabel: String { ["auto": "Auto", "haiku": "Haiku", "sonnet": "Sonnet", "opus": "Opus"][rawValue]! }
    /// The ⌘ digit (engine/claude.json shortcuts are cmd+1/2/3 for the solo picks; Auto is ⌘0).
    public var digit: Character { ["auto": "0", "haiku": "1", "sonnet": "2", "opus": "3"][rawValue]! }
    public static func forDigit(_ c: Character) -> ModelPick? { allCases.first { $0.digit == c } }
}

public struct ModelRow: Equatable, Sendable {
    public var pick: ModelPick
    public var label: String
    public var available: Bool
    public var reason: String?
    public init(pick: ModelPick, label: String, available: Bool, reason: String? = nil) {
        self.pick = pick; self.label = label; self.available = available; self.reason = reason
    }
}

public struct ModelsDoc: Equatable, Sendable {
    public var pick: ModelPick = .haiku          // TRON 10/19: Haiku solo by default (Auto's first token ~15 s); Auto is one tap away
    public var rows: [ModelRow] = ModelPick.allCases.map { ModelRow(pick: $0, label: $0.defaultLabel, available: $0 == .auto) }
    public init() {}
    public func row(_ p: ModelPick) -> ModelRow? { rows.first { $0.pick == p } }
}

// ───────────────────────────── proposals (describe-first; Run = /api/act preview, then confirm) ─────────────────────────────
public struct ProposalCard: Equatable, Sendable, Identifiable {
    public var id: String
    public var action: String
    public var label: String
    public var client: String?
    public var inputs: [String]          // "key: value", sorted
    public var touches: String
    public var outputs: [String]
    public var reason: String
    public var message: String
    public var status: String
    public var viewOnly: Bool
    public var previewBody: Data?        // POST /api/act body without confirm (GOAT's own preview)
    public var confirmBody: Data?        // POST /api/act body with confirm:true (only after the preview, on a second tap)
    /// engine: a 3PO proposal (Run = GOAT's /api/act preview, then Confirm). command: a client voice/typed command Peek
    /// recognised itself (Run opens `link` / brings `appName` forward, nothing else). pick: "which client?" (`picks`).
    public enum Origin: String, Sendable { case engine, command, pick }
    public var origin: Origin = .engine
    public var link: String? = nil       // command: the deep link Run opens (Command's room page / schedule; CommandLink-checked)
    public var appName: String? = nil    // command: the allow-listed app Run brings forward (FLOW)
    public var picks: [String] = []      // pick: the candidate clients, best first
}

public enum ProposalPolicy {
    /// Never from 3PO, whatever the engine says: sends, deletes, money, bookings, DB edits, deploys.
    static let danger = try! NSRegularExpression(pattern: #"(?i)send|e-?mail|text|sms|delete|remove|purge|trash|invoice|bill|charge|pay|refund|book|schedul|deploy|publish|release|db|database|sql|migrat|drop"#)

    public static func isDangerous(_ action: String) -> Bool {
        danger.firstMatch(in: action, range: NSRange(action.startIndex..., in: action)) != nil
    }

    /// The card Peek shows. Run exists only for a routine heal that goes through GOAT's own /api/act preview → confirm.
    public static func card(from o: [String: Any]) -> ProposalCard? {
        guard let id = o["id"] as? String, let action = o["action"] as? String, !id.isEmpty, !action.isEmpty else { return nil }
        func str(_ v: Any?) -> String {
            switch v { case let s as String: return s; case let n as NSNumber: return n.stringValue; case nil, is NSNull: return ""
            default: return (try? JSONSerialization.data(withJSONObject: v!, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        }
        let inputs = ((o["inputs"] as? [String: Any]) ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \(str($0.value))" }
        let outputs: [String] = (o["outputs"] as? [Any])?.map { str($0) } ?? ((o["outputs"] as? String).map { [$0] } ?? [])
        var preview: Data?, confirm: Data?
        if let run = o["run"] as? [String: Any], (run["route"] as? String) == "/api/act",
           let p = run["preview"] as? [String: Any], let c = run["confirm"] as? [String: Any],
           (p["confirm"] as? Bool) != true, (c["confirm"] as? Bool) == true, (p["name"] as? String) == action, (c["name"] as? String) == action {
            preview = try? JSONSerialization.data(withJSONObject: p, options: [.sortedKeys])
            confirm = try? JSONSerialization.data(withJSONObject: c, options: [.sortedKeys])
        }
        let engineViewOnly = (o["view_only"] as? Bool) ?? true
        let viewOnly = engineViewOnly || preview == nil || isDangerous(action) || (o["executed"] as? Bool) == true
        let client = (o["client"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ProposalCard(id: id, action: action, label: str(o["label"]).isEmpty ? action : str(o["label"]), client: client,
                            inputs: inputs, touches: str(o["touches"]), outputs: outputs, reason: str(o["reason"]),
                            message: str(o["message"]), status: str(o["status"]), viewOnly: viewOnly,
                            previewBody: viewOnly ? nil : preview, confirmBody: viewOnly ? nil : confirm)
    }

    public static func prompt(_ c: ProposalCard) -> String {
        """
        3PO proposal (\(c.action)) for \(c.client ?? "no client named"): \(c.label).
        Why: \(c.reason)
        Inputs: \(c.inputs.joined(separator: "; "))
        Touches: \(c.touches)
        Outputs: \(c.outputs.joined(separator: "; "))
        Rule: nothing that sends, deletes, invoices, books, edits a database or deploys runs without my explicit OK in GOAT.
        """
    }
}

// ───────────────────────────── spend meter ─────────────────────────────
public struct SpendDoc: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public var totalUSD: Double
        public var budgetUSD: Double
        public var warn: Bool
        public var byFamily: [(String, Double)]       // opus, sonnet, haiku, other (account) / per alias (peak)
        public var fraction: Double { budgetUSD > 0 ? totalUSD / budgetUSD : 0 }
        public static func == (a: Line, b: Line) -> Bool {
            a.totalUSD == b.totalUSD && a.budgetUSD == b.budgetUSD && a.warn == b.warn && a.byFamily.map(\.0) == b.byFamily.map(\.0) && a.byFamily.map(\.1) == b.byFamily.map(\.1)
        }
    }
    public var budgetUSD: Double = 0
    public var warnAt: Double = 0.8
    public var showAccountLine = false
    public var account: Line?
    public var peak: Line?
    public var hint: String?
    public init() {}

    /// The account line shows only when the profile flag is on. With the flag on: the account MTD when the engine has it;
    /// the engine's hint only when the admin key is missing or rejected (it sends `hint` then); any other failure hides it.
    public var accountState: AccountState {
        guard showAccountLine else { return .hidden }
        if let a = account { return .shown(a) }
        if let h = hint { return .hint(h) }
        return .hidden
    }
    public enum AccountState: Equatable, Sendable { case hidden, shown(Line), hint(String) }
    public static let defaultHint = "Add an org-scoped Anthropic admin key to see full account spend"
    static let familyOrder = ["opus", "sonnet", "haiku", "other"]

    public static func parse(_ data: Data) -> SpendDoc? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var d = SpendDoc()
        d.budgetUSD = num(o["budget_usd"]) ?? 0
        d.warnAt = num(o["warn_at"]) ?? 0.8
        d.showAccountLine = (o["show_account_line"] as? Bool) ?? false
        d.hint = (o["hint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let a = o["account"] as? [String: Any] { d.account = line(a, budget: d.budgetUSD, warnAt: d.warnAt) }
        if let p = o["peak"] as? [String: Any] { d.peak = line(p, budget: d.budgetUSD, warnAt: d.warnAt) }
        return d
    }

    static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }

    static func line(_ o: [String: Any], budget: Double, warnAt: Double) -> Line {
        let total = num(o["total_usd"]) ?? 0
        let b = num(o["budget_usd"]) ?? budget
        var fam: [String: Double] = [:]
        for (k, v) in (o["by_model"] as? [String: Any]) ?? [:] {
            let usd = num(v) ?? num((v as? [String: Any])?["usd"]) ?? 0
            let key = familyOrder.dropLast().first { k.lowercased().contains($0) } ?? "other"
            fam[key, default: 0] += usd
        }
        let ordered = familyOrder.map { ($0, (fam[$0] ?? 0)) }
        let warn = (o["warn"] as? Bool) ?? (b > 0 && total / b >= warnAt)
        return Line(totalUSD: total, budgetUSD: b, warn: warn, byFamily: ordered)
    }

    /// done.spend {peak_mtd_usd, warn}: the Peek line updates from the turn itself (no extra request).
    public mutating func applyTurn(peakMTD: Double?, warn: Bool?) {
        guard let v = peakMTD else { return }
        var l = peak ?? Line(totalUSD: 0, budgetUSD: budgetUSD, warn: false, byFamily: SpendDoc.familyOrder.map { ($0, 0) })
        l.totalUSD = v
        l.warn = warn ?? (l.budgetUSD > 0 && v / l.budgetUSD >= warnAt)
        peak = l
    }
}

/// The UI never asks the engine for spend more than once a minute (the engine caches the account cost itself).
public struct SpendThrottle: Sendable {
    public let interval: TimeInterval
    public private(set) var last: Date?
    public init(interval: TimeInterval = 60) { self.interval = interval }
    public mutating func shouldFetch(now: Date = Date()) -> Bool {
        if let l = last, now.timeIntervalSince(l) < interval { return false }
        last = now
        return true
    }
}

// ───────────────────────────── events + transcript ─────────────────────────────
public enum ThreePOEvent: Equatable, Sendable {
    case start(route: String, modelAlias: String, mode: String, cached: Bool)
    case delta(String)
    case toolCall(String)
    case toolResult(name: String, ok: Bool)
    case proposal(ProposalCard)
    case advisor(consulting: Bool)
    case escalated(String)
    case attachmentRefused(String)
    case intent(name: String, app: String?)
    case models(ModelsDoc)
    case model(ok: Bool, pick: ModelPick?, message: String?)
    case spend(SpendDoc)
    case done(text: String, costUSD: Double, peakMTD: Double?, warn: Bool?, firstTokenMs: Int?)
    case error(code: String, message: String)
    case skill(SkillCard)                              // a skill's description card (nothing has run)
    case skillRun(slug: String)                        // the card's Run tap is being answered
    case memory(MemoryEvent)                           // remember / forget / list (local, zero tokens)
    case memoryRecall(count: Int, clients: [String])   // this Claude turn carried N remembered facts
    case unknown

    public static func decode(event: String, data: String) -> ThreePOEvent {
        guard let d = data.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return .unknown }
        let t = (o["type"] as? String) ?? event
        func s(_ k: String) -> String { (o[k] as? String) ?? "" }
        switch t {
        case "start":
            let cache = o["cache"] as? [String: Any]
            let cached = ((cache?["breakpoints"] as? [Any])?.count ?? 0) > 0     // the prompt prefix is cache-marked
            return .start(route: s("route"), modelAlias: s("model_alias"), mode: s("mode"), cached: cached)
        case "delta": return .delta(s("text"))
        case "tool_call": return .toolCall(s("name"))
        case "tool_result": return .toolResult(name: s("name"), ok: (o["ok"] as? Bool) ?? false)
        case "proposal":
            guard let c = o["card"] as? [String: Any], let card = ProposalPolicy.card(from: c) else { return .unknown }
            return .proposal(card)
        case "advisor": return .advisor(consulting: s("state") == "consulting")
        case "escalated": return .escalated(s("reason"))
        case "attachment_refused": return .attachmentRefused(s("reason").isEmpty ? s("message") : s("reason"))
        case "intent": return .intent(name: s("intent"), app: o["app"] as? String)
        case "models": return .models(parseModels(o))
        case "model": return .model(ok: (o["ok"] as? Bool) ?? false, pick: ModelPick(rawValue: s("pick")), message: o["message"] as? String)
        case "spend": return SpendDoc.parse(d).map { .spend($0) } ?? .unknown
        case "done":
            let usage = o["usage"] as? [String: Any]
            let sp = o["spend"] as? [String: Any]
            return .done(text: s("text"), costUSD: SpendDoc.num(usage?["cost_usd"]) ?? 0, peakMTD: SpendDoc.num(sp?["peak_mtd_usd"]),
                         warn: sp?["warn"] as? Bool, firstTokenMs: (o["first_token_ms"] as? NSNumber)?.intValue)
        case "error": return .error(code: s("code"), message: s("message"))
        case "skill":
            guard let c = o["card"] as? [String: Any], let card = SkillPolicy.card(from: c) else { return .unknown }
            return .skill(card)
        case "skill_run": return .skillRun(slug: s("slug"))
        case "memory": return .memory(MemoryEvent.parse(o))
        case "memory_recall": return .memoryRecall(count: (o["count"] as? NSNumber)?.intValue ?? 0, clients: jstrs(o["clients"]))
        default: return .unknown
        }
    }

    public static func parseModels(_ o: [String: Any]) -> ModelsDoc {
        var m = ModelsDoc()
        m.pick = ModelPick(rawValue: (o["pick"] as? String) ?? "") ?? .haiku
        var rows: [ModelRow] = [ModelRow(pick: .auto, label: "Auto", available: true)]
        for r in (o["models"] as? [[String: Any]]) ?? [] {
            guard let p = ModelPick(rawValue: (r["alias"] as? String) ?? ""), p != .auto else { continue }
            let label = ((r["label"] as? String) ?? p.defaultLabel).components(separatedBy: " ").first ?? p.defaultLabel
            rows.append(ModelRow(pick: p, label: label, available: (r["available"] as? Bool) ?? false, reason: r["reason"] as? String))
        }
        for p in ModelPick.allCases where !rows.contains(where: { $0.pick == p }) { rows.append(ModelRow(pick: p, label: p.defaultLabel, available: false, reason: "not listed")) }
        m.rows = ModelPick.allCases.compactMap { p in rows.first { $0.pick == p } }
        return m
    }

    public static func parseModels(_ data: Data) -> ModelsDoc? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).map(parseModels)
    }
}

public struct ChatMessage: Equatable, Sendable, Identifiable {
    public enum Role: String, Sendable { case user, threePO, system }
    public var id: Int
    public var role: Role
    public var text: String
    public var proposals: [ProposalCard] = []
    public var skills: [SkillCard] = []
    public var memory: MemoryEvent? = nil         // a remember / forget / list answer (tap-to-pick when the client is unclear)
    public var recalled = 0                       // remembered facts this Claude turn carried
    public var tools: [String] = []
    public var modelAlias: String? = nil
    public var consultedOpus = false
    public var cached = false            // the prompt prefix went out with cache breakpoints
    public var local = false             // a zero-token local reply (slash / intent)
    public var costUSD: Double? = nil
    public var error: String? = nil
    public var done = false
}

/// The 3PO conversation as a pure reducer over engine events (the view model just feeds it).
public struct ThreePOTranscript: Equatable, Sendable {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var streaming = false
    public private(set) var thinking = false          // waiting for the first token / a tool / the advisor
    public private(set) var consultingOpus = false
    public private(set) var opusPulses = 0            // trigger for the gold 'consulted Opus' pulse
    public private(set) var notes: [String] = []      // escalations / refused attachments, shown inline
    public private(set) var intents: [(String, String?)] = []
    public var models = ModelsDoc()
    public var spend = SpendDoc()
    private var nextID = 1
    public init() {}

    public static func == (a: ThreePOTranscript, b: ThreePOTranscript) -> Bool {
        a.messages == b.messages && a.streaming == b.streaming && a.thinking == b.thinking && a.consultingOpus == b.consultingOpus
            && a.opusPulses == b.opusPulses && a.notes == b.notes && a.models == b.models && a.spend == b.spend
    }

    public mutating func begin(_ text: String) {
        messages.append(ChatMessage(id: nextID, role: .user, text: text, done: true)); nextID += 1
        messages.append(ChatMessage(id: nextID, role: .threePO, text: "")); nextID += 1
        streaming = true; thinking = true; notes = []
        // Auto: the gold 'consulting Opus' pulse starts on send, not when the engine's advisor event lands (~15 s later).
        consultingOpus = models.pick == .auto
    }

    /// A zero-token local turn (a client command Peek recognised itself): the user's words, then 3PO's card(s).
    public mutating func local(user text: String?, reply: String, cards: [ProposalCard]) {
        if let text { messages.append(ChatMessage(id: nextID, role: .user, text: text, done: true)); nextID += 1 }
        messages.append(ChatMessage(id: nextID, role: .threePO, text: reply, proposals: cards, modelAlias: "local", local: true, done: true))
        nextID += 1
        notes = []
    }

    private mutating func reply(_ f: (inout ChatMessage) -> Void) {
        guard let i = messages.lastIndex(where: { $0.role == .threePO }) else { return }
        f(&messages[i])
    }

    public mutating func apply(_ e: ThreePOEvent) {
        switch e {
        case .start(let route, let alias, let mode, let cached):
            reply { $0.modelAlias = alias; $0.local = route != "claude"; $0.cached = cached }
            if route != "claude" || mode != "advisor" { consultingOpus = false }   // a local intent or a solo turn: no advisor
        case .delta(let t):
            thinking = false
            reply { $0.text += t }
        case .toolCall(let n):
            thinking = true
            reply { $0.tools.append(n) }
        case .toolResult:
            break
        case .proposal(let c):
            thinking = false
            reply { m in if !m.proposals.contains(where: { $0.id == c.id }) { m.proposals.append(c) } }
        case .advisor(let consulting):
            consultingOpus = consulting
            if consulting { thinking = true } else { opusPulses += 1; reply { $0.consultedOpus = true } }
        case .escalated(let r): notes.append("Escalated: \(r)")
        case .attachmentRefused(let r): notes.append("Attachment refused: \(r)")
        case .intent(let n, let app): intents.append((n, app))
        case .models(let m): models = m
        case .model(let ok, let p, _): if ok, let p { models.pick = p }
        case .spend(let s): spend = s
        case .done(let text, let cost, let mtd, let warn, _):
            reply { m in if m.text.isEmpty { m.text = text }; m.costUSD = cost; m.done = true }
            spend.applyTurn(peakMTD: mtd, warn: warn)
            streaming = false; thinking = false; consultingOpus = false
        case .error(let code, let msg):
            reply { $0.error = ThreePOTranscript.friendly(code, msg); $0.done = true }
            streaming = false; thinking = false; consultingOpus = false
        case .skill(let c):
            thinking = false
            reply { m in if !m.skills.contains(where: { $0.id == c.id }) { m.skills.append(c) } }
        case .skillRun: break
        case .memory(let e):
            thinking = false
            reply { $0.memory = e }
        case .memoryRecall(let n, _):
            reply { $0.recalled = n }
        case .unknown: break
        }
    }

    /// The stream ended without a done/error frame (engine stopped, network dropped).
    public mutating func endOfStream() {
        guard streaming else { return }
        reply { if !$0.done { $0.done = true; if $0.text.isEmpty { $0.error = "3PO stopped before answering. Nothing ran." } } }
        streaming = false; thinking = false; consultingOpus = false
    }

    public static func friendly(_ code: String, _ msg: String) -> String {
        switch code {
        case "auth_error": return "Claude rejected this Mac's key. Nothing ran."
        case "rate_limited": return "Claude is rate-limiting right now. Try again in a minute."
        case "overloaded": return "Claude is overloaded right now. Try again shortly."
        case "network_error": return "Couldn't reach Claude from this Mac. Nothing ran."
        default: return msg.isEmpty ? "3PO hit an error. Nothing ran." : String(msg.prefix(200))
        }
    }
}

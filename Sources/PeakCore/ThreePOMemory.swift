import Foundation

// ForceIQ Peak 3PO memory + skill cards: the client side of engine/threepo_memory.py and engine/threepo_skills.py.
// Pure logic, unit-tested: memory doc parsing and grouping, the memory view's look (bright on black, never dim), skill
// card decoding, and the rule that a skill only runs from its card's own Run tap. Nothing here touches the network.

func jstr(_ v: Any?) -> String {
    switch v { case let s as String: return s; case let n as NSNumber: return n.stringValue; default: return "" }
}

func jstrs(_ v: Any?) -> [String] {
    if let a = v as? [Any] { return a.map(jstr).filter { !$0.isEmpty } }
    if let s = v as? String, !s.isEmpty { return [s] }
    return []
}

// ───────────────────────────── memory ─────────────────────────────
public struct MemoryFact: Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var client: String?
    public var clients: [String]
    public var savedAt: String
    public var forgotten: Bool
    public var forgottenAt: String?
    public init(id: String, text: String, client: String? = nil, clients: [String] = [], savedAt: String = "", forgotten: Bool = false, forgottenAt: String? = nil) {
        self.id = id; self.text = text; self.client = client; self.clients = clients; self.savedAt = savedAt; self.forgotten = forgotten; self.forgottenAt = forgottenAt
    }
    /// "Oct 19" from the engine's ISO timestamp (local, never a raw ISO string in the view).
    public var savedLabel: String { MemoryFact.dayLabel(savedAt) }

    public static func dayLabel(_ iso: String) -> String {
        let parts = iso.prefix(10).split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]), (1...12).contains(m) else { return "" }
        return "\(["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][m - 1]) \(d)"
    }

    public static func parse(_ o: [String: Any]) -> MemoryFact? {
        let id = jstr(o["id"]), text = jstr(o["text"])
        guard !id.isEmpty, !text.isEmpty else { return nil }
        let c = jstr(o["client"])
        return MemoryFact(id: id, text: text, client: c.isEmpty ? nil : c, clients: jstrs(o["clients"]), savedAt: jstr(o["ts"]),
                          forgotten: (o["forgotten"] as? Bool) ?? false, forgottenAt: (o["forgotten_at"] as? String))
    }
}

public struct MemoryDoc: Equatable, Sendable {
    public var owner = ""
    public var facts: [MemoryFact] = []
    public init(owner: String = "", facts: [MemoryFact] = []) { self.owner = owner; self.facts = facts }

    public var active: [MemoryFact] { facts.filter { !$0.forgotten } }
    public var forgotten: [MemoryFact] { facts.filter(\.forgotten) }

    public static func parse(_ data: Data) -> MemoryDoc? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], (o["ok"] as? Bool) != false else { return nil }
        return MemoryDoc(owner: jstr(o["owner"]), facts: ((o["facts"] as? [[String: Any]]) ?? []).compactMap(MemoryFact.parse))
    }

    /// The memory view: one section per client (A→Z), then "General" (facts about no client). Forgotten facts appear
    /// only when asked for, in their own section, still at full brightness with a gold "Forgotten" tag.
    public func sections(showForgotten: Bool) -> [MemorySection] {
        var by: [String: [MemoryFact]] = [:]
        var general: [MemoryFact] = []
        for f in active { if let c = f.client { by[c, default: []].append(f) } else { general.append(f) } }
        var out = by.keys.sorted { $0.lowercased() < $1.lowercased() }.map { MemorySection(title: $0, kind: .client, facts: by[$0]!) }
        if !general.isEmpty { out.append(MemorySection(title: "General", kind: .general, facts: general)) }
        if showForgotten && !forgotten.isEmpty { out.append(MemorySection(title: "Forgotten", kind: .forgotten, facts: forgotten)) }
        return out
    }
}

public struct MemorySection: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case client, general, forgotten }
    public var title: String
    public var kind: Kind
    public var facts: [MemoryFact]
    public var id: String { kind.rawValue + ":" + title }
}

public enum MemoryLoad: Equatable, Sendable { case idle, loading, loaded, failed(String) }

/// The memory view's colors: white text on black, gold and green accents, every element at full opacity.
public enum MemoryStyle {
    public static let backgroundHex = Brand.blackHex
    public static let textHex = Brand.whiteHex                 // fact text, dates, empty state: pure white
    public static let clientHex = Brand.goldHex                // client section titles
    public static let generalHex = Brand.greenHex              // "General" and section rules
    public static let forgottenTagHex = Brand.goldHex          // the "Forgotten" tag (never gray, never struck through)
    public static let forgetButtonHex = Brand.goldHex          // outline button, white label
    public static let activePillHex = Brand.goldHex            // the Chat / Memory pill that is showing
    public static let opacity: Double = 1.0
    public static var all: [UInt32] { [backgroundHex, textHex, clientHex, generalHex, forgottenTagHex, forgetButtonHex, activePillHex] }
    public static func titleHex(_ k: MemorySection.Kind) -> UInt32 {
        switch k { case .client: return clientHex; case .general: return generalHex; case .forgotten: return forgottenTagHex }
    }
}

/// A memory event in a turn (remember / forget / list), from engine/threepo.py memory_turn.
public struct MemoryEvent: Equatable, Sendable {
    public var op: String
    public var status: String
    public var fact: MemoryFact?
    public var facts: [MemoryFact]
    public var candidates: [String]
    public var text: String?                   // the fact text to re-send once a client is picked
    public var needsPick: Bool { status == "pick" && !candidates.isEmpty && op == "remember" }

    public static func parse(_ o: [String: Any]) -> MemoryEvent {
        let cands: [String] = ((o["candidates"] as? [Any]) ?? []).compactMap { ($0 as? String) ?? (($0 as? [String: Any]).map { jstr($0["text"]) }) }
        return MemoryEvent(op: jstr(o["op"]), status: jstr(o["status"]), fact: (o["fact"] as? [String: Any]).flatMap(MemoryFact.parse),
                           facts: ((o["facts"] as? [[String: Any]]) ?? []).compactMap(MemoryFact.parse),
                           candidates: cands.filter { !$0.isEmpty }, text: o["text"] as? String)
    }
}

// ───────────────────────────── skill cards ─────────────────────────────
public struct SkillInput: Equatable, Sendable {
    public var key: String
    public var help: String
    public var value: String?
    public var required: Bool
}

public struct SkillCard: Equatable, Sendable, Identifiable {
    public var id: String
    public var slug: String
    public var name: String
    public var description: String
    public var kind: String                  // read | prompt | action
    public var inputs: [SkillInput]
    public var touches: [String]
    public var outputs: [String]
    public var client: String?
    public var clientRule: String
    public var candidates: [String]
    public var needs: [String]
    public var prompt: String
    public var status: String               // described | needs-input | refused
    public var message: String
    public var viewOnly: Bool
    public var runInputs: [String: String]? // the engine's own run body (only for a runnable card)

    public var kindLabel: String { ["read": "Read-only", "prompt": "Asks Claude", "action": "Fix card"][kind] ?? kind }
    public var canRun: Bool { !viewOnly && runInputs != nil && status == "described" }
    public var needsClientPick: Bool { needs.first == "client" && !candidates.isEmpty }
}

public enum SkillPolicy {
    /// Only read, prompt or action skills; an action skill is runnable only for an action Peak itself would allow.
    public static func card(from o: [String: Any]) -> SkillCard? {
        let id = jstr(o["id"]), slug = jstr(o["slug"]), name = jstr(o["name"])
        guard !id.isEmpty, !slug.isEmpty, !name.isEmpty else { return nil }
        let kind = jstr(o["kind"])
        let inputs = ((o["inputs"] as? [[String: Any]]) ?? []).map {
            SkillInput(key: jstr($0["key"]), help: jstr($0["help"]), value: ($0["value"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                       required: ($0["required"] as? Bool) ?? false)
        }
        var runInputs: [String: String]?
        if let r = o["run"] as? [String: Any], jstr(r["skill"]) == slug, (r["run"] as? Bool) == true {
            runInputs = ((r["inputs"] as? [String: Any]) ?? [:]).reduce(into: [:]) { $0[$1.key] = jstr($1.value) }
        }
        let action = jstr(o["action"])
        let status = jstr(o["status"])
        let viewOnly = ((o["view_only"] as? Bool) ?? true) || !["read", "prompt", "action"].contains(kind)
            || (kind == "action" && (action.isEmpty || ProposalPolicy.isDangerous(action))) || status != "described" || runInputs == nil
        let client = jstr(o["client"])
        return SkillCard(id: id, slug: slug, name: name, description: jstr(o["description"]), kind: kind, inputs: inputs,
                         touches: jstrs(o["touches"]), outputs: jstrs(o["outputs"]), client: client.isEmpty ? nil : client,
                         clientRule: jstr(o["client_rule"]), candidates: jstrs(o["candidates"]), needs: jstrs(o["needs"]),
                         prompt: jstr(o["prompt"]), status: status, message: jstr(o["message"]), viewOnly: viewOnly,
                         runInputs: viewOnly ? nil : runInputs)
    }

    /// The body the Run tap sends (and nothing else ever sets "run": true).
    public static func runBody(_ c: SkillCard, session: String, pick: ModelPick) -> Data? {
        guard c.canRun, let inputs = c.runInputs else { return nil }
        let o: [String: Any] = ["text": "Run: \(c.name)", "session": session, "model": pick.rawValue, "skill": c.slug, "run": true, "inputs": inputs]
        return try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }

    /// Picking the client re-asks for the DESCRIPTION card with that client (still no run).
    public static func pickBody(_ c: SkillCard, client: String, session: String, pick: ModelPick) -> Data? {
        guard c.candidates.contains(client) else { return nil }
        var inputs: [String: String] = [:]
        for i in c.inputs { if let v = i.value { inputs[i.key] = v } }
        inputs["client"] = client
        let o: [String: Any] = ["text": "\(c.name) for \(client)", "session": session, "model": pick.rawValue, "skill": c.slug, "inputs": inputs]
        return try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }

    public static func askText(_ c: SkillCard) -> String {
        "Before I run anything: explain the '\(c.name)' skill\(c.client.map { " for \($0)" } ?? ""), what it reads or touches, and what could go wrong. Don't run it."
    }
}

/// A skill card's lifecycle: described → (Run tap) running → done | failed. Nothing runs from described without the tap.
public enum SkillPhase: Equatable, Sendable { case described, running, done, failed(String) }

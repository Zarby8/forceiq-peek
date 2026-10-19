import Foundation

/// ForceIQ Peak drop zones (engine/peakdrop.py via /api/peak/title-drop|shift-drop/preview|apply|undo).
/// Drop a file → pick a zone → Preview (read-only: resolves the client, renders a scratch title) → the description →
/// Run (apply; the engine first answers needs_confirm) → Confirm. Undo the same way. Nothing runs without the taps.
public enum DropZone: String, CaseIterable, Sendable {
    case title = "title-drop", shift = "shift-drop"
    public var title: String { self == .title ? "Title slide fix" : "Dagu Shifts" }
    public var blurb: String {
        self == .title ? "Re-render the title slide + folder image, see before and after, then replace (backed up first)."
                       : "Check the film's name, then clone it into ForceIQ Shifts so the shifts pipeline picks it up."
    }
    /// A hint only (both zones are always offered): a film named like a shift goes to Shifts.
    public static func suggested(for url: URL) -> DropZone {
        let n = url.lastPathComponent
        let film = ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
        return film && n.range(of: #"^[A-Za-z0-9]+_[A-Za-z0-9]+(\([1-9]\))?_\d{1,2}\.\d{1,2}\.\d{4}\.[A-Za-z0-9]+$"#, options: .regularExpression) != nil ? .shift : .title
    }
}

public struct DropPreview: Equatable, Sendable {
    public var zone: DropZone
    public var token: String
    public var client: String?
    public var description: String
    public var canApply: Bool
    public var fixName: String?                 // shift: the suggested corrected name (applied only on Confirm)
    public var problem: String?
    public var before: [String] = []            // local image paths (title)
    public var after: [String] = []
    public var details: [String] = []           // shift: game / date / problems / target
    public var targetExists = false             // shift: a file with that name is already in Shifts → apply blocked

    public static func parse(_ zone: DropZone, _ d: Data) -> (DropPreview?, String?) {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return (nil, "GOAT gave a bad answer.") }
        guard (o["ok"] as? Bool) == true, let tok = o["token"] as? String, tok.range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil else {
            return (nil, (o["message"] as? String) ?? "GOAT couldn't preview that drop.")
        }
        let client: String? = (o["client"] as? String) ?? ((o["client"] as? [String: Any])?["name"] as? String)
        func imgs(_ k: String) -> [String] {
            ((o[k] as? [[String: Any]]) ?? []).compactMap { ($0["image"] as? String) ?? ($0["path"] as? String) }.filter { $0.hasPrefix("/") && $0.lowercased().hasSuffix(".png") }
        }
        let fix = (o["fix_name"] as? [String: Any])?["to"] as? String
        let can: Bool
        switch zone {
        case .title: can = (o["ready"] as? Bool) ?? false
        case .shift: can = ((o["valid"] as? Bool) ?? false || fix != nil) && !((o["target_exists"] as? Bool) ?? false)
        }
        var details: [String] = []
        if let opp = o["opponent"] as? String, !opp.isEmpty { details.append("Opponent: \(opp)") }
        if let g = o["game"], !(g is NSNull), "\(g)" != "" { details.append("Game: \(g)") }
        if let d = o["date"] as? String, !d.isEmpty { details.append("Date: \(d)") }
        for pr in (o["problems"] as? [String]) ?? [] { details.append("Problem: \(pr)") }
        let exists = (o["target_exists"] as? Bool) ?? false
        if exists { details.append("Already in ForceIQ Shifts: \((o["name"] as? String) ?? "that name"). Apply is blocked.") }
        return (DropPreview(zone: zone, token: tok, client: client, description: (o["description"] as? String) ?? "", canApply: can,
                            fixName: (o["valid"] as? Bool) == true ? nil : fix, problem: o["problem"] as? String,
                            before: imgs("before"), after: imgs("after"), details: details, targetExists: exists), nil)
    }

    /// title-drop preview may ask which game: {needs_choice, client, choices, message}.
    public static func choice(_ d: Data) -> (client: String, choices: [String], message: String)? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], (o["needs_choice"] as? Bool) == true,
              let ch = o["choices"] as? [String], !ch.isEmpty else { return nil }
        return ((o["client"] as? String) ?? "", Array(ch.prefix(12)), (o["message"] as? String) ?? "Which game?")
    }

    public var prompt: String {
        "ForceIQ Peak drop (\(zone.title)) for \(client ?? "no client resolved"): \(description)\nRule: nothing is replaced or placed without my explicit confirm."
    }
}

public enum DropPhase: Equatable, Sendable {
    case idle
    case pending(URL, suggested: DropZone)      // a file is here; pick a zone (nothing has been read yet)
    case choosing(URL, client: String, choices: [String], message: String)   // title: which game? (a picker card)
    case previewing(DropZone)
    case described(DropPreview)                 // description first: Run / Ask Claude / Copy prompt
    case confirming(DropPreview, String)        // the engine's confirm text; Confirm = a second tap
    case applying(DropPreview)
    case applied(DropPreview, String)           // Undo is offered (same two-step)
    case undoConfirm(DropPreview, String)
    case failed(String)
    case note(String)                           // a neutral end state (e.g. undone)
}

@MainActor public final class DropStore: ObservableObject {
    @Published public private(set) var phase: DropPhase = .idle
    @Published public private(set) var pops = 0
    @Published public private(set) var shiftState: ShiftProgress? = nil      // shift-download progress (allowed: it's a fix item)
    private var lastURL: URL?
    private var polls = 0
    public var onAsk: ((String) -> Void)?
    public var onCopy: ((String) -> Void)?
    /// The 5090 light's gate (GPULightModel.hold): nil = allowed, else the refusal. The shifts zone starts a Dagu upscale
    /// on the 5090, so its preview, Run and Confirm each ask at the moment of the tap; a held tap changes nothing.
    public var gpuHold: (() -> String?)?
    let transport: ThreePOTransport
    weak var logger: PeakLogging?
    public init(transport: ThreePOTransport, logger: PeakLogging? = nil) { self.transport = transport; self.logger = logger }

    public var active: Bool { phase != .idle }

    public func received(_ url: URL) {
        guard url.isFileURL, url.path.hasPrefix("/") else { phase = .failed("Peak only takes files on this Mac."); return }
        lastURL = url; shiftState = nil; polls = 0
        phase = .pending(url, suggested: DropZone.suggested(for: url))
    }

    public func dismiss() { phase = .idle; shiftState = nil }

    func body(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data() }

    /// true (and the phase shows the plain refusal) when this zone is 5090 GPU work and the light holds it.
    func heldForGPU(_ zone: DropZone) -> Bool {
        guard GPUGate.isGPUAction(zone), let why = gpuHold?() else { return false }
        phase = .failed(why)
        logger?.log("drop refused=gpu-hold zone=\(zone.rawValue)")
        return true
    }

    /// Preview only reads (title: a scratch re-render). An explicit tap on a zone.
    public func preview(_ zone: DropZone, game: String? = nil) async {
        let url: URL
        switch phase {
        case .pending(let u, _): url = u
        case .choosing(let u, _, let choices, _): guard let g = game, choices.contains(g) else { return }; url = u
        default: return
        }
        if heldForGPU(zone) { return }
        phase = .previewing(zone)
        logger?.log("drop preview zone=\(zone.rawValue)")
        var b: [String: Any] = ["path": url.path]
        if zone == .title, let g = game { b["game"] = g }
        let (c, d) = await transport.post("/api/peak/\(zone.rawValue)/preview", body(b))
        guard c == 200 || c == 500 else { phase = .failed("This Mac's GOAT doesn't have Peak drops yet."); return }
        if zone == .title, let ch = DropPreview.choice(d) { phase = .choosing(url, client: ch.client, choices: ch.choices, message: ch.message); return }
        let (p, err) = DropPreview.parse(zone, d)
        phase = p.map { .described($0) } ?? .failed(err ?? "GOAT couldn't preview that drop.")
    }

    /// Run: asks the engine to apply WITHOUT confirm (it only answers with what it would do).
    public func run() async {
        guard case .described(let p) = phase, p.canApply, !p.targetExists else { return }
        if heldForGPU(p.zone) { return }
        let (c, d) = await transport.post("/api/peak/\(p.zone.rawValue)/apply", body(["token": p.token]))
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if c == 200, (o?["needs_confirm"] as? Bool) == true {
            phase = .confirming(p, (o?["confirm_text"] as? String) ?? "Confirm to apply this drop.")
        } else { phase = .failed((o?["message"] as? String) ?? "GOAT didn't answer. Nothing changed.") }
    }

    public func confirm() async {
        guard case .confirming(let p, _) = phase else { return }
        if heldForGPU(p.zone) { return }
        phase = .applying(p)
        logger?.log("drop apply zone=\(p.zone.rawValue)")
        var b: [String: Any] = ["token": p.token, "confirm": true]
        if let n = p.fixName { b["name"] = n }
        let (c, d) = await transport.post("/api/peak/\(p.zone.rawValue)/apply", body(b))
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if c == 200, (o?["ok"] as? Bool) == true {
            pops += 1
            phase = .applied(p, p.zone == .shift ? "Placed in ForceIQ Shifts. Your original stays put." : "Title files replaced (backed up first).")
            if p.zone == .shift { shiftState = ShiftProgress(state: "waiting", message: "Waiting for the shifts watcher.") }
        } else { phase = .failed((o?["message"] as? String) ?? "Nothing changed.") }
    }

    public func undo() async {
        guard case .applied(let p, _) = phase else { return }
        let (c, d) = await transport.post("/api/peak/\(p.zone.rawValue)/undo", body(["token": p.token]))
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if c == 200, (o?["needs_confirm"] as? Bool) == true { phase = .undoConfirm(p, (o?["confirm_text"] as? String) ?? "Confirm to undo.") }
        else { phase = .failed((o?["message"] as? String) ?? "Couldn't undo.") }
    }

    public func confirmUndo() async {
        guard case .undoConfirm(let p, _) = phase else { return }
        logger?.log("drop undo zone=\(p.zone.rawValue)")
        let (c, d) = await transport.post("/api/peak/\(p.zone.rawValue)/undo", body(["token": p.token, "confirm": true]))
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        phase = c == 200 && (o?["ok"] as? Bool) == true ? .note("Undone. Peak put things back the way they were.") : .failed((o?["message"] as? String) ?? "Couldn't undo.")
    }

    /// GET /api/peak/shift-drop/status/<token>: one read. The view calls it every ~10 s while the sheet is open and the
    /// state isn't final (at most 60 reads per drop), so nothing polls in the background.
    public func pollShift() async {
        guard case .applied(let p, _) = phase, p.zone == .shift, !(shiftState?.isFinal ?? false), polls < 60 else { return }
        polls += 1
        let (c, d) = await transport.get("/api/peak/shift-drop/status/\(p.token)")
        guard c == 200, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        shiftState = ShiftProgress(state: (o["state"] as? String) ?? "waiting", message: (o["message"] as? String) ?? "")
    }

    public func cancel() { if case .confirming(let p, _) = phase { phase = .described(p) }; if case .undoConfirm(let p, _) = phase { phase = .applied(p, "Applied.") } }
    public func ask() { if case .described(let p) = phase { onAsk?("Before I apply this drop, explain what it will change and what could go wrong: " + p.description) } }
    public func copy() { if case .described(let p) = phase { onCopy?(p.prompt) } }
}

/// Shift-download progress from shift-drop status (previewed → waiting → identified → staged → queued → running →
/// succeeded | failed; plus the watcher's needs_info / needs_attention / already_delivered / undone).
public struct ShiftProgress: Equatable, Sendable {
    public var state: String
    public var message: String
    public static let steps = ["waiting", "identified", "staged", "queued", "running", "succeeded"]
    public var step: Int { Self.steps.firstIndex(of: state) ?? (state == "previewed" ? -1 : 0) }
    public var isFinal: Bool { ["succeeded", "failed", "undone", "needs_info", "needs_attention", "already_delivered"].contains(state) }
    public var isProblem: Bool { ["failed", "needs_info", "needs_attention"].contains(state) }
    public var label: String { state.replacingOccurrences(of: "_", with: " ").capitalized }
}

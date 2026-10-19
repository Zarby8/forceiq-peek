import AppKit
import KeyboardShortcuts
import PeakCore

// ───────────────────────────── log (action / state names only) ─────────────────────────────
/// This coach's profile for the running app (loaded once at launch; see AppDelegate).
@MainActor enum Session {
    static var profile = CoachProfile.none
    /// Before a profile loads: the default state root (same default engine/peakprofile.py uses).
    /// GOAT_PEAK_ROOT (a scratch root) wins, as in CoachProfile.stateRootURL().
    static var defaultStateRoot: URL { PeakRoot.override() ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ForceIQ/peak") }
}

@MainActor final class FileLog: PeakLogging {
    var url: URL
    init(stateRoot: URL) {
        if let p = ProcessInfo.processInfo.environment["FORCEIQ_PEAK_LOG"], !p.isEmpty {
            url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        } else {
            url = stateRoot.appendingPathComponent("logs/peak.log")
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    func move(to stateRoot: URL) {
        guard ProcessInfo.processInfo.environment["FORCEIQ_PEAK_LOG"]?.isEmpty ?? true else { return }
        url = stateRoot.appendingPathComponent("logs/peak.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    func log(_ event: String) {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        let line = "\(f.string(from: Date())) \(event)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

// ───────────────────────────── hotkey: KeyboardShortcuts 3.1.0 (MIT); default from the profile (ctrl+opt+G) ─────────────────────────────
@MainActor enum PeakHotkeyName {
    static var current = KeyboardShortcuts.Name("togglePeak")
    static func make(_ p: CoachProfile) -> KeyboardShortcuts.Name {
        let keys: [String: KeyboardShortcuts.Key] = ["a": .a, "b": .b, "c": .c, "d": .d, "e": .e, "f": .f, "g": .g, "h": .h, "i": .i, "j": .j,
            "k": .k, "l": .l, "m": .m, "n": .n, "o": .o, "p": .p, "q": .q, "r": .r, "s": .s, "t": .t, "u": .u, "v": .v, "w": .w, "x": .x,
            "y": .y, "z": .z, "0": .zero, "1": .one, "2": .two, "3": .three, "4": .four, "5": .five, "6": .six, "7": .seven, "8": .eight, "9": .nine]
        var mods: NSEvent.ModifierFlags = []
        for m in p.hotkey.modifiers {
            switch m { case "control": mods.insert(.control); case "option": mods.insert(.option)
            case "command": mods.insert(.command); case "shift": mods.insert(.shift); default: break }
        }
        let n = KeyboardShortcuts.Name("togglePeak.\(p.coachID)", initial: .init(keys[p.hotkey.key] ?? .g, modifiers: mods))
        current = n
        return n
    }
}

@MainActor final class KeyboardShortcutsHotkey: HotkeyRegistering {
    let name: KeyboardShortcuts.Name
    init(name: KeyboardShortcuts.Name) { self.name = name }
    func register(_ onPress: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.removeHandler(for: name)
        KeyboardShortcuts.onKeyUp(for: name) { MainActor.assumeIsolated { onPress() } }
    }
    func unregister() { KeyboardShortcuts.removeHandler(for: name) }
}

// ───────────────────────────── installed apps ─────────────────────────────
struct WorkspaceLocator: AppLocating {
    func isInstalled(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

@MainActor enum AppLauncher {
    /// GOAT (the coach profile's goat_bundle_id).
    static func activateGOAT() -> Bool {
        let id = Session.profile.goatBundleID
        return !id.isEmpty && launch(id)
    }
    static func openCommand() -> Bool {
        guard let u = URL(string: Session.profile.commandOpenURL), u.scheme == "forceiq-command" else { return false }
        return NSWorkspace.shared.open(u)
    }
    /// Activates a running app or launches it, by bundle ID: the coach profile's allow-list, installed only.
    static func activate(_ bundleID: String) -> Bool {
        guard AppSwitcher.canActivate(bundleID, Session.profile, WorkspaceLocator()) else { return false }
        return launch(bundleID)
    }
    private static func launch(_ bundleID: String) -> Bool {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return running.activate()
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        return true
    }
}

// ───────────────────────────── the local GOAT engine (phone.py on 127.0.0.1 only) ─────────────────────────────
/// Same trust as GOAT's own Mac app: a loopback request without Tailscale headers is "this Mac (local process)" to
/// phone.py (H.peer), so there is no token to carry and no secret in this code. Never any other host.
final class EngineClient: ThreePOTransport, Sendable {
    let base: URL
    let session: URLSession
    init() {
        let port = Int(ProcessInfo.processInfo.environment["COMMANDBOX_PHONE_PORT"] ?? "") ?? 8765
        base = URL(string: "http://127.0.0.1:\(port)")!
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 70
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.connectionProxyDictionary = [:]
        session = URLSession(configuration: cfg)
    }
    func get(_ path: String) async -> (Int, Data) { await call("GET", path, nil) }
    func profile() async -> Data? {
        let (c, d) = await get("/api/peak/profile")
        return c == 200 ? d : nil
    }
    func post(_ path: String, _ body: [String: String] = [:]) async -> (Int, Data) {
        await call("POST", path, try? JSONSerialization.data(withJSONObject: body))
    }
    func post(_ path: String, _ body: Data) async -> (Int, Data) { await call("POST", path, body) }

    /// POST /api/3po/stream: text/event-stream from this Mac's engine, decoded event by event.
    func stream(_ body: Data) -> AsyncStream<ThreePOEvent> {
        let session = session, base = base
        return AsyncStream { cont in
            let task = Task {
                guard let url = URL(string: "/api/3po/stream", relativeTo: base), url.host == "127.0.0.1" else { cont.finish(); return }
                var r = URLRequest(url: url)
                r.httpMethod = "POST"; r.httpBody = body; r.timeoutInterval = 180
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                do {
                    let (bytes, resp) = try await session.bytes(for: r)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                        cont.yield(.error(code: "engine", message: "This Mac's GOAT didn't open 3PO (is GOAT up to date?)."))
                        cont.finish(); return
                    }
                    var parser = SSEParser()
                    var line = Data()
                    for try await b in bytes {
                        line.append(b)
                        if b == 0x0A {
                            for f in parser.feed(line) { cont.yield(ThreePOEvent.decode(event: f.event, data: f.data)) }
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    for f in parser.feed(line + Data([0x0A, 0x0A])) { cont.yield(ThreePOEvent.decode(event: f.event, data: f.data)) }
                } catch {
                    if !Task.isCancelled { cont.yield(.error(code: "engine", message: "Lost the connection to this Mac's GOAT. Nothing ran.")) }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
    private func call(_ method: String, _ path: String, _ body: Data?) async -> (Int, Data) {
        guard path.hasPrefix("/api/"), let url = URL(string: path, relativeTo: base), url.host == "127.0.0.1" else { return (0, Data()) }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = body
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (d, resp) = try await session.data(for: r)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, d)
        } catch {
            return (0, Data())
        }
    }

    func snapshot() async -> EngineSnapshot {
        async let m = get("/api/peak/next-meeting")
        async let l = get("/api/live")
        async let a = get("/api/approvals")
        async let f = get("/api/family-delivery-alerts")
        var s = EngineSnapshot()
        let (mc, md) = await m
        if mc == 200 { (s.meeting, s.meetingError) = EngineParse.meeting(md) } else {
            s.meetingError = mc == 404 ? "This Mac's GOAT doesn't have the Peak meeting feed yet." : "GOAT didn't answer for the next meeting."
        }
        let (lc, ld) = await l
        if lc == 200 { let x = EngineParse.live(ld); s.fixes = x.fixes; s.fixesRunning = x.fixing; s.downloadsRunning = x.downloading }
        else { s.errors.append("live") }
        let (ac, ad) = await a
        if ac == 200 { s.approvals = EngineParse.approvals(ad) } else { s.errors.append("approvals") }
        let (fc, fd) = await f
        if fc == 200 { let x = EngineParse.family(fd); s.familyEnabled = x.enabled; s.family = x.rows }
        return s
    }
}

// ───────────────────────────── performing an allowed card action ─────────────────────────────
@MainActor final class Performer: CardActionPerforming {
    let engine: EngineClient
    let demo: Bool
    var lastOK = true
    init(engine: EngineClient, demo: Bool) { self.engine = engine; self.demo = demo }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func localPrompt(_ c: PeakCard) -> String {
        """
        ForceIQ GOAT card (\(c.kind.rawValue)) for \(c.client): \(c.title).
        Inputs: \(c.description.inputs.joined(separator: "; "))
        Touches: \(c.description.touches.joined(separator: "; "))
        Outputs: \(c.description.outputs.joined(separator: "; "))
        Rule: nothing that sends, deletes, invoices, books or edits a database runs without my explicit OK.
        """
    }

    func open(_ s: String) -> Bool {
        guard let u = URL(string: s), let sc = u.scheme?.lowercased(), sc == "https" || sc == "forceiq-command" else { return false }
        return NSWorkspace.shared.open(u)
    }

    static func message(_ d: Data) -> String {
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        let m = (o?["message"] as? String) ?? (o?["answer"] as? String) ?? (o?["text"] as? String) ?? ""
        return String(m.prefix(400))
    }

    func perform(_ action: CardAction, on c: PeakCard) async -> String {
        lastOK = false
        if demo, action == .run || action == .askClaude { lastOK = action == .run; return "Demo mode: nothing ran." }
        switch action {
        case .run:
            if c.kind == .meeting {
                // The room page only (CommandLink-validated): never a join URL, never workflow=.
                let link = CommandLink.safe(c.joinURL ?? "")
                lastOK = open(link)
                return lastOK ? "Opened the room in Command. Tap Join and Record there." : "Couldn't open Command."
            }
            guard c.kind == .approval, !c.viewOnly, let id = c.engineID else { return "Nothing to run here." }
            let (code, d) = await engine.post("/api/approvals/\(id)/approve")
            let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            if (o?["needs_confirm"] as? Bool) == true {
                _ = AppLauncher.activateGOAT()
                return "GOAT needs a confirm for this one. Nothing ran; GOAT is open."
            }
            lastOK = code == 200 && (o?["ok"] as? Bool) != false
            return code == 200 ? (Self.message(d).isEmpty ? "GOAT took it." : Self.message(d)) : "GOAT didn't answer. Nothing ran."
        case .askClaude:
            if c.kind == .approval, let id = c.engineID {
                let (code, d) = await engine.post("/api/approvals/\(id)/ask")
                return code == 200 ? (Self.message(d).isEmpty ? "Asked. The answer is in GOAT." : Self.message(d)) : "GOAT didn't answer."
            }
            copy(localPrompt(c)); _ = AppLauncher.activateGOAT()
            return "Prompt copied. Paste it into GOAT's Ask."
        case .copyPrompt:
            if c.kind == .approval, let id = c.engineID {
                let (code, d) = await engine.post("/api/approvals/\(id)/prompt")
                let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
                if code == 200, let p = (o?["prompt"] as? String) ?? (o?["text"] as? String), !p.isEmpty { copy(p); return "Prompt copied." }
            }
            copy(localPrompt(c)); return "Prompt copied."
        case .openInGOAT:
            return AppLauncher.activateGOAT() ? "Opened GOAT." : "GOAT isn't installed on this Mac."
        case .openInCommand:
            return AppLauncher.openCommand() ? "Opened Command." : "Couldn't open Command."
        case .openURL(let u):
            return open(u) ? "Opened." : "Only https or Command links open from Peak."
        case .copyLink(let l):
            guard l.lowercased().hasPrefix("https://") else { return "No valid link to copy." }
            copy(l); return "Family link copied. Nothing was sent."
        }
    }
}

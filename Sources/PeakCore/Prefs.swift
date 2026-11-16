import Foundation

/// Persisted Peek settings, one JSON file under this coach's state root (<state_root>/settings.json).
/// (KeyboardShortcuts keeps the recorded shortcut itself in the app's UserDefaults; that's the library's storage.)
///
/// Every key is optional and decoded leniently: a missing key (or a JSON null) gets its documented default and the keys
/// that are present are kept, so a partial file like {"commandMeetingLink": true} works. Defaults:
///   hiddenDisplays [] (shown on every display) · globallyHidden false · hotkeyEnabled unset (the profile's hotkey.enabled)
///   ghostFormat unset (h264-black) · voiceEnabled unset (the profile's modules.voice) · desktopActions false
///   commandMeetingLink false · nextSessionPill false · cuaActions false · readyAlerts true (peek when a pack or FLOW package is ready)
///   agentsWatcher false (the Claude watcher: Peek installs its hook relay and shows Claude session states; the profile's modules.agents also turns it on)
///   presenting false (hide every client detail on a shared screen) · menuBarItem false (the wing's right-click is the menu) · autoPresenting true (present while Command is live)
///   quietHoursStart / quietHoursEnd unset ("HH:mm" local; both set = no peeks in that window, wraps midnight) · dndUntil unset
/// No file is normal (a fresh Mac): silent defaults. A file that exists but can't be used (unreadable, empty, not valid
/// JSON, not an object, or any key of the wrong type) fails loudly and fails closed: ALL settings fall back to defaults,
/// desktopActions / commandMeetingLink / voice are off, `loadIssue` names the path and the bad key or parse error
/// (never a value), the app logs it and shows `unreadableNotice` on the home list. Before the first save over such a
/// file, Peek keeps a copy next to it (settings.unreadable.json) so the coach's edits aren't lost. Never crashes.
public final class PeakPrefs: @unchecked Sendable {
    struct Doc: Codable {
        var hiddenDisplays: [String] = []; var hotkeyEnabled: Bool? = nil; var globallyHidden = false; var ghostFormat: String? = nil
        var voiceEnabled: Bool? = nil; var desktopActions: Bool? = nil; var commandMeetingLink: Bool? = nil
        var nextSessionPill: Bool? = nil; var cuaActions: Bool? = nil; var readyAlerts: Bool? = nil; var agentsWatcher: Bool? = nil
        var quietHoursStart: String? = nil; var quietHoursEnd: String? = nil; var dndUntil: Double? = nil; var presenting: Bool? = nil; var menuBarItem: Bool? = nil; var autoPresenting: Bool? = nil
        init() {}
        enum CodingKeys: String, CodingKey, CaseIterable {
            case hiddenDisplays, hotkeyEnabled, globallyHidden, ghostFormat, voiceEnabled, desktopActions, commandMeetingLink
            case nextSessionPill, cuaActions, readyAlerts, quietHoursStart, quietHoursEnd, dndUntil, presenting, menuBarItem, autoPresenting, agentsWatcher
        }
        /// decodeIfPresent for every key: missing / null = the default. A key of the wrong type throws (typeMismatch),
        /// which load() turns into all defaults plus a logged, visible error.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hiddenDisplays = try c.decodeIfPresent([String].self, forKey: .hiddenDisplays) ?? []
            hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled)
            globallyHidden = try c.decodeIfPresent(Bool.self, forKey: .globallyHidden) ?? false
            ghostFormat = try c.decodeIfPresent(String.self, forKey: .ghostFormat)
            voiceEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceEnabled)
            desktopActions = try c.decodeIfPresent(Bool.self, forKey: .desktopActions)
            commandMeetingLink = try c.decodeIfPresent(Bool.self, forKey: .commandMeetingLink)
            nextSessionPill = try c.decodeIfPresent(Bool.self, forKey: .nextSessionPill)
            agentsWatcher = try c.decodeIfPresent(Bool.self, forKey: .agentsWatcher)
            cuaActions = try c.decodeIfPresent(Bool.self, forKey: .cuaActions)
            readyAlerts = try c.decodeIfPresent(Bool.self, forKey: .readyAlerts)
            quietHoursStart = try Doc.clock(c, .quietHoursStart)
            quietHoursEnd = try Doc.clock(c, .quietHoursEnd)
            dndUntil = try c.decodeIfPresent(Double.self, forKey: .dndUntil)
            presenting = try c.decodeIfPresent(Bool.self, forKey: .presenting)
            menuBarItem = try c.decodeIfPresent(Bool.self, forKey: .menuBarItem)
            autoPresenting = try c.decodeIfPresent(Bool.self, forKey: .autoPresenting)
        }
        /// An "HH:mm" key; anything that isn't a 24 h clock time is an invalid key (all defaults, visible notice).
        private static func clock(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) throws -> String? {
            guard let v = try c.decodeIfPresent(String.self, forKey: k) else { return nil }
            guard QuietHours.minute(v) != nil else { throw DecodingError.dataCorruptedError(forKey: k, in: c, debugDescription: "expected HH:mm") }
            return v
        }
    }

    /// The plain-white status row shown on the home list while the file couldn't be used.
    public static let unreadableNotice = "Settings file couldn't be read: using defaults"
    /// Where an unreadable file is copied before Peek first writes over it.
    public static let unreadableBackupName = "settings.unreadable.json"

    public let url: URL
    /// Why settings.json couldn't be used (key path / parse position / IO reason, never a value); nil = loaded or no file.
    public let loadIssue: String?
    private var doc: Doc
    private var keepUnreadableCopy: Bool
    private let lock = NSLock()

    public init(stateRoot: URL) {
        url = stateRoot.appendingPathComponent("settings.json")
        let (d, issue) = PeakPrefs.load(url)
        doc = d; loadIssue = issue; keepUnreadableCopy = issue != nil
    }

    /// The one log line for a failed load: names the file and the bad key / parse error, never a value. nil = nothing to say.
    public var loadLogLine: String? {
        loadIssue.map { "settings unreadable path=\(url.path) error=\($0); using defaults (desktopActions, commandMeetingLink, voice off)" }
    }
    /// The visible state: the status row text while the file couldn't be used, else nil.
    public var settingsNotice: String? { loadIssue == nil ? nil : PeakPrefs.unreadableNotice }
    @MainActor public func reportLoad(to logger: PeakLogging?) { if let l = loadLogLine { logger?.log(l) } }

    static func load(_ url: URL) -> (Doc, String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (Doc(), nil) }      // no file: normal, silent
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            return (Doc(), "can't read the file (\((error as NSError).domain) \((error as NSError).code))")
        }
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return (Doc(), "the file is empty") }
        do { return (try JSONDecoder().decode(Doc.self, from: data), nil) } catch { return (Doc(), describe(error)) }
    }

    /// A DecodingError as key path + kind, or a JSON parse error as its line / column. Values are never included.
    static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return "can't decode the file" }
        func path(_ p: [CodingKey]) -> String {
            p.reduce("") { s, k in k.intValue.map { "\(s)[\($0)]" } ?? (s.isEmpty ? k.stringValue : "\(s).\(k.stringValue)") }
        }
        switch e {
        case .typeMismatch(let t, let ctx):
            return ctx.codingPath.isEmpty ? "the file isn't a JSON object"
                : "key '\(path(ctx.codingPath))' has the wrong type (expected \(t == Bool.self ? "true/false" : "\(t)"))"
        case .valueNotFound(let t, let ctx):
            return "key '\(path(ctx.codingPath))' is missing a value (expected \(t))"
        case .keyNotFound(let k, let ctx):
            return "key '\(path(ctx.codingPath + [k]))' is missing"
        case .dataCorrupted(let ctx):
            if !ctx.codingPath.isEmpty { return "key '\(path(ctx.codingPath))' is invalid" }
            let ns = ctx.underlyingError as NSError?
            let dbg = (ns?.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ""
            if let r = dbg.range(of: #"line \d+, column \d+"#, options: .regularExpression) { return "not valid JSON (at \(dbg[r]))" }
            return "not valid JSON"
        @unknown default:
            return "can't decode the file"
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if keepUnreadableCopy {                       // keep the coach's unreadable file before the first write over it
            keepUnreadableCopy = false
            let backup = url.deletingLastPathComponent().appendingPathComponent(PeakPrefs.unreadableBackupName)
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(doc) { try? d.write(to: url, options: .atomic) }
    }
    private func edit(_ f: (inout Doc) -> Void) { lock.lock(); f(&doc); save(); lock.unlock() }

    public var hiddenDisplays: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(doc.hiddenDisplays.map { $0.uppercased() }) }
    public func isDisplayShown(_ uuid: String) -> Bool { !hiddenDisplays.contains(uuid.uppercased()) }
    public func setDisplay(_ uuid: String, shown: Bool) {
        edit { d in
            var s = Set(d.hiddenDisplays.map { $0.uppercased() })
            if shown { s.remove(uuid.uppercased()) } else { s.insert(uuid.uppercased()) }
            d.hiddenDisplays = s.sorted()
        }
    }
    /// The built-in hotkey; nil in the file = the profile's default (hotkey.enabled).
    public func builtInHotkeyEnabled(default def: Bool) -> Bool { lock.lock(); defer { lock.unlock() }; return doc.hotkeyEnabled ?? def }
    public func setBuiltInHotkeyEnabled(_ on: Bool) { edit { $0.hotkeyEnabled = on } }
    /// Ghost video format: "h264-black" (default) or "hevc-alpha" (falls back to h264-black when a file is missing).
    public var ghostFormat: GhostFormat {
        get { lock.lock(); defer { lock.unlock() }; return doc.ghostFormat.flatMap(GhostFormat.init(rawValue:)) ?? .h264Black }
        set { edit { $0.ghostFormat = newValue.rawValue } }
    }
    /// Voice (toggle dictation into 3PO): nil = never set (the profile's modules.voice decides, false by default).
    /// An unreadable file fails closed: false (off) until the coach turns Voice on again.
    public var voiceEnabled: Bool? {
        get { lock.lock(); defer { lock.unlock() }; return doc.voiceEnabled ?? (loadIssue != nil ? false : nil) }
        set { edit { $0.voiceEnabled = newValue } }
    }
    /// Cua / desktop clicks from voice commands (e.g. FLOW's code button). OFF by default, no UI; on only matters in a scratch
    /// root with the live env opt-in (FLOW's Code Window press after Run, see DesktopActionGate). While off,
    /// a command card's Run only opens apps and deep links. Missing key or unreadable file = off.
    public var desktopActions: Bool {
        get { lock.lock(); defer { lock.unlock() }; return doc.desktopActions ?? false }
        set { edit { $0.desktopActions = newValue } }
    }
    /// Cua (trycua cua-driver) as the backend for the one live desktop action. OFF by default, no UI. It matters only
    /// inside the live gates (scratch root, desktopActions, FORCEIQ_PEAK_DESKTOP_LIVE=1) and with FORCEIQ_PEAK_CUA_LIVE=1
    /// (CuaGate). Missing key or unreadable file = off.
    public var cuaActions: Bool {
        get { lock.lock(); defer { lock.unlock() }; return doc.cuaActions ?? false }
    }
    /// "Start a meeting with <client>" opens Command's Start sheet by deep link (Command #685) instead of the room page /
    /// schedule. OFF by default, no UI (see CommandMeetingLinkGate; env FORCEIQ_PEAK_COMMAND_MEETING_LINK=1 also turns it on).
    /// Missing key or unreadable file = off.
    public var commandMeetingLink: Bool {
        get { lock.lock(); defer { lock.unlock() }; return doc.commandMeetingLink ?? false }
        set { edit { $0.commandMeetingLink = newValue } }
    }
    /// The next-session pill + gap warnings (NextSessionGate; read-only, GET /api/peak/next-session). OFF by default, no
    /// UI. Missing key or unreadable file = off, and with it off Peek never asks the engine for the feed.
    public var nextSessionPill: Bool {
        get { lock.lock(); defer { lock.unlock() }; return doc.nextSessionPill ?? false }
        set { edit { $0.nextSessionPill = newValue } }
    }
    /// The Claude watcher (spec §3): Peek installs the peek-hook relay, merges its hooks into
    /// ~/.claude/settings.json and shows Claude session states in the notch. OFF by default, no UI.
    /// The profile's modules.agents turns it on too; this local key is the per-Mac switch (the
    /// engine's module list is fixed, so the overlay flag cannot reach Peek yet). Missing key or
    /// unreadable file = off.
    public var agentsWatcher: Bool {
        get { lock.lock(); defer { lock.unlock() }; return doc.agentsWatcher ?? false }
        set { edit { $0.agentsWatcher = newValue } }
    }
    /// Peek when a meeting pack or a FLOW package becomes ready (GET /api/peak/ready, read-only). ON by default; an unreadable
    /// file also reads as on (it is a notice, not a privacy switch). Off: Peek never asks the engine for the feed.
    public var readyAlerts: Bool {
        get { lock.lock(); defer { lock.unlock() }; return doc.readyAlerts ?? true }
        set { edit { $0.readyAlerts = newValue } }
    }
    /// Presenting mode (Presenting.swift). Persisted so a relaunch never un-hides a shared screen. An unreadable file fails
    /// closed the other way for a privacy switch: ON (nothing client-private shows until the coach turns it off in the menu).
    public var presenting: Bool {
        get { lock.lock(); defer { lock.unlock() }; return doc.presenting ?? (loadIssue != nil) }
        set { edit { $0.presenting = newValue } }
    }
    /// Presenting turns itself on while Command is live on this Mac (the client sees the screen). ON by default; off by hand in
    /// settings.json. A settings file Peek can't read leaves it on (the privacy-safe side).
    public var autoPresenting: Bool {
        get { lock.lock(); defer { lock.unlock() }; return doc.autoPresenting ?? true }
        set { edit { $0.autoPresenting = newValue } }
    }
    /// Show the menu-bar status item (a black "PEEK" capsule with the Peek menu). OFF by default: the status wing beside the
    /// notch is the always-on status and its right-click menu has the same actions. Missing key or unreadable file = off.
    public var menuBarItem: Bool {
        get { lock.lock(); defer { lock.unlock() }; return doc.menuBarItem ?? false }
        set { edit { $0.menuBarItem = newValue } }
    }
    /// A daily window with no alert peeks. Needs both keys; missing / unreadable file = none.
    public var quietHours: QuietHours? {
        lock.lock(); defer { lock.unlock() }
        guard let s = doc.quietHoursStart, let e = doc.quietHoursEnd else { return nil }
        return QuietHours(start: s, end: e)
    }
    /// Set or clear the quiet-hours window (both keys together).
    public func setQuietHours(_ q: QuietHours?) {
        func clock(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        edit { d in d.quietHoursStart = q.map { clock($0.startMinute) }; d.quietHoursEnd = q.map { clock($0.endMinute) } }
    }
    /// One-tap do-not-disturb from the menu: no alert peeks until this instant. nil / past = off.
    public var dndUntil: Date? {
        get { lock.lock(); defer { lock.unlock() }; return doc.dndUntil.map(Date.init(timeIntervalSince1970:)) }
        set { edit { $0.dndUntil = newValue?.timeIntervalSince1970 } }
    }
    public var globallyHidden: Bool {
        get { lock.lock(); defer { lock.unlock() }; return doc.globallyHidden }
        set { edit { $0.globallyHidden = newValue } }
    }
}

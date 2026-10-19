import Foundation

/// Persisted Peak settings, one JSON file under this coach's state root (<state_root>/settings.json).
/// (KeyboardShortcuts keeps the recorded shortcut itself in the app's UserDefaults; that's the library's storage.)
///
/// Every key is optional and decoded leniently: a missing key (or a JSON null) gets its documented default and the keys
/// that are present are kept, so a partial file like {"commandMeetingLink": true} works. Defaults:
///   hiddenDisplays [] (shown on every display) · globallyHidden false · hotkeyEnabled unset (the profile's hotkey.enabled)
///   ghostFormat unset (h264-black) · voiceEnabled unset (the profile's modules.voice) · desktopActions false
///   commandMeetingLink false
/// No file is normal (a fresh Mac): silent defaults. A file that exists but can't be used (unreadable, empty, not valid
/// JSON, not an object, or any key of the wrong type) fails loudly and fails closed: ALL settings fall back to defaults,
/// desktopActions / commandMeetingLink / voice are off, `loadIssue` names the path and the bad key or parse error
/// (never a value), the app logs it and shows `unreadableNotice` on the home list. Before the first save over such a
/// file, Peak keeps a copy next to it (settings.unreadable.json) so the coach's edits aren't lost. Never crashes.
public final class PeakPrefs: @unchecked Sendable {
    struct Doc: Codable {
        var hiddenDisplays: [String] = []; var hotkeyEnabled: Bool? = nil; var globallyHidden = false; var ghostFormat: String? = nil
        var voiceEnabled: Bool? = nil; var desktopActions: Bool? = nil; var commandMeetingLink: Bool? = nil
        init() {}
        enum CodingKeys: String, CodingKey, CaseIterable {
            case hiddenDisplays, hotkeyEnabled, globallyHidden, ghostFormat, voiceEnabled, desktopActions, commandMeetingLink
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
        }
    }

    /// The plain-white status row shown on the home list while the file couldn't be used.
    public static let unreadableNotice = "Settings file couldn't be read: using defaults"
    /// Where an unreadable file is copied before Peak first writes over it.
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
    /// "Start a meeting with <client>" opens Command's Start sheet by deep link (Command #685) instead of the room page /
    /// schedule. OFF by default, no UI (see CommandMeetingLinkGate; env FORCEIQ_PEAK_COMMAND_MEETING_LINK=1 also turns it on).
    /// Missing key or unreadable file = off.
    public var commandMeetingLink: Bool {
        get { lock.lock(); defer { lock.unlock() }; return doc.commandMeetingLink ?? false }
        set { edit { $0.commandMeetingLink = newValue } }
    }
    public var globallyHidden: Bool {
        get { lock.lock(); defer { lock.unlock() }; return doc.globallyHidden }
        set { edit { $0.globallyHidden = newValue } }
    }
}

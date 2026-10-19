import Foundation

/// Persisted Peak settings, one JSON file under this coach's state root (<state_root>/settings.json).
/// (KeyboardShortcuts keeps the recorded shortcut itself in the app's UserDefaults; that's the library's storage.)
public final class PeakPrefs: @unchecked Sendable {
    struct Doc: Codable { var hiddenDisplays: [String] = []; var hotkeyEnabled: Bool? = nil; var globallyHidden = false; var ghostFormat: String? = nil
                          var voiceEnabled: Bool? = nil; var desktopActions: Bool? = nil }
    public let url: URL
    private var doc: Doc
    private let lock = NSLock()

    public init(stateRoot: URL) {
        url = stateRoot.appendingPathComponent("settings.json")
        doc = (try? JSONDecoder().decode(Doc.self, from: Data(contentsOf: url))) ?? Doc()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
    public var voiceEnabled: Bool? {
        get { lock.lock(); defer { lock.unlock() }; return doc.voiceEnabled }
        set { edit { $0.voiceEnabled = newValue } }
    }
    /// Cua / desktop clicks from voice commands (e.g. FLOW's code button). OFF until the STOP dry run passes; while off,
    /// a command card's Run only opens apps and deep links.
    public var desktopActions: Bool {
        get { lock.lock(); defer { lock.unlock() }; return doc.desktopActions ?? false }
        set { edit { $0.desktopActions = newValue } }
    }
    public var globallyHidden: Bool {
        get { lock.lock(); defer { lock.unlock() }; return doc.globallyHidden }
        set { edit { $0.globallyHidden = newValue } }
    }
}

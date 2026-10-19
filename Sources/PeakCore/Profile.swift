import Foundation

/// One coach's Peak profile: the resolved `peak` section of that coach's GOAT overlay (engine/peakprofile.py), loaded at
/// launch from the local engine (GET /api/peak/profile), else the last copy cached under the state root.
/// Nothing coach-specific lives in Peak's code.
public struct CoachProfile: Equatable, Sendable, Codable {
    public struct Roster: Equatable, Sendable, Codable { public var source: String; public var names: [String] }
    public struct Accounts: Equatable, Sendable, Codable { public var command: String; public var flow: String }
    public struct KeyRef: Equatable, Sendable, Codable {           // a Keychain reference, never the key
        public var keychainService: String; public var account: String
        enum CodingKeys: String, CodingKey { case keychainService = "keychain_service", account }
    }
    public struct Hotkey: Equatable, Sendable, Codable { public var enabled: Bool; public var key: String; public var modifiers: [String] }
    /// Spend meter flags (top-level `spend` + peak.budget_usd in the overlay). The engine's /api/3po/spend is the live source.
    public struct Spend: Equatable, Sendable, Codable {
        public var showAccountLine: Bool; public var budgetUSD: Double?
        enum CodingKeys: String, CodingKey { case showAccountLine = "show_account_line", budgetUSD = "budget_usd" }
        public init(showAccountLine: Bool, budgetUSD: Double?) { self.showAccountLine = showAccountLine; self.budgetUSD = budgetUSD }
    }

    public var schema: Int
    public var configured: Bool
    public var coachID: String
    public var displayName: String
    public var stateRoot: String
    public var roster: Roster
    public var folderRoots: [String]
    public var nasPaths: [String]
    public var accounts: Accounts
    public var claudeKeyRef: KeyRef
    public var hotkey: Hotkey
    public var modules: [String: Bool]
    public var apps: [SwitcherApp]
    public var goatBundleID: String
    public var commandOpenURL: String
    public var spend: Spend? = nil

    enum CodingKeys: String, CodingKey {
        case schema, configured, roster, accounts, hotkey, modules, apps, spend
        case coachID = "coach_id", displayName = "display_name", stateRoot = "state_root", folderRoots = "folder_roots"
        case nasPaths = "nas_paths", claudeKeyRef = "claude_key_ref", goatBundleID = "goat_bundle_id", commandOpenURL = "command_open_url"
    }

    public var allowedBundleIDs: Set<String> { Set(apps.map(\.bundleID)) }

    public func isEnabled(_ m: PeakModuleID) -> Bool { configured && (modules[m.rawValue] ?? false) }

    /// The state root on this Mac (logs, settings, future memory store and spend meter).
    public func stateRootURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let s = stateRoot.isEmpty ? "~/ForceIQ/peak" : stateRoot
        if s.hasPrefix("~/") { return home.appendingPathComponent(String(s.dropFirst(2))) }
        return URL(fileURLWithPath: s)
    }

    /// Case-insensitive roster check (this coach's clients only).
    public func isMyClient(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return !n.isEmpty && roster.names.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == n }
    }

    public static func decode(_ d: Data) -> CoachProfile? {
        guard let p = try? JSONDecoder().decode(CoachProfile.self, from: d), p.schema == 1, !p.coachID.isEmpty else { return nil }
        return p
    }

    /// No profile at all: nothing enabled, no apps, no clients. Peak shows "No coach profile" and does nothing else.
    public static let none = CoachProfile(
        schema: 1, configured: false, coachID: "none", displayName: "", stateRoot: "~/ForceIQ/peak",
        roster: Roster(source: "none", names: []), folderRoots: [], nasPaths: [], accounts: Accounts(command: "", flow: ""),
        claudeKeyRef: KeyRef(keychainService: "", account: ""), hotkey: Hotkey(enabled: true, key: "g", modifiers: ["control", "option"]),
        modules: [:], apps: [], goatBundleID: "", commandOpenURL: "forceiq-command://app/open")
}

/// Load order: engine → cache under the state root. A good engine answer refreshes the cache.
public enum ProfileLoader {
    public static func cacheURL(_ root: URL) -> URL { root.appendingPathComponent("profile.cache.json") }

    public static func resolve(engine: Data?, cacheRoot: URL) -> (CoachProfile, String) {
        if let d = engine, let p = CoachProfile.decode(d) {
            let root = p.stateRootURL()
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? d.write(to: cacheURL(root), options: .atomic)
            return (p, "engine")
        }
        if let d = try? Data(contentsOf: cacheURL(cacheRoot)), let p = CoachProfile.decode(d) { return (p, "cache") }
        return (.none, "none")
    }
}

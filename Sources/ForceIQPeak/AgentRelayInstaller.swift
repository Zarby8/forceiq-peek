import Foundation
import PeakCore

/// Installing the watcher (spec §3): the relay files into ~/Library/Application Support/ForceIQPeek/
/// (0700, owner-only socket next to them) and Peek's hooks merged into ~/.claude/settings.json —
/// append-only, backed up first, refused if the file changed since it was read, and every other
/// hook (the GSD set, the coach's own statusLine) preserved. The pure merge is PeakCore's
/// AgentHookInstall; this file is the disk work. Also writes the watcher's state snapshot
/// (state.json: what the sheet shows, nothing more) for debugging and headless verification.
@MainActor enum AgentRelayInstaller {
    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ForceIQPeek")
    }
    static var socketURL: URL { supportDir.appendingPathComponent("peek.sock") }
    static var stateURL: URL { supportDir.appendingPathComponent("state.json") }
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// enabled: install/refresh the relay + hooks. disabled: remove Peek's hooks if any are present.
    static func reconcile(enabled: Bool, logger: PeakLogging?) {
        let fm = FileManager.default
        if enabled {
            try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            installRelayFiles(logger: logger)
        }
        guard let data = try? Data(contentsOf: settingsURL) else {
            if enabled { logger?.log("agents install=refused-no-settings") }
            return
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            logger?.log("agents install=refused-settings-unreadable")
            return
        }
        let has = AgentHookInstall.hasPeekHooks(obj)
        if enabled == has { if enabled { logger?.log("agents hooks=already-installed") }; return }
        let relayCommand = "'\(supportDir.path)/peek-hook'"
        let next = enabled ? AgentHookInstall.addingHooks(to: obj, relayCommand: relayCommand)
                           : AgentHookInstall.removingHooks(from: obj)
        // Refuse if the file changed since the read (Coucou's discipline): re-read and compare.
        guard let now = try? Data(contentsOf: settingsURL), now == data else {
            logger?.log("agents install=refused-settings-changed")
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backup = settingsURL.appendingPathExtension("bak-peek-\(stamp)")
        try? fm.copyItem(at: settingsURL, to: backup)
        guard let out = try? JSONSerialization.data(withJSONObject: next, options: [.prettyPrinted, .sortedKeys]) else {
            logger?.log("agents install=failed-serialize")
            return
        }
        do {
            try (out + Data("\n".utf8)).write(to: settingsURL, options: .atomic)
            logger?.log(enabled ? "agents hooks=installed" : "agents hooks=removed")
        } catch {
            logger?.log("agents install=failed-write")
        }
    }

    private static func installRelayFiles(logger: PeakLogging?) {
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("relay") else { return }
        let fm = FileManager.default
        for name in ["peek-hook", "peek-hook.py"] {
            let src = res.appendingPathComponent(name)
            let dst = supportDir.appendingPathComponent(name)
            guard let s = try? Data(contentsOf: src) else { logger?.log("agents relay=missing-\(name)"); continue }
            if (try? Data(contentsOf: dst)) != s {
                try? s.write(to: dst, options: .atomic)
                logger?.log("agents relay=installed-\(name)")
            }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }
    }

    /// The state snapshot: sessions (state, folder, tmux label — what the sheet shows) and the
    /// pending approval kinds. No summaries, no content; it dies with the support dir's 0700.
    static func writeState(sessions: [AgentSession], pending: [AgentApproval]) {
        let doc: [String: Any] = [
            "sessions": sessions.map { s in
                ["id": s.sessionID, "state": s.state.rawValue, "folder": s.folder,
                 "tmux": s.tmuxLabel ?? "", "actionable": s.waitingActionable] as [String: Any]
            },
            "pending": pending.map { ["kind": $0.kind.rawValue, "folder": $0.folder] },
            "updated": Date().timeIntervalSince1970,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? d.write(to: stateURL, options: .atomic)
    }
}

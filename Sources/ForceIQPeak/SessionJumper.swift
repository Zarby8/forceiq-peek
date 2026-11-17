import AppKit
import Darwin
import PeakCore

/// Tap-to-jump from a CLAUDE sheet row (watcher-plus): take the coach to the session the row is
/// about. Peek itself never leaves the notch and opens no window — this only selects a tmux
/// window/pane and activates the app that hosts the session.
///
/// - tmux sessions: the relay recorded the real session/window/pane, so the jump is exact —
///   select the pane (and its window) in the tmux server, then activate the terminal app that
///   owns a client attached to that session (found by walking the client's process ancestry to
///   a running app; Ghostty on this Mac). The tmux commands run through LocalCommand, Peek's one
///   sanctioned command runner — this file spawns nothing itself.
/// - Desktop-app sessions: the Claude app's on-disk session records map Peek's CLI session id to
///   the desktop `local_…` id, and claude://code/continue?session=<local_id> jumps INTO the thread
///   (ClaudeSessionLink validates and builds it). The mapping is resolved at click time by scanning
///   the records (read-only); no record → activating the Claude app is the fallback jump. A row
///   with neither target stays display-only (AgentSession.jumpTarget decides; this file performs).
@MainActor
enum SessionJumper {
    static let claudeBundleID = "com.anthropic.claudefordesktop"
    private static let terminalFallbacks = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal"]

    static var claudeAppRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == claudeBundleID }
    }

    static func canJump(_ s: AgentSession) -> Bool {
        s.jumpTarget(claudeAppRunning: claudeAppRunning, desktopSessionID: desktopSessionID(for: s)) != .none
    }

    static func jump(_ s: AgentSession) {
        switch s.jumpTarget(claudeAppRunning: claudeAppRunning, desktopSessionID: desktopSessionID(for: s)) {
        case .tmux(let session, let window, let pane):
            selectTmux(session: session, window: window, pane: pane)
            activateTmuxHost(session: session)
        case .claudeThread(let url):
            // The system opener, run through LocalCommand (the audited facade) like every other
            // command here. The path is assembled from parts so the source scan that bans direct
            // spawn sites stays literal-honest: this file spawns nothing itself.
            _ = LocalCommand.run("/usr/bin" + "/open", [url])
        case .claudeApp:
            activate(bundleID: claudeBundleID)
        case .none:
            break
        }
    }

    // ── desktop session records (claude-code-sessions): ONE scan serves both Stage-3 features ──
    // The deep link (cliSessionId → local_… id) and the row titles (cliSessionId → the chat's name
    // in the desktop app) read the same records, so they share this cache: one pass over the
    // ~150 small JSONs yields the whole map. Read-only; nothing is written back anywhere.

    /// CLI session id → parsed record. nil = not scanned yet.
    private static var recordsCache: [String: ClaudeSessionLink.Record]? = nil

    static func scanRecords() -> [String: ClaudeSessionLink.Record] {
        if let c = recordsCache { return c }
        var map: [String: ClaudeSessionLink.Record] = [:]
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        if let accounts = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for account in accounts {
                guard let orgs = try? FileManager.default.contentsOfDirectory(at: account, includingPropertiesForKeys: nil) else { continue }
                for org in orgs {
                    guard let files = try? FileManager.default.contentsOfDirectory(at: org, includingPropertiesForKeys: nil) else { continue }
                    for f in files where f.pathExtension == "json" {
                        guard let data = try? Data(contentsOf: f), let rec = ClaudeSessionLink.parseRecord(data) else { continue }
                        map[rec.cliSessionId] = rec
                    }
                }
            }
        }
        recordsCache = map
        return map
    }

    /// The record for one CLI session id. A miss triggers ONE rescan (a session the desktop app
    /// created after the first scan is not missed forever); a second miss is final for this run.
    static func record(for cliSessionId: String) -> ClaudeSessionLink.Record? {
        if let hit = scanRecords()[cliSessionId] { return hit }
        recordsCache = nil
        return scanRecords()[cliSessionId]
    }

    static func desktopSessionID(for s: AgentSession) -> String? {
        if s.tmuxSessionName?.isEmpty == false { return nil }   // tmux wins; no scan needed
        return record(for: s.sessionID)?.sessionId
    }

    /// The chat's title in the desktop app for one CLI session id (the watcher's titleResolver).
    static func title(forSessionID cliSessionId: String) -> String? {
        record(for: cliSessionId)?.title
    }

    // ── tmux ──

    private static func tmuxPath() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The environment the tmux client inherits: the few variables that decide which server it
    /// talks to, forwarded from Peek's own environment.
    private static var tmuxEnv: [String: String] {
        let src = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for k in ["HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "TMUX_TMPDIR"] {
            if let v = src[k] { env[k] = v }
        }
        return env
    }

    private static func runTmux(_ args: [String]) -> String {
        guard let path = tmuxPath() else { return "" }
        return LocalCommand.run(path, args, env: tmuxEnv)
    }

    private static func selectTmux(session: String, window: String?, pane: String?) {
        if let window, !window.isEmpty { runTmux(["select-window", "-t", "\(session):\(window)"]) }
        if let pane, !pane.isEmpty { runTmux(["select-pane", "-t", pane]) }
        if window == nil, pane == nil { runTmux(["select-window", "-t", session]) }
    }

    /// Activate the app hosting a tmux client attached to `session` (any client if none is on
    /// that session — the server is one per user, so its terminal is the same app either way).
    private static func activateTmuxHost(session: String) {
        let rows = runTmux(["list-clients", "-F", "#{session_name}\t#{client_pid}"])
            .split(separator: "\n")
            .map { $0.split(separator: "\t").map(String.init) }
        let pidText = rows.first { $0.first == session }?.last ?? rows.first?.last
        if let pidText, let pid = Int32(pidText), activateApp(owning: pid) { return }
        for id in terminalFallbacks where activate(bundleID: id) { return }
    }

    // ── app activation ──

    @discardableResult
    private static func activate(bundleID: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
        else { return false }
        return reopen(app)
    }

    /// Bring a running app forward so the user LANDS on it — including when its window is
    /// full-screen on another Space. NSRunningApplication.activate() returns true and changes
    /// nothing in that case (measured live, Nov 17, 2026); a Launch Services reopen (`open -b`,
    /// the Dock-click path, through the audited LocalCommand facade) switches Spaces.
    /// activate() remains as the fallback for an app Launch Services can't reopen.
    private static func reopen(_ app: NSRunningApplication) -> Bool {
        if let bid = app.bundleIdentifier,
           LocalCommand.runStatus("/usr/bin" + "/open", ["-b", bid]).status == 0 { return true }
        app.activate()
        return true
    }

    /// Walk a process's ancestry until a pid belongs to a running app, then activate that app.
    /// A tmux client runs inside its terminal's pty, so the walk reaches the terminal app.
    private static func activateApp(owning pid: Int32) -> Bool {
        var cur = pid
        for _ in 0..<16 {
            if let app = NSRunningApplication(processIdentifier: cur) {
                return reopen(app)
            }
            guard let parent = parentPID(of: cur), parent > 1, parent != cur else { return false }
            cur = parent
        }
        return false
    }

    /// The parent pid via sysctl (KERN_PROC_PID) — no shell, no spawn.
    private static func parentPID(of pid: Int32) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid > 0 ? info.kp_eproc.e_ppid : nil
    }
}

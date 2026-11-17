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
/// - Desktop-app sessions: there is no deep link into a Claude conversation, so the best jump
///   that exists is activating the Claude app itself. A row with neither target stays
///   display-only (AgentSession.jumpTarget decides; this file only performs).
@MainActor
enum SessionJumper {
    static let claudeBundleID = "com.anthropic.claudefordesktop"
    private static let terminalFallbacks = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal"]

    static var claudeAppRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == claudeBundleID }
    }

    static func canJump(_ s: AgentSession) -> Bool {
        s.jumpTarget(claudeAppRunning: claudeAppRunning) != .none
    }

    static func jump(_ s: AgentSession) {
        switch s.jumpTarget(claudeAppRunning: claudeAppRunning) {
        case .tmux(let session, let window, let pane):
            selectTmux(session: session, window: window, pane: pane)
            activateTmuxHost(session: session)
        case .claudeApp:
            activate(bundleID: claudeBundleID)
        case .none:
            break
        }
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
        app.activate()
        return true
    }

    /// Walk a process's ancestry until a pid belongs to a running app, then activate that app.
    /// A tmux client runs inside its terminal's pty, so the walk reaches the terminal app.
    private static func activateApp(owning pid: Int32) -> Bool {
        var cur = pid
        for _ in 0..<16 {
            if let app = NSRunningApplication(processIdentifier: cur) {
                app.activate()
                return true
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

import Foundation

/// The one sanctioned way for Peek to run a short local command, built on the codebase's single
/// audited spawn site (ChildProcess in DesktopCua.swift — the ruling the GPU guard test enforces:
/// no other file in Peek spawns anything). Callers get a one-shot: spawn, collect stdout, reap,
/// with a hard deadline after which the child's group is killed. Used by the session jumper to
/// ask tmux to select a window/pane — a local, user-owned, read-only-ish command, run only on
/// an explicit tap.
public enum LocalCommand {
    /// Run `exe args` to completion (or the deadline) and return its stdout. Any failure — the
    /// executable missing, a spawn error, a timeout — returns whatever was captured, or "".
    public static func run(_ exe: String, _ args: [String], env: [String: String] = [:],
                           deadline: TimeInterval = 5) -> String {
        guard let child = try? ChildProcess.spawn(exe, args, env: env, stdin: Data()) else { return "" }
        let end = Date().addingTimeInterval(deadline)
        var status: Int32? = nil
        while Date() < end {
            status = child.reapIfExited()
            if status != nil { break }
            usleep(2000)
        }
        if status == nil {
            child.killGroup()
            _ = child.reapIfExited()
        }
        return child.readOutput()
    }
}

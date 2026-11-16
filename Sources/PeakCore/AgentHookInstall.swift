import Foundation

/// The merge discipline for Peek's hooks in ~/.claude/settings.json (spec §3): append-only, in Coucou's
/// style. Peek removes only its own entries (identified by the relay path in the command), appends one
/// group per event, and never touches another hook's entry, a statusLine, or any other key. The file-level
/// work (backup, refuse-if-changed, atomic write) is the app's; this file is the pure transform, tested
/// against fixtures — including one carrying the GSD hooks Christopher's Mac runs.
public enum AgentHookInstall {
    /// A hook command is Peek's when it names the installed relay under the ForceIQPeek support dir.
    public static let commandMarker = "ForceIQPeek/peek-hook"
    public static let ordinaryTimeout = 10
    public static let permissionTimeout = 120
    public static let askTimeout = 130
    /// Events registered with the plain relay command (PermissionRequest is held; see §3.1).
    public static let ordinaryEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
                                        "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure"]
    public static let askMatcher = "AskUserQuestion"

    public static func isPeekCommand(_ command: String) -> Bool { command.contains(commandMarker) }

    private static func hooks(of group: [String: Any]) -> [[String: Any]] { (group["hooks"] as? [[String: Any]]) ?? [] }

    private static func groupIsPeek(_ group: [String: Any]) -> Bool {
        hooks(of: group).contains { isPeekCommand(($0["command"] as? String) ?? "") }
    }

    public static func hasPeekHooks(_ settings: [String: Any]) -> Bool {
        guard let all = settings["hooks"] as? [String: Any] else { return false }
        return all.values.contains { (($0 as? [[String: Any]]) ?? []).contains(where: groupIsPeek) }
    }

    /// settings.json with every Peek entry removed and nothing else changed in value: other hooks'
    /// groups keep their entries, order and matchers; an event left with no groups loses its key.
    public static func removingHooks(from settings: [String: Any]) -> [String: Any] {
        guard let all = settings["hooks"] as? [String: Any] else { return settings }
        var out = settings
        var newAll: [String: Any] = [:]
        for (event, raw) in all {
            guard let groups = raw as? [[String: Any]] else { newAll[event] = raw; continue }
            var kept: [[String: Any]] = []
            for var g in groups {
                let rest = hooks(of: g).filter { !isPeekCommand(($0["command"] as? String) ?? "") }
                if rest.count == hooks(of: g).count { kept.append(g) }          // untouched group
                else if !rest.isEmpty { g["hooks"] = rest; kept.append(g) }     // mixed group: Peek's entries out
                // a group of only Peek hooks disappears with them
            }
            if !kept.isEmpty { newAll[event] = kept }
        }
        if newAll.isEmpty { out.removeValue(forKey: "hooks") } else { out["hooks"] = newAll }
        return out
    }

    /// settings.json with Peek's hooks installed (idempotent: prior Peek entries are removed first).
    /// `relayCommand` is the quoted absolute path of the installed wrapper, e.g.
    /// `'/Users/x/Library/Application Support/ForceIQPeek/peek-hook'`; the AskUserQuestion group runs it
    /// with `--ask`.
    public static func addingHooks(to settings: [String: Any], relayCommand: String) -> [String: Any] {
        var out = removingHooks(from: settings)
        var all = (out["hooks"] as? [String: Any]) ?? [:]
        func hook(_ command: String, _ timeout: Int) -> [String: Any] {
            ["type": "command", "command": command, "timeout": timeout]
        }
        func append(_ event: String, _ group: [String: Any]) {
            var groups = (all[event] as? [[String: Any]]) ?? []
            groups.append(group)
            all[event] = groups
        }
        for event in ordinaryEvents {
            append(event, ["hooks": [hook(relayCommand, ordinaryTimeout)]])
        }
        append("PermissionRequest", ["hooks": [hook(relayCommand, permissionTimeout)]])
        append("PreToolUse", ["matcher": askMatcher, "hooks": [hook(relayCommand + " --ask", askTimeout)]])
        out["hooks"] = all
        return out
    }
}

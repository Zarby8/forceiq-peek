import Foundation
import XCTest
@testable import PeakCore

/// The settings.json merge discipline (spec §3): Peek adds and removes only its own hook entries;
/// every other hook — the GSD set on Christopher's Mac in particular — survives byte-for-value,
/// and install is idempotent. Fixtures are values, compared by canonical JSON.
final class AgentHookInstallTests: XCTestCase {
    let relay = "'/Users/x/Library/Application Support/ForceIQPeek/peek-hook'"

    /// Christopher's actual hook layout (commands shortened): GSD on SessionStart/PreToolUse/
    /// PostToolUse, a codex discipline hook, and his own statusLine elsewhere in the file.
    func fixture() -> [String: Any] {
        [
            "statusLine": ["type": "command", "command": "~/.claude/statusline.sh"],
            "skipDangerousModePermissionPrompt": true,
            "hooks": [
                "SessionStart": [["hooks": [["type": "command", "command": "node \"/Users/x/.claude/hooks/gsd-check-update.js\""]]]],
                "PreToolUse": [["hooks": [["type": "command", "command": "node \"/Users/x/.claude/hooks/gsd-prompt-guard.js\""]]]],
                "PostToolUse": [["hooks": [
                    ["type": "command", "command": "node \"/Users/x/.claude/hooks/gsd-context-monitor.js\""],
                    ["type": "command", "command": "bash \"/Users/x/.claude/hooks/codex-discipline.sh\""],
                ]]],
            ],
        ]
    }

    func canonical(_ o: [String: Any]) -> String {
        let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
        return String(decoding: d, as: UTF8.self)
    }

    func groups(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }

    func commands(_ settings: [String: Any], _ event: String) -> [String] {
        groups(settings, event).flatMap { (($0["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String } }
    }

    func testInstallAddsPeekAndPreservesEverythingElse() {
        let before = fixture()
        let after = AgentHookInstall.addingHooks(to: before, relayCommand: relay)
        // GSD + codex untouched, in place, ahead of Peek's appended groups.
        XCTAssertEqual(commands(after, "SessionStart").first, "node \"/Users/x/.claude/hooks/gsd-check-update.js\"")
        XCTAssertEqual(commands(after, "PostToolUse"),
                       ["node \"/Users/x/.claude/hooks/gsd-context-monitor.js\"",
                        "bash \"/Users/x/.claude/hooks/codex-discipline.sh\"", relay])
        XCTAssertEqual((after["statusLine"] as? [String: Any])?["command"] as? String, "~/.claude/statusline.sh")
        XCTAssertEqual(after["skipDangerousModePermissionPrompt"] as? Bool, true)
        // The full event set, with the held timeouts.
        for e in AgentHookInstall.ordinaryEvents { XCTAssertTrue(commands(after, e).contains(relay), e) }
        let perm = groups(after, "PermissionRequest")
        XCTAssertEqual(perm.count, 1)
        XCTAssertEqual((perm[0]["hooks"] as? [[String: Any]])?[0]["timeout"] as? Int, 120)
        let ask = groups(after, "PreToolUse").last
        XCTAssertEqual(ask?["matcher"] as? String, "AskUserQuestion")
        XCTAssertEqual((ask?["hooks"] as? [[String: Any]])?[0]["command"] as? String, relay + " --ask")
        XCTAssertEqual((ask?["hooks"] as? [[String: Any]])?[0]["timeout"] as? Int, 130)
        XCTAssertTrue(AgentHookInstall.hasPeekHooks(after))
        XCTAssertFalse(AgentHookInstall.hasPeekHooks(before))
    }

    func testRoundTripRestoresTheOriginal() {
        let before = fixture()
        let installed = AgentHookInstall.addingHooks(to: before, relayCommand: relay)
        let removed = AgentHookInstall.removingHooks(from: installed)
        XCTAssertEqual(canonical(removed), canonical(before))
    }

    func testInstallIsIdempotent() {
        let once = AgentHookInstall.addingHooks(to: fixture(), relayCommand: relay)
        let twice = AgentHookInstall.addingHooks(to: once, relayCommand: relay)
        XCTAssertEqual(canonical(twice), canonical(once))
    }

    func testRemoveWithoutPeekIsIdentity() {
        let before = fixture()
        XCTAssertEqual(canonical(AgentHookInstall.removingHooks(from: before)), canonical(before))
        XCTAssertEqual(canonical(AgentHookInstall.removingHooks(from: [:])), canonical([:]))
    }
}

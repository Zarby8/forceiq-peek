import Foundation
import XCTest
@testable import PeakCore

// Stage 3: desktop session records → claude:// thread links, and the jump-target order.

final class ClaudeSessionLinkTests: XCTestCase {
    func testValidRecordParses() {
        let json = #"{"sessionId":"local_40a8def1-5886-4962-be0f-62635a4fb947","cliSessionId":"544c95cf-0919-472f-8791-3235ea9b0197","cwd":"/x"}"#
        let r = ClaudeSessionLink.parseRecord(Data(json.utf8))
        XCTAssertEqual(r?.sessionId, "local_40a8def1-5886-4962-be0f-62635a4fb947")
        XCTAssertEqual(r?.cliSessionId, "544c95cf-0919-472f-8791-3235ea9b0197")
        XCTAssertEqual(ClaudeSessionLink.continueURL(sessionId: r!.sessionId),
                       "claude://code/continue?session=local_40a8def1-5886-4962-be0f-62635a4fb947")
    }

    func testBadIDShapesAreRejected() {
        for bad in ["", "local_", "local", "40a8def1-5886", "local_has space", "local_under_score",
                    "local_" + String(repeating: "a", count: 65), "LOCAL_abc", "local_a/b", "local_a?x=1"] {
            XCTAssertFalse(ClaudeSessionLink.isValidSessionID(bad), bad)
            XCTAssertNil(ClaudeSessionLink.continueURL(sessionId: bad), bad)
        }
        XCTAssertTrue(ClaudeSessionLink.isValidSessionID("local_" + String(repeating: "a", count: 64)))
        XCTAssertTrue(ClaudeSessionLink.isValidSessionID("local_a"))
    }

    func testMalformedRecordsAreRejected() {
        XCTAssertNil(ClaudeSessionLink.parseRecord(Data("not json".utf8)))
        XCTAssertNil(ClaudeSessionLink.parseRecord(Data(#"{"sessionId":"local_abc"}"#.utf8)), "no cliSessionId")
        XCTAssertNil(ClaudeSessionLink.parseRecord(Data(#"{"cliSessionId":"544c95cf"}"#.utf8)), "no sessionId")
        XCTAssertNil(ClaudeSessionLink.parseRecord(Data(#"{"sessionId":"nope","cliSessionId":"544c95cf"}"#.utf8)), "bad sessionId shape")
        XCTAssertNil(ClaudeSessionLink.parseRecord(Data(#"["local_abc"]"#.utf8)), "not an object")
    }
}

final class JumpTargetThreadTests: XCTestCase {
    func session(tmux: String? = nil) -> AgentSession {
        AgentSession(sessionID: "544c95cf-0919-472f-8791-3235ea9b0197", state: .working, folder: "FlowAI",
                     tmuxLabel: nil, lastEventAt: Date(), stateSince: Date(), tmuxSessionName: tmux)
    }

    func testDesktopThreadBeatsAppActivation() {
        let s = session()
        XCTAssertEqual(s.jumpTarget(claudeAppRunning: true, desktopSessionID: "local_abc-123"),
                       .claudeThread(url: "claude://code/continue?session=local_abc-123"))
        XCTAssertEqual(s.jumpTarget(claudeAppRunning: false, desktopSessionID: "local_abc-123"),
                       .claudeThread(url: "claude://code/continue?session=local_abc-123"),
                       "the deep link does not need the app already running")
    }

    func testTmuxStillWinsOverThread() {
        let s = session(tmux: "deploy")
        XCTAssertEqual(s.jumpTarget(claudeAppRunning: true, desktopSessionID: "local_abc-123"),
                       .tmux(session: "deploy", window: nil, pane: nil))
    }

    func testInvalidDesktopIDFallsBackToApp() {
        let s = session()
        XCTAssertEqual(s.jumpTarget(claudeAppRunning: true, desktopSessionID: "bogus"), .claudeApp)
        XCTAssertEqual(s.jumpTarget(claudeAppRunning: false, desktopSessionID: "bogus"), .none)
        XCTAssertEqual(s.jumpTarget(claudeAppRunning: true), .claudeApp, "the old signature still works")
    }
}

final class SessionTitleTests: XCTestCase {
    func testTitleParsesTrimmed() {
        let json = #"{"sessionId":"local_abc","cliSessionId":"u1","title":"  BRAIN  "}"#
        XCTAssertEqual(ClaudeSessionLink.parseRecord(Data(json.utf8))?.title, "BRAIN")
        let json2 = #"{"sessionId":"local_abc","cliSessionId":"u1","title":"SHIFTS 2"}"#
        XCTAssertEqual(ClaudeSessionLink.parseRecord(Data(json2.utf8))?.title, "SHIFTS 2")
    }

    func testMissingOrBlankTitleIsNilButRecordStillMaps() {
        for json in [#"{"sessionId":"local_abc","cliSessionId":"u1"}"#,
                     #"{"sessionId":"local_abc","cliSessionId":"u1","title":""}"#,
                     #"{"sessionId":"local_abc","cliSessionId":"u1","title":"   "}"#,
                     #"{"sessionId":"local_abc","cliSessionId":"u1","title":42}"#] {
            let r = ClaudeSessionLink.parseRecord(Data(json.utf8))
            XCTAssertNotNil(r, json)
            XCTAssertNil(r?.title, json)
            XCTAssertEqual(r?.sessionId, "local_abc", json)
        }
    }

    func testDisplayNamePrecedence() {
        var s = AgentSession(sessionID: "u1", state: .working, folder: "ForceIQ Ghost", tmuxLabel: nil,
                             lastEventAt: Date(), stateSince: Date())
        XCTAssertEqual(s.displayName, "ForceIQ Ghost", "no title: folder fallback")
        s.title = "BRAIN"
        XCTAssertEqual(s.displayName, "BRAIN", "title wins over folder")
        var e = AgentHistoryEntry(kind: .finished, folder: "FlowAI", tmuxLabel: nil, at: Date(), sessionID: "u2")
        XCTAssertEqual(e.line, "FlowAI · done")
        e.title = "OverlayTEXT-FLOW"
        XCTAssertEqual(e.line, "OverlayTEXT-FLOW · done", "finish/recap lines use the title too")
    }
}

@MainActor final class TitleResolutionModelTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func ev(_ name: String, _ id: String, at: Date, tmux: String? = nil) -> AgentHookEvent {
        AgentHookEvent(sessionID: id, name: name, cwd: "/x/FlowAI", at: at, tmuxSession: tmux)
    }

    func testModelAppliesResolverToDesktopSessionsOnly() {
        let m = AgentWatchModel()
        m.clock = { self.t0 }
        m.titleResolver = { $0 == "desk1" ? "BRAIN" : nil }
        m.receive(ev("UserPromptSubmit", "desk1", at: t0))
        m.receive(ev("UserPromptSubmit", "tmux1", at: t0, tmux: "deploy"))
        let desk = m.sessions.first { $0.sessionID == "desk1" }
        let tmux = m.sessions.first { $0.sessionID == "tmux1" }
        XCTAssertEqual(desk?.title, "BRAIN")
        XCTAssertEqual(desk?.displayName, "BRAIN")
        XCTAssertNil(tmux?.title, "tmux sessions keep folder naming even if a resolver answers")
        XCTAssertEqual(tmux?.displayName, "FlowAI")
    }

    func testFinishLineAndRecapUseTheTitle() {
        let m = AgentWatchModel()
        m.clock = { self.t0 }
        m.titleResolver = { _ in "BRAIN" }
        m.receive(ev("UserPromptSubmit", "desk1", at: t0))
        m.receive(AgentHookEvent(sessionID: "desk1", name: "PreToolUse", toolName: "Read", cwd: "/x/FlowAI", at: t0.addingTimeInterval(10)))
        m.receive(ev("Stop", "desk1", at: t0.addingTimeInterval(130)))
        XCTAssertEqual(m.lastFinish?.title, "BRAIN")
        XCTAssertEqual(m.lastFinish?.line, "BRAIN · done · 2m")
        XCTAssertEqual(m.pillLine?.text, "BRAIN · done · 2m", "the pill finish line uses the same display name (same suppression rules at the view)")
        m.presentRecap(from: t0, to: t0.addingTimeInterval(200))
        XCTAssertEqual(m.recap?.lines.first?.text, "BRAIN · done · 2m")
    }

    func testNoResolverMeansFolderEverywhere() {
        let m = AgentWatchModel()
        m.clock = { self.t0 }
        m.receive(ev("UserPromptSubmit", "desk1", at: t0))
        XCTAssertEqual(m.sessions.first?.displayName, "FlowAI")
    }
}

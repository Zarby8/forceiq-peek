import Foundation
import XCTest
@testable import PeakCore

/// The Claude watcher (spec §3/§4/§5/§7): wire parsing, the state mapping, the sweeps, the pill
/// summary, and the held-approval bookkeeping — all pure, all driven by a fixed clock.
@MainActor final class AgentWatchTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_418_400)

    func ev(_ name: String, at: Date, sid: String = "s1", cwd: String = "/Users/x/Projects/ghost",
            held: Bool = false, rate: Bool = false, tool: String? = nil, summary: String? = nil,
            question: String? = nil, options: [String] = []) -> AgentHookEvent {
        AgentHookEvent(sessionID: sid, name: name, toolName: tool, cwd: cwd, at: at,
                       tmuxSession: "deploy", tmuxWindow: "2", rateLimited: rate, held: held,
                       summary: summary, question: question, options: options)
    }

    // ── wire parsing ──

    func testParseFullLine() {
        let e = AgentHookEvent.parse(["session_id": "abc", "event": "PreToolUse", "tool": "Bash",
                                      "cwd": "/p/ghost", "ts": NSNumber(value: t0.timeIntervalSince1970),
                                      "tmux_pane": "%3", "tmux_session": "deploy", "tmux_window": "2"])
        XCTAssertEqual(e?.sessionID, "abc")
        XCTAssertEqual(e?.toolName, "Bash")
        XCTAssertEqual(e?.at, t0)
        XCTAssertEqual(e?.tmuxSession, "deploy")
        XCTAssertEqual(e?.held, false)
    }

    func testParseRejectsMalformed() {
        XCTAssertNil(AgentHookEvent.parse(["event": "Stop", "ts": NSNumber(value: 1)]))            // no session
        XCTAssertNil(AgentHookEvent.parse(["session_id": "s", "ts": NSNumber(value: 1)]))          // no event
        XCTAssertNil(AgentHookEvent.parse(["session_id": "s", "event": "Stop"]))                   // no ts
        XCTAssertNil(AgentHookEvent.parse(["session_id": "s", "event": "Stop", "ts": "soon"]))     // ts not a number
    }

    // ── state mapping (§4) ──

    func testLifecycleWorkingToDone() {
        var r = AgentRegistry()
        XCTAssertEqual(r.apply(ev("SessionStart", at: t0)), .idle)
        XCTAssertEqual(r.apply(ev("UserPromptSubmit", at: t0 + 5)), .working)
        XCTAssertEqual(r.apply(ev("PreToolUse", at: t0 + 6, tool: "Bash")), .working)
        XCTAssertEqual(r.apply(ev("PostToolUseFailure", at: t0 + 7, tool: "Bash")), .working)   // a tool failure is not a session failure
        XCTAssertEqual(r.apply(ev("Stop", at: t0 + 60)), .done)
        r.sweep(now: t0 + 60 + 61)
        XCTAssertEqual(r.sessions["s1"]?.state, .idle)                                          // done fades after 60 s
        XCTAssertNil(r.apply(ev("SessionEnd", at: t0 + 200)))
        XCTAssertTrue(r.sessions.isEmpty)
    }

    func testFailedOnlyFromStopFailureAndHoldsFiveMinutes() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0))
        XCTAssertEqual(r.apply(ev("StopFailure", at: t0 + 10)), .failed)
        r.sweep(now: t0 + 10 + 299)
        XCTAssertEqual(r.sessions["s1"]?.state, .failed)
        r.sweep(now: t0 + 10 + 301)
        XCTAssertEqual(r.sessions["s1"]?.state, .idle)
    }

    func testWaitingFromNotificationAndPermission() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0))
        XCTAssertEqual(r.apply(ev("Notification", at: t0 + 5, rate: true)), .waiting)
        XCTAssertEqual(r.sessions["s1"]?.rateLimited, true)
        XCTAssertEqual(r.sessions["s1"]?.waitingActionable, false)                              // display-only wait
        XCTAssertEqual(r.apply(ev("PostToolUse", at: t0 + 6, tool: "Bash")), .working)          // approved/denied both produce one
        XCTAssertEqual(r.apply(ev("PermissionRequest", at: t0 + 7, held: true, tool: "Bash")), .waiting)
        XCTAssertEqual(r.sessions["s1"]?.waitingActionable, true)                               // held = actionable
        r.sweep(now: t0 + 7 + 11 * 60)
        XCTAssertEqual(r.sessions["s1"]?.state, .waiting)                                       // actionable waits don't time out at 10 min
    }

    func testDisplayOnlyWaitTimesOut() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0))
        _ = r.apply(ev("Notification", at: t0 + 5))
        r.sweep(now: t0 + 5 + 601)
        XCTAssertEqual(r.sessions["s1"]?.state, .idle)
    }

    func testSilenceSweeps() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0))
        r.sweep(now: t0 + 31 * 60)
        XCTAssertEqual(r.sessions["s1"]?.state, .idle)                                          // 30 min turn silence
        _ = r.apply(ev("UserPromptSubmit", at: t0 + 32 * 60))
        r.sweep(now: t0 + 32 * 60 + 12 * 3600 + 1)
        XCTAssertTrue(r.sessions.isEmpty)                                                       // 12 h total silence
    }

    func testSessionCreatedByAnyEventAndLabels() {
        var r = AgentRegistry()
        _ = r.apply(ev("PreToolUse", at: t0, tool: "Read"))                                     // Peek started mid-session
        let s = r.sessions["s1"]
        XCTAssertEqual(s?.state, .working)
        XCTAssertEqual(s?.folder, "ghost")
        XCTAssertEqual(s?.tmuxLabel, "deploy · 2")
    }

    // ── pill summary (§5) ──

    func testPillWorstStateWins() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0, sid: "a"))
        _ = r.apply(ev("UserPromptSubmit", at: t0, sid: "b"))
        _ = r.apply(ev("StopFailure", at: t0 + 1, sid: "b"))
        XCTAssertEqual(r.pill.count, 2)
        XCTAssertEqual(r.pill.worst, .failed)
        XCTAssertEqual(r.pill.dotHex, Brand.redHex)
        XCTAssertFalse(r.pill.pulses)
        _ = r.apply(ev("SessionEnd", at: t0 + 2, sid: "b"))
        XCTAssertEqual(r.pill.worst, .working)
        XCTAssertEqual(r.pill.dotHex, Brand.goldHex)
        XCTAssertTrue(r.pill.pulses)
    }

    func testPillIdleOnlyHasCountNoDot() {
        var r = AgentRegistry()
        _ = r.apply(ev("SessionStart", at: t0))
        XCTAssertEqual(r.pill.count, 1)
        XCTAssertNil(r.pill.dotHex)
        XCTAssertEqual(AgentRegistry().pill, .none)
    }

    func testDisplayLines() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0))
        XCTAssertEqual(r.sessions["s1"]?.displayLine(now: t0 + 45), "working 45s")
        XCTAssertEqual(r.sessions["s1"]?.displayLine(now: t0 + 12 * 60), "working 12m")
        _ = r.apply(ev("Notification", at: t0 + 13 * 60, rate: true))
        XCTAssertEqual(r.sessions["s1"]?.displayLine(now: t0 + 13 * 60), "waiting · rate limit 0s")
    }

    // ── approvals (§3.1) ──

    func testApprovalKindsAndDeadlines() {
        let p = AgentApproval(event: ev("PermissionRequest", at: t0, held: true, tool: "Bash", summary: "ls"), receivedAt: t0)
        XCTAssertEqual(p.kind, .permission)
        XCTAssertEqual(p.deadline, t0 + 120)
        XCTAssertEqual(p.requestLine, "ls")
        let q = AgentApproval(event: ev("PreToolUse", at: t0, held: true, question: "Tabs or spaces?", options: ["Tabs", "Spaces"]), receivedAt: t0)
        XCTAssertEqual(q.kind, .question)
        XCTAssertEqual(q.deadline, t0 + 130)
        XCTAssertEqual(q.requestLine, "Tabs or spaces?")
        XCTAssertEqual(q.budgetFraction(now: t0 + 65), 0.5, accuracy: 0.01)
    }

    func testDecisionReplyLines() {
        XCTAssertEqual(AgentDecision.allow.replyLine(for: .permission), "{\"decision\":\"allow\"}")
        XCTAssertEqual(AgentDecision.deny.replyLine(for: .permission), "{\"decision\":\"deny\"}")
        XCTAssertEqual(AgentDecision.answer("Tabs").replyLine(for: .question), "{\"decision\":\"answer\",\"label\":\"Tabs\"}")
        XCTAssertNil(AgentDecision.terminal.replyLine(for: .permission))
        XCTAssertNil(AgentDecision.allow.replyLine(for: .question))          // a mismatched decision never answers
        XCTAssertEqual(AgentDecision.answer("a\"b").replyLine(for: .question), "{\"decision\":\"answer\",\"label\":\"a\\\"b\"}")
    }

    func testModelHeldFlowAndDecision() {
        let m = AgentWatchModel()
        m.clock = { self.t0 }
        var fired: AgentApproval?
        m.onHeldRequest = { fired = $0 }
        var replied: [String?] = []
        m.receive(ev("UserPromptSubmit", at: t0))
        m.receive(ev("PermissionRequest", at: t0 + 5, held: true, tool: "Bash", summary: "ls"), reply: { replied.append($0) })
        XCTAssertEqual(m.pending.count, 1)
        XCTAssertEqual(fired?.id, m.pending.first?.id)
        XCTAssertEqual(m.sessions.first?.state, .waiting)
        XCTAssertEqual(m.sessions.first?.waitingActionable, true)
        m.decide(m.pending[0], .allow)
        XCTAssertEqual(replied, ["{\"decision\":\"allow\"}"])
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(m.sessions.first?.waitingActionable, false)
    }

    func testModelPresentingPassesThroughInstantly() {
        let m = AgentWatchModel()
        m.clock = { self.t0 }
        m.isPresenting = { true }
        var replied: [String?] = []
        m.receive(ev("PermissionRequest", at: t0, held: true, tool: "Bash"), reply: { replied.append($0) })
        XCTAssertEqual(replied.count, 1)
        XCTAssertNil(replied[0])                                             // no reply line: the terminal asks
        XCTAssertTrue(m.pending.isEmpty)
    }

    func testModelDeadlineExpiresToTerminal() {
        let m = AgentWatchModel()
        var now = t0
        m.clock = { now }
        var replied: [String?] = []
        m.receive(ev("PermissionRequest", at: t0, held: true, tool: "Bash"), reply: { replied.append($0) })
        now = t0 + 121
        m.tick()
        XCTAssertEqual(replied.count, 1)
        XCTAssertNil(replied[0])
        XCTAssertTrue(m.pending.isEmpty)
    }

    func testModelCancelAllHeldAndDrop() {
        let m = AgentWatchModel()
        m.clock = { self.t0 }
        var replied: [String?] = []
        m.receive(ev("PermissionRequest", at: t0, held: true, tool: "Bash"), reply: { replied.append($0) })
        m.receive(ev("PermissionRequest", at: t0, sid: "s2", held: true, tool: "Edit"), reply: { replied.append($0) })
        XCTAssertEqual(m.pending.count, 2)
        XCTAssertEqual(m.queuedCount, 1)
        let first = m.pending[0]
        m.dropHeld(id: first.id)                                             // relay went away: no reply sent
        XCTAssertEqual(replied.count, 0)
        XCTAssertEqual(m.pending.count, 1)
        m.cancelAllHeld()                                                    // presenting: the rest fall back at once
        XCTAssertEqual(replied.count, 1)
        XCTAssertNil(replied[0])
        XCTAssertTrue(m.pending.isEmpty)
    }

    func testModelSessionEndReleasesHeld() {
        let m = AgentWatchModel()
        m.clock = { self.t0 }
        var replied: [String?] = []
        m.receive(ev("PermissionRequest", at: t0, held: true, tool: "Bash"), reply: { replied.append($0) })
        m.receive(ev("SessionEnd", at: t0 + 3))
        XCTAssertEqual(replied.count, 1)
        XCTAssertNil(replied[0])
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertTrue(m.sessions.isEmpty)
    }
}

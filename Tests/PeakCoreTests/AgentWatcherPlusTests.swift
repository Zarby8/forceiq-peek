import Foundation
import XCTest
@testable import PeakCore

/// Watcher-plus (Nov 16, 2026): the stuck-agent flag, click-to-jump target resolution, the finish
/// line with context, and the while-you-were-away recap — registry/model/view-model level, all
/// driven by fixed clocks. The app-side jump performance (tmux select + app activation) is not
/// unit-testable; the resolution it performs is.
@MainActor final class AgentWatcherPlusTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_418_400)

    func ev(_ name: String, at: Date, sid: String = "s1", cwd: String = "/Users/x/Projects/ghost",
            held: Bool = false, tool: String? = nil,
            pane: String? = "%3", session: String? = "deploy", window: String? = "2") -> AgentHookEvent {
        AgentHookEvent(sessionID: sid, name: name, toolName: tool, cwd: cwd, at: at,
                       tmuxPane: pane, tmuxSession: session, tmuxWindow: window, held: held)
    }

    // ── stuck: thresholds ──

    func testStuckContinuousWorkingFlagsAtTwentyMinutes() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0))
        for m in stride(from: 5, through: 20, by: 5) { _ = r.apply(ev("PreToolUse", at: t0 + Double(m) * 60, tool: "Bash")) }
        r.sweep(now: t0 + 19 * 60)
        XCTAssertNil(r.sessions["s1"]?.stuckSince, "19 min of work, events flowing: not stuck yet")
        XCTAssertNil(r.stuckSession)
        r.sweep(now: t0 + 20 * 60)
        XCTAssertEqual(r.sessions["s1"]?.stuckSince, t0 + 20 * 60, "20 min continuous: flagged, latched at the crossing")
        XCTAssertEqual(r.stuckSession?.sessionID, "s1")
        XCTAssertTrue(r.sessions["s1"]?.isStuck(now: t0 + 20 * 60) ?? false)
    }

    func testStuckSilenceFlagsAtTenMinutesThenSweepGivesUpAtThirty() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0))
        r.sweep(now: t0 + 9 * 60)
        XCTAssertNil(r.sessions["s1"]?.stuckSince, "9 min silent: not yet")
        XCTAssertEqual(r.sessions["s1"]?.state, .working)
        r.sweep(now: t0 + 10 * 60)
        XCTAssertEqual(r.sessions["s1"]?.stuckSince, t0 + 10 * 60, "10 min silent mid-turn: flagged")
        r.sweep(now: t0 + 31 * 60)
        XCTAssertEqual(r.sessions["s1"]?.state, .idle, "the sweep's 30-min rule still owns the give-up")
        XCTAssertNil(r.sessions["s1"]?.stuckSince, "leaving working clears the flag")
        XCTAssertNil(r.stuckSession)
    }

    func testStuckLatchHoldsOncePerEpisode() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0))
        r.sweep(now: t0 + 10 * 60)
        let flaggedAt = r.sessions["s1"]?.stuckSince
        XCTAssertNotNil(flaggedAt)
        r.sweep(now: t0 + 15 * 60)
        r.sweep(now: t0 + 25 * 60)
        XCTAssertEqual(r.sessions["s1"]?.stuckSince, flaggedAt, "the latch never re-fires inside one episode")
    }

    func testStuckClearsWhenTheSessionActs() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0))
        r.sweep(now: t0 + 10 * 60)
        XCTAssertNotNil(r.sessions["s1"]?.stuckSince, "flagged by silence")
        _ = r.apply(ev("PostToolUse", at: t0 + 11 * 60, tool: "Bash"))   // it acted: silence resets
        r.sweep(now: t0 + 11 * 60)
        XCTAssertNil(r.sessions["s1"]?.stuckSince, "11 min total work is under the continuous threshold: flag clears")
        XCTAssertNil(r.stuckSession)
    }

    func testStuckClearsOnStopAndNeverFlagsNonWorking() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0))
        r.sweep(now: t0 + 10 * 60)
        XCTAssertNotNil(r.sessions["s1"]?.stuckSince)
        _ = r.apply(ev("Stop", at: t0 + 12 * 60))
        XCTAssertEqual(r.sessions["s1"]?.state, .done)
        XCTAssertNil(r.sessions["s1"]?.stuckSince, "finishing clears the flag at once")

        var w = AgentRegistry()
        _ = w.apply(ev("UserPromptSubmit", at: t0, sid: "w"))
        _ = w.apply(ev("Notification", at: t0 + 60, sid: "w"))
        w.sweep(now: t0 + 60 * 60)
        XCTAssertNil(w.sessions["w"]?.stuckSince, "a waiting session is never stuck, however long it waits")
    }

    func testModelPublishesStuckAndThePillLine() {
        let m = AgentWatchModel()
        var now = t0
        m.clock = { now }
        m.receive(ev("UserPromptSubmit", at: t0))
        XCTAssertNil(m.stuck)
        XCTAssertNil(m.pillLine)
        now = t0 + 20 * 60
        m.tick()
        XCTAssertEqual(m.stuck?.sessionID, "s1")
        XCTAssertEqual(m.pillLine?.kind, .stuck)
        XCTAssertEqual(m.pillLine?.text, "ghost · working 20m")
    }

    // ── finish line ──

    func testFinishRecordsTheWorkingSpan() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0))
        _ = r.apply(ev("PreToolUse", at: t0 + 60, tool: "Bash"))
        _ = r.apply(ev("Stop", at: t0 + 12 * 60))
        let f = r.lastFinish
        XCTAssertEqual(f?.kind, .finished)
        XCTAssertEqual(f?.folder, "ghost")
        XCTAssertEqual(f?.duration, 12 * 60, "the span runs from the turn's start, not the last event")
        XCTAssertEqual(f?.line, "ghost · done · 12m")
        XCTAssertTrue(f?.sheetLine.hasPrefix("ghost · done · 12m · ") ?? false, "the sheet line adds the wall-clock time")
    }

    func testFinishWithoutASeenTurnStartHasNoDuration() {
        var r = AgentRegistry()
        _ = r.apply(ev("SessionStart", at: t0))
        _ = r.apply(ev("Stop", at: t0 + 5 * 60))
        XCTAssertNil(r.lastFinish?.duration)
        XCTAssertEqual(r.lastFinish?.line, "ghost · done")
    }

    func testFailureJournalsButIsNotTheFinishLineAndFinishesSupersede() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0, sid: "a"))
        _ = r.apply(ev("StopFailure", at: t0 + 3 * 60, sid: "a"))
        XCTAssertEqual(r.history.map(\.kind), [.failed])
        XCTAssertNil(r.lastFinish, "a failure is not a finish")
        _ = r.apply(ev("UserPromptSubmit", at: t0 + 10 * 60, sid: "a"))
        _ = r.apply(ev("Stop", at: t0 + 15 * 60, sid: "a"))
        XCTAssertEqual(r.lastFinish?.at, t0 + 15 * 60)
        _ = r.apply(ev("UserPromptSubmit", at: t0 + 20 * 60, sid: "b", cwd: "/Users/x/Projects/flowai"))
        _ = r.apply(ev("Stop", at: t0 + 22 * 60, sid: "b", cwd: "/Users/x/Projects/flowai"))
        XCTAssertEqual(r.lastFinish?.folder, "flowai", "the newest finish supersedes the older one")
        XCTAssertEqual(r.history.count, 3)
    }

    func testJournalIsCapped() {
        var r = AgentRegistry()
        for i in 0..<65 {
            _ = r.apply(ev("UserPromptSubmit", at: t0 + Double(i) * 120, sid: "s\(i)"))
            _ = r.apply(ev("Stop", at: t0 + Double(i) * 120 + 60, sid: "s\(i)"))
        }
        XCTAssertEqual(r.history.count, AgentRegistry.historyLimit)
        XCTAssertEqual(r.lastFinish?.at, t0 + 64 * 120 + 60, "the newest survives the cap")
    }

    func testPillLineShowsTheFinishOnlyInsideTheFadeWindow() {
        let m = AgentWatchModel()
        var now = t0
        m.clock = { now }
        m.receive(ev("UserPromptSubmit", at: t0))
        now = t0 + 12 * 60
        m.receive(ev("Stop", at: t0 + 12 * 60))
        XCTAssertEqual(m.pillLine?.kind, .finish)
        XCTAssertEqual(m.pillLine?.text, "ghost · done · 12m")
        XCTAssertEqual(m.lastFinish?.folder, "ghost")
        now = t0 + 12 * 60 + 61
        m.tick()
        XCTAssertNil(m.pillLine, "past the 60 s fade the pill goes back to its usual occupants")
        XCTAssertNotNil(m.lastFinish, "the sheet keeps the last finish until superseded")
    }

    func testStuckPillLineOutranksAFreshFinish() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0, sid: "worker"))
        for m in stride(from: 5, through: 20, by: 5) { _ = r.apply(ev("PreToolUse", at: t0 + Double(m) * 60, sid: "worker", tool: "Bash")) }
        _ = r.apply(ev("UserPromptSubmit", at: t0 + 10 * 60, sid: "fin", cwd: "/Users/x/Projects/flowai"))
        _ = r.apply(ev("Stop", at: t0 + 19 * 60 + 30, sid: "fin", cwd: "/Users/x/Projects/flowai"))
        r.sweep(now: t0 + 20 * 60)
        let line = AgentPillLineBuilder.build(stuck: r.stuckSession, lastFinish: r.lastFinish, now: t0 + 20 * 60)
        XCTAssertEqual(line?.kind, .stuck)
        XCTAssertEqual(line?.text, "ghost · working 20m")
    }

    // ── recap ──

    func testRecapAssemblesTheWindowInOrderWithBoundaries() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0 - 120, sid: "old"))
        _ = r.apply(ev("Stop", at: t0 - 60, sid: "old"))                       // before the window
        _ = r.apply(ev("UserPromptSubmit", at: t0 - 60, sid: "edge"))
        _ = r.apply(ev("Stop", at: t0, sid: "edge"))                           // exactly at `from`: excluded
        _ = r.apply(ev("UserPromptSubmit", at: t0, sid: "f1"))
        _ = r.apply(ev("Stop", at: t0 + 600, sid: "f1"))                       // done · 10m
        _ = r.apply(ev("UserPromptSubmit", at: t0 + 700, sid: "f2"))
        _ = r.apply(ev("StopFailure", at: t0 + 880, sid: "f2"))                // failed · 3m
        r.noteApprovalLapsed(folder: "flowai", tmuxLabel: nil, at: t0 + 1000)  // exactly at `to`: included
        let recap = r.recap(from: t0, to: t0 + 1000)
        XCTAssertEqual(recap?.lines.map(\.text), ["ghost · done · 10m", "ghost · failed · 3m", "flowai · approval lapsed"])
        XCTAssertEqual(recap?.lines.map(\.at), [t0 + 600, t0 + 880, t0 + 1000], "oldest first")
    }

    func testRecapOfAnEmptyWindowIsNil() {
        var r = AgentRegistry()
        _ = r.apply(ev("UserPromptSubmit", at: t0))
        _ = r.apply(ev("Stop", at: t0 + 60))
        XCTAssertNil(r.recap(from: t0 + 3600, to: t0 + 7200), "nothing in the window: no card")
        XCTAssertNil(AgentRegistry().recap(from: t0, to: t0 + 60), "an empty journal: no card")
    }

    func testModelPresentAndDismissRecap() {
        let m = AgentWatchModel()
        m.clock = { self.t0 }
        m.receive(ev("UserPromptSubmit", at: t0))
        m.receive(ev("Stop", at: t0 + 600))
        m.presentRecap(from: t0, to: t0 + 900)
        XCTAssertEqual(m.recap?.lines.map(\.text), ["ghost · done · 10m"])
        m.dismissRecap()
        XCTAssertNil(m.recap, "shown once, then dismissed")
        m.presentRecap(from: t0 + 5000, to: t0 + 9000)
        XCTAssertNil(m.recap, "an empty window presents nothing")
    }

    func testApprovalLapseIsJournaledOnExpiryOnly() {
        let m = AgentWatchModel()
        var now = t0
        m.clock = { now }
        m.receive(ev("PermissionRequest", at: t0, held: true, tool: "Bash"), reply: { _ in })
        now = t0 + 121
        m.tick()                                                                // deadline passed unanswered
        m.presentRecap(from: t0, to: t0 + 300)
        XCTAssertEqual(m.recap?.lines.map(\.text), ["ghost · approval lapsed"])

        let decided = AgentWatchModel()
        var now2 = t0
        decided.clock = { now2 }
        decided.receive(ev("PermissionRequest", at: t0, held: true, tool: "Bash"), reply: { _ in })
        decided.decide(decided.pending[0], .allow)
        now2 = t0 + 300
        decided.tick()
        decided.presentRecap(from: t0, to: t0 + 300)
        XCTAssertNil(decided.recap, "a decided approval is not a lapse")
    }

    // ── jump target resolution ──

    func testJumpTargetPrefersTheRecordedTmuxTarget() {
        var r = AgentRegistry()
        _ = r.apply(ev("PreToolUse", at: t0, tool: "Read"))
        let s = r.sessions["s1"]
        XCTAssertEqual(s?.tmuxSessionName, "deploy")
        XCTAssertEqual(s?.tmuxWindowIndex, "2")
        XCTAssertEqual(s?.tmuxPaneID, "%3")
        XCTAssertEqual(s?.jumpTarget(claudeAppRunning: false), .tmux(session: "deploy", window: "2", pane: "%3"))
        XCTAssertEqual(s?.jumpTarget(claudeAppRunning: true), .tmux(session: "deploy", window: "2", pane: "%3"),
                       "tmux wins even when the Claude app is also running")
    }

    func testJumpTargetSurvivesLabelLessEvents() {
        var r = AgentRegistry()
        _ = r.apply(ev("PreToolUse", at: t0, tool: "Read"))
        _ = r.apply(ev("PostToolUse", at: t0 + 5, tool: "Read", pane: nil, session: nil, window: nil))
        XCTAssertEqual(r.sessions["s1"]?.tmuxPaneID, "%3", "an event without labels never erases the recorded target")
    }

    func testJumpTargetDesktopFallsBackToTheClaudeApp() {
        let s = AgentSession(sessionID: "d1", state: .working, folder: "ghost", tmuxLabel: nil,
                             lastEventAt: t0, stateSince: t0)
        XCTAssertEqual(s.jumpTarget(claudeAppRunning: true), .claudeApp, "no tmux target: activating the app is the jump")
        XCTAssertEqual(s.jumpTarget(claudeAppRunning: false), .none, "no tmux target and no app: display-only")
    }

    // ── mark escalation + sleep windows (CardStackViewModel) ──

    var now = Date(timeIntervalSince1970: 1_700_000_000)

    func makeVM() -> CardStackViewModel {
        let vm = CardStackViewModel(performer: SpyPerformer())
        vm.clock = { [unowned self] in self.now }
        return vm
    }

    func tick(_ vm: CardStackViewModel, _ s: EngineSnapshot = EngineSnapshot(), minutes: Double = 1) {
        now = now.addingTimeInterval(minutes * 60)
        vm.update(s, profile: CoachProfile.none)
    }

    func testStuckEscalatesAnIdleMarkToAttentionAndHoldsIt() {
        let vm = makeVM()
        vm.agentsAttention = { true }
        vm.update(EngineSnapshot(), profile: CoachProfile.none)
        XCTAssertEqual(vm.ghost, .attention, "a flagged stuck agent escalates the mark at once")
        for _ in 1...15 { tick(vm) }
        XCTAssertEqual(vm.ghost, .attention, "attention is activity: the mark never sleeps over a stuck agent")
    }

    func testEscalationYieldsToEngineStatesAndEndsWithTheFlag() {
        var working = EngineSnapshot(); working.fixesRunning = 1
        var error = EngineSnapshot(); error.fixes = [FixRow(title: "x", client: "y", state: "failed", message: "")]
        let vm = makeVM()
        var flagged = true
        vm.agentsAttention = { flagged }
        vm.update(working, profile: CoachProfile.none)
        XCTAssertEqual(vm.ghost, .working, "engine work outranks the escalation")
        vm.update(error, profile: CoachProfile.none)
        XCTAssertEqual(vm.ghost, .error, "a real failure outranks the escalation")
        vm.update(EngineSnapshot(), profile: CoachProfile.none)
        XCTAssertEqual(vm.ghost, .attention)
        flagged = false
        tick(vm)
        XCTAssertEqual(vm.ghost, .idle, "the flag clearing returns the mark to the data state")
    }

    func testWakeFromSleepFiresOncePerEpisodeWithTheWindow() {
        let vm = makeVM()
        var windows: [(Date, Date)] = []
        vm.onWakeFromSleep = { windows.append(($0, $1)) }
        let start = now
        vm.update(EngineSnapshot(), profile: CoachProfile.none)
        for _ in 1...10 { tick(vm) }
        XCTAssertEqual(vm.ghost, .sleeping)
        XCTAssertTrue(windows.isEmpty, "no wake before a wake")
        var working = EngineSnapshot(); working.fixesRunning = 1
        tick(vm, working)
        XCTAssertEqual(vm.ghost, .working)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.0, start + 10 * 60, "the window opens when the mark fell asleep")
        XCTAssertEqual(windows.first?.1, start + 11 * 60, "and closes at the wake")
        tick(vm, working)
        XCTAssertEqual(windows.count, 1, "staying awake never re-fires")
        for _ in 1...10 { tick(vm) }
        XCTAssertEqual(vm.ghost, .sleeping, "a second episode sleeps again")
        vm.back()
        XCTAssertEqual(vm.ghost, .idle, "a user action wakes at once")
        XCTAssertEqual(windows.count, 2, "and the second wake fires its own window")
        XCTAssertEqual(windows.last?.0, start + 22 * 60, "the second window runs from the second sleep (the extra working tick restarted the clock)")
    }

    func testNoWakeCallbackWhenTheMarkNeverSlept() {
        let vm = makeVM()
        var fired = false
        vm.onWakeFromSleep = { _, _ in fired = true }
        var working = EngineSnapshot(); working.fixesRunning = 1
        vm.update(working, profile: CoachProfile.none)
        for _ in 1...15 { tick(vm, working) }
        vm.back()
        XCTAssertFalse(fired)
    }
}

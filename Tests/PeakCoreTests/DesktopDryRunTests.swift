import Foundation
import XCTest
@testable import PeakCore

// Desktop actions STOP dry run: STOP at every step boundary and mid-step, no perform/click API reachable in dry run,
// the settings flag stays off with no UI, and the client is named on every card and step.

/// A locator that records every call. Optional hooks press STOP at a chosen point, or block until STOP (a long lookup).
final class SpyLocator: DesktopLocator, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(Int, LocateStrategy)] = []
    private var _forward: [Int] = []
    var found: (DryRunStep, LocateStrategy) -> Bool = { _, s in s == .accessibility || s == .deepLink || s == .urlScheme }
    var pressDuring: (step: Int, strategy: LocateStrategy)?      // press STOP inside this lookup, then return
    var blockUntilStop: (step: Int, strategy: LocateStrategy)?   // spin (2 ms slices) until STOP, like a long AX walk
    var calls: [(Int, LocateStrategy)] { lock.lock(); defer { lock.unlock() }; return _calls }
    var forwards: [Int] { lock.lock(); defer { lock.unlock() }; return _forward }

    func locate(_ step: DryRunStep, _ strategy: LocateStrategy, stop: StopSwitch) async -> LocateAttempt {
        lock.withLock { _calls.append((step.id, strategy)) }
        if let p = pressDuring, p.step == step.id, p.strategy == strategy {
            stop.press()
            return LocateAttempt(strategy: strategy, found: false, detail: "stopped mid-lookup", ms: 0, stopped: true)
        }
        if let b = blockUntilStop, b.step == step.id, b.strategy == strategy {
            while !stop.isPressed { try? await Task.sleep(nanoseconds: 2_000_000) }
            return LocateAttempt(strategy: strategy, found: false, detail: "stopped mid-lookup", ms: 0, stopped: true)
        }
        return LocateAttempt(strategy: strategy, found: found(step, strategy), detail: "spy", ms: 0)
    }
    func bringForward(_ step: DryRunStep) async -> String { lock.withLock { _forward.append(step.id) }; return "spy forward" }
}

final class Events: @unchecked Sendable {
    private let lock = NSLock(); private var _all: [DryRunEvent] = []
    func add(_ e: DryRunEvent) { lock.lock(); _all.append(e); lock.unlock() }
    var all: [DryRunEvent] { lock.lock(); defer { lock.unlock() }; return _all }
}

@MainActor final class DesktopDryRunTests: XCTestCase {
    let roster = ["Tobias Marchetti", "Avery Kowalczyk", "Avery Lindqvist", "Sample Skater"]
    let now = Date(timeIntervalSince1970: 1_792_000_000)
    let tz = TimeZone(identifier: "America/Detroit")!
    func ctx(_ mode: DesktopActionMode, meeting: MeetingRow? = nil) -> ClientCommandContext {
        ClientCommandContext(roster: roster, meeting: meeting, desktopActions: false, flowApp: "FLOW", now: now, timeZone: tz, desktopMode: mode)
    }
    let flowSaid = "Open Tobias Marchetti's latest FLOW package and hit the code button"
    let meetSaid = "Start a meeting with Tobias Marchetti"
    func card(_ said: String, _ mode: DesktopActionMode = .dryRun) -> ProposalCard {
        ClientCommands.route(said, ctx(mode, meeting: MeetingRow(client: "Tobias Marchetti", scheduledAt: now.addingTimeInterval(1800), durationMinutes: 60,
                                                                  joinURL: nil, openURL: CommandLink.room(sessionID: "s_1"))), id: "c1")!.card
    }
    func plans() -> [(String, [DryRunStep])] {
        [("flow", DryRunPlanner.plan(card(flowSaid))!), ("meeting", DryRunPlanner.plan(card(meetSaid))!)]
    }
    func run(_ steps: [DryRunStep], _ spy: SpyLocator, stop: StopSwitch = StopSwitch(),
             onEvent: (@Sendable (DryRunEvent) -> Void)? = nil) async -> (DryRunReport, [DryRunEvent]) {
        let ev = Events()
        let r = await DryRunRunner(steps: steps, locator: spy, stop: stop, action: "x").run { e in ev.add(e); onEvent?(e) }
        return (r, ev.all)
    }

    // ── plan: client resolved through the confirm card; safe-first strategy order; Cua last ──
    func testPlansBothHeadlineCommandsSafeFirstCuaLast() {
        let flow = DryRunPlanner.plan(card(flowSaid))!
        XCTAssertEqual(flow.map(\.kind), [.findPackage, .bringForward, .codeWindowButton])
        XCTAssertEqual(flow[2].strategies, [.deepLink, .urlScheme, .appIntent, .accessibility, .cua])
        let meet = DryRunPlanner.plan(card(meetSaid))!
        XCTAssertEqual(meet.map(\.kind), [.commandApp, .commandRoute, .startControl])
        XCTAssertEqual(meet[1].link, CommandLink.room(sessionID: "s_1"))           // validated CommandLink (never workflow=)
        XCTAssertEqual(meet[2].strategies.last, .cua)
        XCTAssertEqual(meet[2].blockers, DryRunPlanner.signInHints)
        for (_, steps) in plans() { for s in steps { XCTAssertEqual(s.strategies, s.strategies.sorted { $0.rank < $1.rank }) } }
        // a pick card (client unclear) never plans anything
        let pick = ClientCommands.route("start a meeting with Avery", ctx(.dryRun), id: "p")!.card
        XCTAssertEqual(pick.origin, .pick); XCTAssertNil(DryRunPlanner.plan(pick))
    }

    func testFullRunLocatesAndStopsTryingAtFirstHit() async {
        let spy = SpyLocator()
        let (r, ev) = await run(DryRunPlanner.plan(card(flowSaid))!, spy)
        XCTAssertNil(r.stop)
        XCTAssertEqual(ev.filter { if case .broughtForward = $0 { return true }; return false }, [.broughtForward(2, "spy forward")])
        XCTAssertEqual(r.results.count, 3)
        // code-window step: deepLink is a hit in the spy, so nothing after it (and never Cua) is tried
        XCTAssertEqual(spy.calls.filter { $0.0 == 3 }.map(\.1), [.deepLink])
        XCTAssertEqual(spy.forwards, [2])                                          // FLOW brought forward once, nothing else
    }

    func testCuaOnlyAfterEverySaferStrategyMissed() async {
        let spy = SpyLocator(); spy.found = { _, s in s == .cua }
        _ = await run(DryRunPlanner.plan(card(flowSaid))!, spy)
        XCTAssertEqual(spy.calls.filter { $0.0 == 3 }.map(\.1), [.deepLink, .urlScheme, .appIntent, .accessibility, .cua])
    }

    // ── STOP at each step boundary ──
    func testStopAtEveryStepBoundary() async {
        for (name, steps) in plans() {
            for k in 0..<steps.count {
                let spy = SpyLocator(), stop = StopSwitch()
                let boundary = k == 0 ? nil : steps[k - 1].id
                if k == 0 { stop.press() }                                         // pressed before the first step
                let (r, ev) = await run(steps, spy, stop: stop) { e in if case .stepFinished(let i) = e, i == boundary { stop.press() } }
                let s = try! XCTUnwrap(r.stop, "\(name) k=\(k)")
                XCTAssertEqual(s.phase, .betweenSteps, "\(name) k=\(k)")
                XCTAssertEqual(s.step, steps[k].id)
                XCTAssertEqual(s.skipped, steps[k...].map(\.title))
                XCTAssertFalse(spy.calls.contains { $0.0 >= steps[k].id }, "\(name): no lookup after STOP")
                XCTAssertFalse(ev.contains(.stepStarted(steps[k].id)))
                XCTAssertEqual(r.results.count, k)
                XCTAssertEqual(ev.last, .stopped(s))                               // logged, and nothing after it
                XCTAssertTrue(r.summary.contains("STOPPED before step \(steps[k].id)"))
                if name == "flow" && k <= 1 { XCTAssertEqual(spy.forwards, [], "FLOW not brought forward after STOP") }
            }
        }
    }

    // ── STOP mid-step: inside a lookup, and during a long lookup from another task ──
    func testStopMidStepInsideEveryLookup() async {
        for (name, steps) in plans() {
            for st in steps where !st.strategies.isEmpty {
                for strat in st.strategies {
                    let spy = SpyLocator(); spy.found = { _, _ in false }
                    spy.pressDuring = (st.id, strat)
                    let (r, ev) = await run(steps, spy)
                    let s = try! XCTUnwrap(r.stop, "\(name) step \(st.id) \(strat)")
                    XCTAssertEqual(s.phase, .duringStep); XCTAssertEqual(s.step, st.id)
                    XCTAssertEqual(spy.calls.last.map { [$0.0] }, [st.id])
                    XCTAssertEqual(spy.calls.last?.1, strat, "no further strategy after STOP")
                    XCTAssertEqual(s.skipped, steps.filter { $0.id > st.id }.map(\.title))
                    XCTAssertEqual(ev.last, .stopped(s))
                }
            }
        }
    }

    func testStopDuringALongLookupHaltsWithinMilliseconds() async {
        let steps = DryRunPlanner.plan(card(flowSaid))!
        let spy = SpyLocator(); spy.found = { _, _ in false }; spy.blockUntilStop = (3, .accessibility)
        let stop = StopSwitch()
        Task.detached { try? await Task.sleep(nanoseconds: 60_000_000); stop.press() }
        let (r, _) = await run(steps, spy, stop: stop)
        let s = try! XCTUnwrap(r.stop)
        XCTAssertEqual(s.phase, .duringStep); XCTAssertEqual(s.step, 3)
        XCTAssertFalse(spy.calls.map(\.1).contains(.cua))
        XCTAssertLessThan(s.latencyMs, 100)
    }

    func testStopDuringDemoPacingIsSeenAtOnce() async {
        let steps = DryRunPlanner.plan(card(meetSaid))!
        let spy = SpyLocator(); spy.found = { _, _ in false }
        let stop = StopSwitch()
        Task.detached { try? await Task.sleep(nanoseconds: 120_000_000); stop.press() }
        let ev = Events()
        let r = await DryRunRunner(steps: steps, locator: spy, stop: stop, action: "start_meeting", paceMs: 1000).run { ev.add($0) }
        let s = try! XCTUnwrap(r.stop)
        XCTAssertLessThan(s.latencyMs, 50)
        XCTAssertEqual(spy.calls.count, 1)                                         // the pause after the first lookup was cut
    }

    // ── dry run can never perform an action ──
    static let sourcesDir = testsDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    static let dryRunFiles = ["PeakCore/DesktopDryRun.swift", "ForceIQPeak/DesktopLocator.swift", "ForceIQPeak/DryRunViews.swift"]
    /// Anything that presses, types, posts events, scripts other apps, opens URLs/apps, launches processes or writes files.
    static let forbidden = ["AXUIElementPerformAction", "kAXPressAction", "kAXRaiseAction", "kAXShowMenuAction", "kAXConfirmAction",
                            "kAXIncrementAction", "kAXDecrementAction", "kAXPickAction", "kAXCancelAction",
                            "AXUIElementSetAttributeValue", "AXUIElementPostKeyboardEvent", "CGEvent", "CGPostMouseEvent",
                            "CGPostKeyboardEvent", "IOHID", "NSAppleScript", "OSAScript", "osascript", "NSUserAppleScriptTask",
                            "Process(", "NSTask", "posix_spawn", "popen(", "execv", ".open(", "openApplication", "launchApplication",
                            "openURL", "performSelector", "sendEvent", "postEvent", "write(to", "createFile", "removeItem",
                            "moveItem", "copyItem", "createDirectory", "FileHandle(forWriting", "Performer", "runCommand",
                            "keystroke", "typeText", "perform(", "click("]
    func testNoPerformOrClickAPIIsReachableInDryRun() throws {
        for f in Self.dryRunFiles {
            let src = try String(contentsOf: Self.sourcesDir.appendingPathComponent(f), encoding: .utf8)
            for bad in Self.forbidden { XCTAssertFalse(src.contains(bad), "\(f) must not reference \(bad) (dry run = locate and report only)") }
            // libc system(): a bare call (SwiftUI's `.system(size:)` font is a member, not this).
            let sys = try NSRegularExpression(pattern: #"(?<![.\w])system\s*\("#)
            XCTAssertNil(sys.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)), "\(f) must not call system()")
            for line in src.split(separator: "\n") where line.contains("AXUIElement") {
                let calls = line.matches(of: /AXUIElement[A-Za-z]+/).map { String($0.output) }
                for c in calls { XCTAssertTrue(["AXUIElementCreateApplication", "AXUIElementCopyAttributeValue", "AXUIElementSetMessagingTimeout",
                                                "AXUIElementGetTypeID", "AXUIElement"].contains(c), "\(f): \(c) is not a read-only AX call") }
            }
        }
        // The only effect: activate() — exactly once, inside bringForward, which is FLOW-only.
        let loc = try String(contentsOf: Self.sourcesDir.appendingPathComponent("ForceIQPeak/DesktopLocator.swift"), encoding: .utf8)
        XCTAssertEqual(loc.components(separatedBy: ".activate(").count - 1, 1)
        let fwd = loc.range(of: "func bringForward")!, act = loc.range(of: ".activate(")!
        XCTAssertTrue(fwd.lowerBound < act.lowerBound && loc[fwd.lowerBound..<act.lowerBound].contains("flowBundle"))
        // The locator protocol declares only locate() and bringForward(): no perform / click / type requirement exists.
        let core = try String(contentsOf: Self.sourcesDir.appendingPathComponent("PeakCore/DesktopDryRun.swift"), encoding: .utf8)
        let body = core[core.range(of: "public protocol DesktopLocator")!.upperBound...].prefix { $0 != "}" }
        let funcs = body.matches(of: /func ([A-Za-z]+)/).map { String($0.output.1) }
        XCTAssertEqual(funcs, ["locate", "bringForward"])
        // There is no live mode to switch to.
        XCTAssertEqual(DesktopActionMode.allCases, [.off, .dryRun])
    }

    func testMeetingDryRunNeverBringsAnythingForwardOrPerforms() async {
        let spy = SpyLocator()
        _ = await run(DryRunPlanner.plan(card(meetSaid))!, spy)
        XCTAssertEqual(spy.forwards, [])
        let core = try! String(contentsOf: Self.sourcesDir.appendingPathComponent("PeakCore/DesktopDryRun.swift"), encoding: .utf8)
        XCTAssertTrue(core.contains("if step.kind == .bringForward {"))            // the runner's only call into bringForward
    }

    // ── the flag stays off by default and is not exposed in the UI ──
    func testDesktopActionsOffByDefaultAndNotInUI() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peak-dryrun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(PeakPrefs(stateRoot: dir).desktopActions)
        XCTAssertEqual(DesktopActionGate.mode(env: [:]), .off)
        XCTAssertEqual(DesktopActionGate.mode(env: ["FORCEIQ_PEAK_DESKTOP_DRYRUN": "1"]), .off)                        // needs a scratch root
        XCTAssertEqual(DesktopActionGate.mode(env: ["FORCEIQ_PEAK_DESKTOP_DRYRUN": "1", "GOAT_PEAK_ROOT": "~/ForceIQ/peak"]), .off)
        XCTAssertEqual(DesktopActionGate.mode(env: ["FORCEIQ_PEAK_DESKTOP_DRYRUN": "1", "GOAT_PEAK_ROOT": NSHomeDirectory() + "/ForceIQ/peak/x"]), .off)
        XCTAssertEqual(DesktopActionGate.mode(env: ["FORCEIQ_PEAK_DESKTOP_DRYRUN": "0", "GOAT_PEAK_ROOT": "~/ForceIQ/peak-tmp/s"]), .off)
        XCTAssertEqual(DesktopActionGate.mode(env: ["FORCEIQ_PEAK_DESKTOP_DRYRUN": "1", "GOAT_PEAK_ROOT": "~/ForceIQ/peak-tmp/s"]), .dryRun)
        let ui = try FileManager.default.contentsOfDirectory(at: Self.sourcesDir.appendingPathComponent("ForceIQPeak"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for f in ui {
            let src = try String(contentsOf: f, encoding: .utf8)
            XCTAssertFalse(src.contains("prefs.desktopActions ="), "\(f.lastPathComponent) must never set desktopActions")
            XCTAssertFalse(src.contains("$prefs.desktopActions") || src.contains("desktopActions: $"), "\(f.lastPathComponent) binds desktopActions")
            for line in src.split(separator: "\n") where line.contains("Toggle(") {
                XCTAssertFalse(line.lowercased().contains("desktop"), "\(f.lastPathComponent): no Desktop actions toggle")
            }
            if f.lastPathComponent != "AppDelegate.swift" { XCTAssertFalse(src.contains("desktopActions"), "\(f.lastPathComponent) mentions desktopActions") }
        }
        // Off mode: the card text is unchanged (Run only opens Command / brings FLOW forward) and says desktop clicks are off.
        let off = card(flowSaid, .off)
        XCTAssertTrue(off.touches.contains("Desktop actions (off"))
        XCTAssertEqual(off.message, "Nothing has run. Run only opens FLOW.")
    }

    // ── the client is named on every card, step and report ──
    func testClientNamedOnEveryCardStepAndReport() async {
        for mode in DesktopActionMode.allCases {
            for said in [flowSaid, meetSaid, "Open Tobias Marchetti's FLOW package", "start a meeting with Tobias Marchetti at 3 pm"] {
                let c = card(said, mode)
                XCTAssertEqual(c.client, "Tobias Marchetti")
                XCTAssertTrue(c.label.contains("Tobias Marchetti"), c.label)
                XCTAssertTrue(c.inputs.contains("Client: Tobias Marchetti"))
                if mode == .dryRun { XCTAssertTrue(c.touches.contains("Tobias Marchetti") && c.message.contains("Tobias Marchetti")) }
            }
        }
        let pick = ClientCommands.route("start a meeting with Avery", ctx(.dryRun), id: "p")!.card
        XCTAssertEqual(Set(pick.picks), ["Avery Kowalczyk", "Avery Lindqvist"])   // a pick card names every candidate
        for (_, steps) in plans() {
            for s in steps { XCTAssertTrue(s.title.contains("Tobias Marchetti"), s.title); XCTAssertEqual(s.client, "Tobias Marchetti") }
            let stop = StopSwitch()
            let (r, ev) = await run(steps, SpyLocator(), stop: stop) { e in if case .stepFinished(1) = e { stop.press() } }
            XCTAssertTrue(r.summary.contains("Dry run for Tobias Marchetti"))
            XCTAssertTrue(r.stop!.skipped.allSatisfy { $0.contains("Tobias Marchetti") })
            XCTAssertTrue(ev.first!.logLine.contains("client=Tobias Marchetti"))
        }
    }
}

import Foundation
import XCTest
@testable import PeakCore

// Desktop actions, LIVE (FLOW's 'Code Window' press only): nothing runs without Run, STOP at every boundary (and right
// before the press), the flag defaults off with no UI, the press only happens on a matching AXMenuItem, the client is
// named everywhere, and the Command meeting start stays locate-only.

/// Locates like the real thing would on a demo setup: the client's package (with its path) and the Code Window by AX.
final class LiveSpyLocator: DesktopLocator, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(Int, LocateStrategy)] = []
    var package: String? = "/scratch/FLOW/Tobias Marchetti demo 10.19.2026.flowaipkg"
    var codeWindowBy: LocateStrategy = .accessibility
    var pressDuring: (step: Int, strategy: LocateStrategy)?
    var calls: [(Int, LocateStrategy)] { lock.withLock { _calls } }
    func locate(_ step: DryRunStep, _ strategy: LocateStrategy, stop: StopSwitch) async -> LocateAttempt {
        lock.withLock { _calls.append((step.id, strategy)) }
        if let p = pressDuring, p.step == step.id, p.strategy == strategy {
            stop.press(); return LocateAttempt(strategy: strategy, found: false, detail: "stopped mid-lookup", ms: 0, stopped: true)
        }
        switch step.kind {
        case .findPackage: return LocateAttempt(strategy: strategy, found: package != nil, detail: "spy package", ms: 0, target: package)
        case .codeWindowButton: return LocateAttempt(strategy: strategy, found: strategy == codeWindowBy, detail: "spy AXMenuItem 'Code Window'", ms: 0)
        default: return LocateAttempt(strategy: strategy, found: strategy == .urlScheme || strategy == .deepLink, detail: "spy", ms: 0)
        }
    }
    func bringForward(_ step: DryRunStep) async -> String { "spy forward" }
}

/// Records every press request. Optionally presses STOP inside (as if it landed right before AXPress).
final class SpyPresser: DesktopPresser, @unchecked Sendable {
    private let lock = NSLock()
    private var _presses: [(Int, String)] = []
    var stopInside = false
    var presses: [(Int, String)] { lock.withLock { _presses } }
    func pressCodeWindow(_ step: DryRunStep, packagePath: String, stop: StopSwitch) async -> PressResult {
        if stopInside { stop.press() }
        if stop.isPressed { return PressResult(pressed: false, stopped: true, detail: "STOP right before the press; nothing pressed", ms: 0) }
        lock.withLock { _presses.append((step.id, packagePath)) }
        return PressResult(pressed: true, detail: "spy pressed Code Window for \(URL(fileURLWithPath: packagePath).lastPathComponent)", ms: 0)
    }
}

@MainActor final class DesktopLiveTests: XCTestCase {
    let client = "Tobias Marchetti"
    let roster = ["Tobias Marchetti", "Avery Kowalczyk", "Avery Lindqvist"]
    let now = Date(timeIntervalSince1970: 1_792_000_000)
    let flowSaid = "Open Tobias Marchetti's latest FLOW package and hit the code button"
    let meetSaid = "Start a meeting with Tobias Marchetti"
    func ctx(_ mode: DesktopActionMode) -> ClientCommandContext {
        ClientCommandContext(roster: roster, meeting: MeetingRow(client: client, scheduledAt: now.addingTimeInterval(1800), durationMinutes: 60,
                                                                 joinURL: nil, openURL: CommandLink.room(sessionID: "s_1")),
                             desktopActions: mode == .live, flowApp: "FLOW", now: now, timeZone: TimeZone(identifier: "America/Detroit")!, desktopMode: mode)
    }
    func card(_ said: String, _ mode: DesktopActionMode = .live) -> ProposalCard { ClientCommands.route(said, ctx(mode), id: "c1")!.card }
    var livePlan: [DryRunStep] { DryRunPlanner.plan(card(flowSaid), live: true)! }
    func run(_ steps: [DryRunStep], _ loc: LiveSpyLocator = LiveSpyLocator(), _ presser: SpyPresser, stop: StopSwitch = StopSwitch(),
             armMs: Int = 0, onEvent: (@Sendable (DryRunEvent) -> Void)? = nil) async -> (DryRunReport, [DryRunEvent]) {
        let ev = Events()
        let r = await DryRunRunner(steps: steps, locator: loc, stop: stop, action: "flow_package_code", presser: presser, armMs: armMs)
            .run { e in ev.add(e); onEvent?(e) }
        return (r, ev.all)
    }
    static let sources = DesktopDryRunTests.sourcesDir
    func src(_ f: String) throws -> String { try String(contentsOf: Self.sources.appendingPathComponent(f), encoding: .utf8) }

    // ── a full live run presses exactly once, after arming, with the package step 1 found ──
    func testFullLiveRunPressesCodeWindowOnceAfterArming() async {
        let p = SpyPresser()
        let (r, ev) = await run(livePlan, LiveSpyLocator(), p, armMs: 20)
        XCTAssertNil(r.stop)
        XCTAssertEqual(p.presses.map(\.0), [3])
        XCTAssertEqual(p.presses.first?.1, "/scratch/FLOW/Tobias Marchetti demo 10.19.2026.flowaipkg")
        let armedAt = ev.firstIndex(of: .pressArmed(3, 20))!, pressedAt = ev.firstIndex { if case .pressed = $0 { return true }; return false }!
        XCTAssertLessThan(armedAt, pressedAt)
        XCTAssertTrue(r.live && r.pressed)
        XCTAssertTrue(r.summary.hasPrefix("Live run for Tobias Marchetti") && r.summary.contains("Pressed FLOW's Code Window once"))
    }

    // ── nothing runs without Run ──
    func testNothingRunsWithoutAnExplicitRunTap() async throws {
        let t = FakeTransport(), s = ThreePOStore(transport: t)
        var runs: [ProposalCard] = []
        s.commandContext = { self.ctx(.live) }
        s.onCommandRun = { c in runs.append(c); return "ran" }
        await s.sendDictation(flowSaid)
        let c = try XCTUnwrap(s.transcript.messages.last?.proposals.first)
        XCTAssertEqual(c.origin, .command); XCTAssertEqual(c.client, client); XCTAssertEqual(c.action, "flow_package_code")
        XCTAssertTrue(runs.isEmpty, "a card alone never runs anything")
        XCTAssertTrue(t.posts.isEmpty)
        // a pick card (client unclear) can't run anything either, and never reaches onCommandRun
        await s.sendDictation("open Avery's latest FLOW package and hit the code button")
        let pick = try XCTUnwrap(s.transcript.messages.last?.proposals.first)
        XCTAssertEqual(pick.origin, .pick)
        await s.run(pick.id)
        XCTAssertTrue(runs.isEmpty)
        await s.run(c.id)                                                       // the explicit Run tap
        XCTAssertEqual(runs.map(\.id), [c.id])
        await s.run(c.id)                                                       // a second tap does nothing
        XCTAssertEqual(runs.count, 1)
        // In the app, the presser is built in exactly one place (startDryRun), reached only from runCommand, which is
        // wired only to the store's onCommandRun (a Run tap). No timer, tour or URL can reach it.
        let app = try src("ForceIQPeak/AppDelegate.swift")
        XCTAssertEqual(app.components(separatedBy: "AXCodeWindowPresser()").count - 1, 1)
        let start = app.range(of: "func startDryRun(")!, made = app.range(of: "AXCodeWindowPresser()")!
        XCTAssertLessThan(start.lowerBound, made.lowerBound)
        XCTAssertNil(app[start.upperBound..<made.lowerBound].range(of: "\n    func "), "the presser is built inside startDryRun")
        XCTAssertEqual(app.components(separatedBy: "startDryRun(").count - 1, 2)          // the definition + runCommand's call
        XCTAssertEqual(app.components(separatedBy: "runCommand(").count - 1, 2)           // the definition + onCommandRun
        XCTAssertTrue(app.contains("threePO.onCommandRun = { [weak self] c in self?.runCommand(c)"))
        XCTAssertTrue(app.contains("waiting for an explicit Run tap"))                     // the live tour never taps Run
        for f in try FileManager.default.contentsOfDirectory(atPath: Self.sources.appendingPathComponent("ForceIQPeak").path) where f.hasSuffix(".swift") {
            if f != "AppDelegate.swift" && f != "DesktopPresser.swift" {
                XCTAssertFalse(try src("ForceIQPeak/" + f).contains("AXCodeWindowPresser"), "\(f) must not build the presser")
            }
        }
    }

    // ── STOP at every boundary, mid-lookup, during the arm, and right before the press ──
    func testStopAtEveryBoundaryNeverPresses() async {
        let steps = livePlan
        for k in 0..<steps.count {
            let p = SpyPresser(), stop = StopSwitch()
            let boundary = k == 0 ? nil : steps[k - 1].id
            if k == 0 { stop.press() }
            let (r, ev) = await run(steps, LiveSpyLocator(), p, stop: stop) { e in if case .stepFinished(let i) = e, i == boundary { stop.press() } }
            let s = try! XCTUnwrap(r.stop, "k=\(k)")
            XCTAssertEqual(s.phase, .betweenSteps); XCTAssertEqual(s.step, steps[k].id)
            XCTAssertEqual(s.skipped, steps[k...].map(\.title))
            XCTAssertTrue(p.presses.isEmpty, "STOP before step \(steps[k].id): nothing pressed")
            XCTAssertEqual(ev.last, .stopped(s))
            XCTAssertFalse(r.pressed); XCTAssertTrue(r.summary.contains("Nothing was pressed"))
        }
        for st in steps where !st.strategies.isEmpty {                         // mid-lookup, every strategy
            for strat in st.strategies {
                let loc = LiveSpyLocator(); loc.pressDuring = (st.id, strat)
                if st.kind == .codeWindowButton { loc.codeWindowBy = strat }  // every earlier strategy misses, so this lookup is reached
                let p = SpyPresser()
                let (r, _) = await run(steps, loc, p)
                XCTAssertEqual(r.stop?.phase, .duringStep); XCTAssertTrue(p.presses.isEmpty, "\(st.id) \(strat)")
            }
        }
    }

    func testStopDuringTheArmHaltsBeforeThePressWithinMilliseconds() async {
        let p = SpyPresser(), stop = StopSwitch()
        let (r, ev) = await run(livePlan, LiveSpyLocator(), p, stop: stop, armMs: 2000) { e in
            if case .pressArmed = e { Task.detached { try? await Task.sleep(nanoseconds: 80_000_000); stop.press() } }
        }
        let s = try! XCTUnwrap(r.stop)
        XCTAssertEqual(s.phase, .beforePress); XCTAssertEqual(s.step, 3)
        XCTAssertLessThan(s.latencyMs, 50)
        XCTAssertTrue(p.presses.isEmpty)
        XCTAssertFalse(ev.contains { if case .pressed = $0 { return true }; return false }, "the presser was never called")
        XCTAssertTrue(r.summary.contains("STOPPED right before the press in step 3"))
        XCTAssertTrue(ev.last!.logLine.contains("phase=before_press"))
    }

    func testStopInsideThePresserRightBeforeAXPress() async throws {
        let p = SpyPresser(); p.stopInside = true
        let (r, ev) = await run(livePlan, LiveSpyLocator(), p)
        XCTAssertEqual(r.stop?.phase, .beforePress)
        XCTAssertTrue(p.presses.isEmpty); XCTAssertFalse(r.pressed)
        XCTAssertTrue(ev.contains { if case .pressed(3, let x) = $0 { return x.stopped && !x.pressed }; return false })
        // and the real presser checks STOP after the guard and immediately before its single AXPress
        let ps = try src("ForceIQPeak/DesktopPresser.swift")
        let guardAt = try XCTUnwrap(ps.range(of: "PressGuard.refusal("), "the guard runs before the press")
        let stopAt = try XCTUnwrap(ps.range(of: "if stop.isPressed { return PressResult(pressed: false, stopped: true, detail: \"STOP right before the press"),
                                   "STOP is checked right before the press")
        let press = try XCTUnwrap(ps.range(of: "AXUIElementPerformAction("))
        XCTAssertTrue(guardAt.lowerBound < stopAt.lowerBound && stopAt.lowerBound < press.lowerBound)
        XCTAssertNil(ps[stopAt.upperBound..<press.lowerBound].range(of: "await"), "nothing can suspend between the STOP check and the press")
    }

    // ── the flag defaults off and isn't in the UI; live needs every opt-in, never the coach's root ──
    func testLiveNeedsEveryOptInAndTheFlagDefaultsOff() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peak-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(PeakPrefs(stateRoot: dir).desktopActions)                 // default OFF
        let scratch = NSHomeDirectory() + "/ForceIQ/peak-tmp/live-x"
        let live = ["FORCEIQ_PEAK_DESKTOP_LIVE": "1", "GOAT_PEAK_ROOT": scratch]
        XCTAssertEqual(DesktopActionGate.mode(env: live, desktopActions: true, stateRoot: scratch), .live)
        XCTAssertEqual(DesktopActionGate.mode(env: live, desktopActions: true, stateRoot: "~/ForceIQ/peak-tmp/live-x"), .live)
        XCTAssertEqual(DesktopActionGate.mode(env: live, desktopActions: false, stateRoot: scratch), .off)        // flag off
        XCTAssertEqual(DesktopActionGate.mode(env: live), .off)                                                   // flag not read
        XCTAssertEqual(DesktopActionGate.mode(env: ["GOAT_PEAK_ROOT": scratch], desktopActions: true, stateRoot: scratch), .off)  // no env opt-in
        XCTAssertEqual(DesktopActionGate.mode(env: ["FORCEIQ_PEAK_DESKTOP_LIVE": "true", "GOAT_PEAK_ROOT": scratch], desktopActions: true, stateRoot: scratch), .off)
        XCTAssertEqual(DesktopActionGate.mode(env: ["FORCEIQ_PEAK_DESKTOP_LIVE": "1"], desktopActions: true, stateRoot: scratch), .off)  // no scratch root
        for coach in ["~/ForceIQ/peak", NSHomeDirectory() + "/ForceIQ/peak", NSHomeDirectory() + "/ForceIQ/peak/sub", NSHomeDirectory() + "/ForceIQ/peak/"] {
            XCTAssertEqual(DesktopActionGate.mode(env: ["FORCEIQ_PEAK_DESKTOP_LIVE": "1", "GOAT_PEAK_ROOT": coach], desktopActions: true, stateRoot: coach), .off, coach)
        }
        XCTAssertEqual(DesktopActionGate.mode(env: live, desktopActions: true, stateRoot: NSHomeDirectory() + "/ForceIQ/peak"), .off)  // settings from another root
        XCTAssertEqual(DesktopActionGate.mode(env: live, desktopActions: true, stateRoot: nil), .off)
        var both = live; both["FORCEIQ_PEAK_DESKTOP_DRYRUN"] = "1"
        XCTAssertEqual(DesktopActionGate.mode(env: both, desktopActions: true, stateRoot: scratch), .dryRun)        // a dry-run opt-in wins
        // the app decides the mode only from the gate with the scratch root's own settings; nothing in the UI sets it
        let app = try src("ForceIQPeak/AppDelegate.swift")
        XCTAssertTrue(app.contains("desktopMode = DesktopActionGate.mode(env: ProcessInfo.processInfo.environment, desktopActions: prefs.desktopActions, stateRoot: root.path)"))
        XCTAssertEqual(app.components(separatedBy: "desktopMode = ").count - 1, 1)
        XCTAssertFalse(app.contains("prefs.desktopActions ="))
        for f in try FileManager.default.contentsOfDirectory(atPath: Self.sources.appendingPathComponent("ForceIQPeak").path) where f.hasSuffix(".swift") {
            let s = try src("ForceIQPeak/" + f)
            for line in s.split(separator: "\n") where line.contains("Toggle(") { XCTAssertFalse(line.lowercased().contains("desktop"), f) }
            XCTAssertFalse(s.contains("FORCEIQ_PEAK_DESKTOP_LIVE"), "\(f): the live opt-in is an env var only (read by the gate)")
        }
    }

    // ── the press only happens on a matching AXMenuItem (and FLOW's front window is the client's package) ──
    func testPressOnlyOnTheExactCodeWindowMenuItem() async throws {
        let pkg = "/Users/x/ForceIQ/peak-tmp/flow/Tobias Marchetti demo 10.19.2026.flowaipkg"
        let ok = PressCandidate(role: "AXMenuItem", title: "Code Window", enabled: true, pid: 42, bundleID: "com.forceiq.flowai", frontmostPid: 42,
                                matches: 1, documentPath: nil, windowTitle: "Tobias Marchetti demo 10.19.2026")
        func refusal(_ c: PressCandidate) -> String? { PressGuard.refusal(c, flowBundle: "com.forceiq.flowai", packagePath: pkg, client: client) }
        XCTAssertNil(refusal(ok))
        var c = ok; c.documentPath = "file://" + pkg.replacingOccurrences(of: " ", with: "%20") + "/"; c.windowTitle = "FLOW"
        XCTAssertNil(refusal(c), "AXDocument naming the package is enough")
        let bad: [(String, (inout PressCandidate) -> Void)] = [
            ("button", { $0.role = "AXButton" }), ("menu bar item", { $0.role = "AXMenuBarItem" }), ("checkbox", { $0.role = "AXCheckBox" }),
            ("lowercase", { $0.title = "code window" }), ("plural", { $0.title = "Code Windows" }), ("prefix", { $0.title = "Code Window…" }),
            ("padded", { $0.title = " Code Window" }), ("other item", { $0.title = "Code Editor" }), ("disabled", { $0.enabled = false }),
            ("none", { $0.matches = 0 }), ("ambiguous", { $0.matches = 2 }), ("not FLOW", { $0.bundleID = "com.forceiq.command" }),
            ("no bundle", { $0.bundleID = nil }), ("not frontmost", { $0.frontmostPid = 7 }), ("no frontmost", { $0.frontmostPid = nil }),
            ("other package window", { $0.windowTitle = "Avery Lindqvist demo 10.19.2026" }), ("no window", { $0.windowTitle = nil }),
            ("generic title", { $0.windowTitle = "FLOW" }),
            ("other document", { $0.documentPath = "file:///Users/x/Desktop/FLOW/Avery%20Lindqvist.flowaipkg" }),
        ]
        for (name, f) in bad {
            var x = ok; f(&x)
            let why = try XCTUnwrap(refusal(x), "\(name) must be refused")
            XCTAssertTrue(why.hasSuffix("nothing pressed"), why)
        }
        // a too-short package name can't be matched by title alone
        XCTAssertFalse(PressGuard.frontWindowIsPackage(PressCandidate(role: "AXMenuItem", title: "Code Window", enabled: true, pid: 1, bundleID: "b",
                                                                      frontmostPid: 1, windowTitle: "FLOW Tob"), packagePath: "/p/Tob.flowaipkg"))
        // the runner arms a press only for a Code Window located by Accessibility, with the client's package found
        for by in [LocateStrategy.deepLink, .urlScheme, .appIntent, .cua] {
            let loc = LiveSpyLocator(); loc.codeWindowBy = by
            let p = SpyPresser()
            let (r, ev) = await run(livePlan, loc, p)
            XCTAssertTrue(p.presses.isEmpty, "\(by)"); XCTAssertFalse(r.pressed)
            XCTAssertTrue(ev.contains { if case .pressSkipped(3, _) = $0 { return true }; return false })
        }
        let noPkg = LiveSpyLocator(); noPkg.package = nil
        let p = SpyPresser()
        let (_, ev) = await run(livePlan, noPkg, p)
        XCTAssertTrue(p.presses.isEmpty)
        XCTAssertTrue(ev.contains(.pressSkipped(3, "no FLOW package found for Tobias Marchetti; nothing pressed")))
        // the single live call site: one AXUIElementPerformAction in all of Sources, in DesktopPresser.swift, with
        // kAXPressAction on the matched item; no coordinates, events or keystrokes anywhere in that file
        var sites: [String] = []
        for sub in ["PeakCore", "ForceIQPeak"] {
            for f in try FileManager.default.contentsOfDirectory(atPath: Self.sources.appendingPathComponent(sub).path) where f.hasSuffix(".swift") {
                let n = try src(sub + "/" + f).components(separatedBy: "AXUIElementPerformAction(").count - 1
                sites += Array(repeating: sub + "/" + f, count: n)
            }
        }
        XCTAssertEqual(sites, ["ForceIQPeak/DesktopPresser.swift"])
        let ps = try src("ForceIQPeak/DesktopPresser.swift")
        XCTAssertTrue(ps.contains("AXUIElementPerformAction(item, kAXPressAction as CFString)"))
        for bad in ["CGEvent", "CGPost", "CGWarpMouse", "AXUIElementPostKeyboardEvent", "keystroke", "NSAppleScript", "osascript", "IOHID",
                    "kAXPositionAttribute", "CGPoint", "AXUIElementSetAttributeValue", "kAXRaiseAction", "kAXShowMenuAction", "kAXConfirmAction",
                    "Process(", ".open(", "openURL", "write(to"] {
            XCTAssertFalse(ps.contains(bad), "DesktopPresser.swift must not use \(bad)")
        }
        XCTAssertEqual(ps.components(separatedBy: "kAXPressAction").count - 1, 1)
        XCTAssertTrue(ps.contains("MenuItems.find(app, title: PressGuard.title)"))
        XCTAssertEqual(PressGuard.role, "AXMenuItem"); XCTAssertEqual(PressGuard.title, "Code Window")
    }

    // ── the Command meeting start stays locate-only ──
    func testMeetingStartStaysLocateOnlyInLiveMode() async throws {
        let meet = DryRunPlanner.plan(card(meetSaid), live: true)!
        XCTAssertFalse(meet.contains { $0.kind == .codeWindowButton })
        XCTAssertTrue(meet.last!.title.contains("never pressed"))
        let p = SpyPresser()
        let (r, ev) = await run(meet, LiveSpyLocator(), p)
        XCTAssertTrue(p.presses.isEmpty); XCTAssertFalse(r.pressed)
        XCTAssertFalse(ev.contains { if case .pressArmed = $0 { return true }; return false })
        let app = try src("ForceIQPeak/AppDelegate.swift")
        XCTAssertTrue(app.contains("let live = desktopMode == .live && c.action == \"flow_package_code\""))
        XCTAssertTrue(card(meetSaid).message.contains("dry run"), "the meeting card in live mode is a locate-only dry run")
    }

    // ── the client is named everywhere ──
    func testClientNamedOnTheLiveCardStepsPanelTextAndReport() async {
        let c = card(flowSaid)
        XCTAssertTrue(c.label.contains(client) && c.inputs.contains("Client: \(client)"))
        XCTAssertTrue(c.touches.hasPrefix("Live for \(client):") && c.touches.contains("\(client)'s package"))
        XCTAssertTrue(c.message.contains(client)); XCTAssertTrue(c.outputs.allSatisfy { $0.contains(client) })
        for s in livePlan { XCTAssertTrue(s.title.contains(client), s.title) }
        XCTAssertEqual(livePlan[2].title, "Press FLOW's Code Window for \(client)'s package")
        let stop = StopSwitch()
        let (r, ev) = await run(livePlan, LiveSpyLocator(), SpyPresser(), stop: stop, armMs: 500) { e in if case .pressArmed = e { stop.press() } }
        XCTAssertTrue(r.summary.contains("Live run for \(client)") && r.summary.contains("for \(client)'s package"))
        XCTAssertTrue(ev.first!.logLine.contains("client=\(client)"))
        let refusals = [PressGuard.refusal(PressCandidate(role: "AXMenuItem", title: "Code Window", enabled: true, pid: 1, bundleID: "f", frontmostPid: 1,
                                                          windowTitle: "FLOW"), flowBundle: "f", packagePath: "/p/\(client) demo.flowaipkg", client: client),
                        DryRunRunner.pressBlocker(DryRunStepResult(step: livePlan[2], attempts: [], located: nil, note: nil, ms: 0), packagePath: nil, client: client)]
        for w in refusals { XCTAssertTrue(w?.contains(client) == true, w ?? "nil") }
    }
}

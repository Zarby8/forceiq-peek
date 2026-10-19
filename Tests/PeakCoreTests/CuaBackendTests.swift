import Foundation
import XCTest
@testable import PeakCore

// Cua (trycua cua-driver) as the backend of the ONE live desktop action: flag off = no Cua import, spawn or call;
// production FLOW refused; STOP kills an in-flight Cua run (child + its children) within 100 ms; no approval card
// Run tap = no run (voice or a link never approve); and Cua can act only through DesktopPresser's guard path.

final class Box<T>: @unchecked Sendable { private let l = NSLock(); private var v: T; init(_ v: T) { self.v = v }
    var value: T { get { l.withLock { v } } set { l.withLock { v = newValue } } } }

@MainActor final class CuaBackendTests: XCTestCase {
    let uat = "com.forceiq.flowai.uat.run-20261019t101913z-34722"
    let uatPath = "/Users/x/.forceiq/demo/candidate/DerivedData/Build/Products/Release/FLOW.app"
    let pkg = "/Users/x/.forceiq/demo/FLOW-Demo.flowaipkg"
    let path = ["Tools", "Code Window"]
    static let sources = DesktopDryRunTests.sourcesDir
    static let peakDir = sources.deletingLastPathComponent()
    func src(_ f: String) throws -> String { try String(contentsOf: Self.sources.appendingPathComponent(f), encoding: .utf8) }
    func runner() throws -> String { try String(contentsOf: Self.peakDir.appendingPathComponent("cua/peak_cua_runner.py"), encoding: .utf8) }
    func allSources() throws -> [(String, String)] {
        var out: [(String, String)] = []
        for sub in ["PeakCore", "ForceIQPeak"] {
            for f in try FileManager.default.contentsOfDirectory(atPath: Self.sources.appendingPathComponent(sub).path).sorted() where f.hasSuffix(".swift") {
                out.append((sub + "/" + f, try src(sub + "/" + f)))
            }
        }
        return out
    }
    func candidate(pid: Int32 = 92451, bundle: String? = nil) -> PressCandidate {
        PressCandidate(role: "AXMenuItem", title: "Code Window", enabled: true, pid: pid, bundleID: bundle ?? uat, frontmostPid: pid,
                       matches: 1, windowTitle: "", windowTexts: ["FLOW-DEMO"])
    }
    func mint(pid: Int32 = 92451, bundle: String? = nil, path appPath: String? = nil, protected: Set<Int32> = [11311],
              target: FlowSmokeTarget? = nil, menu: [String]? = nil) -> PressAuthorization.Mint {
        PressAuthorization.mint(frontPid: pid, frontBundle: bundle ?? uat, frontPath: appPath ?? uatPath, protectedPids: protected, target: target,
                                candidate: candidate(pid: pid, bundle: bundle), flowBundle: bundle ?? uat, packagePath: pkg, client: "Sample Skater",
                                menuPath: menu ?? path)
    }
    func auth(pid: Int32 = 92451) throws -> PressAuthorization {
        guard case .authorized(let a) = mint(pid: pid, target: FlowSmokeTarget(pid: pid, bundleID: uat)) else { throw XCTSkip("mint refused") }
        return a
    }
    /// A real approval: the card goes up, then a tap on its Run.
    func approved(_ a: PressAuthorization, desk: ApprovalDesk = ApprovalDesk()) async throws -> ApprovalTicket {
        let card = CuaApprovalCard.make(a, app: "FLOW")
        let stop = StopSwitch()
        let wait = Task.detached { await desk.waitForApproval(card, stop: stop, timeoutMs: 3000) }
        for _ in 0..<200 where desk.current == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(desk.approve(cardID: card.id, source: .tap))
        guard case .approved(let t) = await wait.value else { XCTFail("not approved"); throw XCTSkip("no ticket") }
        return t
    }
    func shBackend(_ script: String, _ args: [String] = []) -> CuaBackend {
        let live = ["GOAT_PEAK_ROOT": "~/ForceIQ/peak-tmp/cua-test", "FORCEIQ_PEAK_CUA_LIVE": "1"]
        return CuaBackend.make(env: live, cuaActions: true, mode: .live,
                               config: CuaConfig(executable: "/bin/sh", arguments: ["-c", script, "sh"] + args, environment: ["PATH": "/usr/bin:/bin"]))!
    }
    nonisolated static func alive(_ pid: Int32) -> Bool {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat != SZOMB && info.kp_proc.p_pid == pid
    }

    // ── 1. flag off: no Cua import, spawn or call ──
    func testFlagOffMeansNoCuaImportSpawnOrCall() throws {
        let before = CuaBackend.spawnCount
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peak-cua-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(PeakPrefs(stateRoot: dir).cuaActions, "default OFF")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"cuaActions": "yes"}"#.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        XCTAssertFalse(PeakPrefs(stateRoot: dir).cuaActions, "a wrong type fails closed")
        try #"{"cuaActions": true}"#.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(PeakPrefs(stateRoot: dir).cuaActions)
        let cfg = CuaConfig(executable: "/nonexistent/python", arguments: [], environment: [:])
        let on = ["FORCEIQ_PEAK_CUA_LIVE": "1"]
        for (env, flag, mode) in [(on, true, DesktopActionMode.off), (on, true, .dryRun), (on, false, .live), ([:], true, .live),
                                  (["FORCEIQ_PEAK_CUA_LIVE": "true"], true, .live), (["FORCEIQ_PEAK_CUA_LIVE": "0"], true, .live)] {
            XCTAssertNil(CuaBackend.make(env: env, cuaActions: flag, mode: mode, config: cfg), "\(env) \(flag) \(mode)")
            XCTAssertFalse(CuaGate.enabled(env: env, cuaActions: flag, mode: mode))
        }
        // the three existing gates still decide .live: the coach's own root never gets there, so Cua can't either
        let coach = NSHomeDirectory() + "/ForceIQ/peak"
        let m = DesktopActionGate.mode(env: ["FORCEIQ_PEAK_DESKTOP_LIVE": "1", "GOAT_PEAK_ROOT": coach, "FORCEIQ_PEAK_CUA_LIVE": "1"], desktopActions: true, stateRoot: coach)
        XCTAssertNil(CuaBackend.make(env: on, cuaActions: true, mode: m, config: cfg))
        XCTAssertNotNil(CuaBackend.make(env: on, cuaActions: true, mode: .live, config: cfg), "all gates open: a backend exists")
        XCTAssertEqual(CuaBackend.spawnCount, before, "making (or not making) a backend never spawns anything")
        // the app: one backend, built only from the gate with the scratch root's own settings; the presser asks the wiring
        let app = try src("ForceIQPeak/AppDelegate.swift")
        XCTAssertEqual(app.components(separatedBy: "CuaBackend.make(").count - 1, 1)
        XCTAssertEqual(app.components(separatedBy: "CuaWiring.shared.install(").count - 1, 1)
        XCTAssertTrue(app.contains("CuaBackend.make(env: ProcessInfo.processInfo.environment, cuaActions: prefs.cuaActions, mode: desktopMode,"))
        XCTAssertTrue(app.contains("presser: live ? AXCodeWindowPresser() : nil"), "no presser at all outside live mode")
        let ps = try src("ForceIQPeak/DesktopPresser.swift")
        XCTAssertTrue(ps.contains("if let cua = CuaWiring.shared.backend {"), "no backend (flag off) = the Cua branch is never entered")
        for (f, s) in try allSources() {
            XCTAssertFalse(s.contains("prefs.cuaActions ="), "\(f) sets cuaActions")
            for line in s.split(separator: "\n") where line.contains("Toggle(") { XCTAssertFalse(line.lowercased().contains("cua"), "\(f): no Cua toggle") }
            if f.hasPrefix("ForceIQPeak/") { XCTAssertFalse(s.contains("FORCEIQ_PEAK_CUA_LIVE"), "\(f): the opt-in is an env var read by the gate only") }
        }
        XCTAssertFalse(try src("PeakCore/Prefs.swift").contains("$0.cuaActions = "), "cuaActions has no setter")
        // the child refuses before importing Cua when the flag is off (tests/test_peak_cua_runner.py runs it for real)
        let py = try runner()
        let imp = try XCTUnwrap(py.range(of: "import cua_driver"))
        XCTAssertEqual(py.components(separatedBy: "import cua_driver").count - 1, 1)
        XCTAssertLessThan(try XCTUnwrap(py.range(of: "async def invoke(")).lowerBound, imp.lowerBound, "imported only inside invoke()")
        let main = try XCTUnwrap(py.range(of: "def main("))
        let pre = try XCTUnwrap(py.range(of: "why = precheck(req, env)", range: main.upperBound..<py.endIndex))
        let call = try XCTUnwrap(py.range(of: "asyncio.run(invoke(", range: main.upperBound..<py.endIndex))
        XCTAssertLessThan(pre.lowerBound, call.lowerBound)
        XCTAssertTrue(py.contains("if env.get(FLAG) != \"1\":"))
        XCTAssertEqual(CuaConfig.childEnvironment([:])[CuaGate.env], "0", "the child never sees the flag on unless Peek had it on")
    }

    // ── 2. production FLOW is refused (pid 11311, com.forceiq.flowai, /Applications/FLOW.app); only the isolated UAT FLOW ──
    func testCuaRefusesProductionTargets() throws {
        func refused(_ m: PressAuthorization.Mint) -> String? { if case .refused(let w) = m { return w }; return nil }
        let r11311 = try XCTUnwrap(refused(mint(pid: 11311, protected: [11311])))
        XCTAssertTrue(r11311.contains("11311") && r11311.contains("production FLOW"), r11311)
        XCTAssertNotNil(refused(mint(bundle: "com.forceiq.flowai")))
        XCTAssertNotNil(refused(mint(bundle: "COM.FORCEIQ.FLOWAI")))
        XCTAssertNotNil(refused(mint(path: "/Applications/FLOW.app")))
        XCTAssertNotNil(refused(mint(path: "/Applications/FLOW.app/Contents/MacOS/FLOW")))
        XCTAssertNotNil(refused(mint(target: FlowSmokeTarget(pid: 11311))), "a smoke target naming 11311")
        XCTAssertNotNil(refused(mint(target: FlowSmokeTarget(bundleID: "com.forceiq.flowai"))))
        XCTAssertNotNil(refused(mint(target: FlowSmokeTarget(pid: 92452, bundleID: uat))), "another instance than the target")
        XCTAssertNotNil(refused(mint(menu: ["Code Window"])))
        XCTAssertNotNil(refused(mint(menu: ["Tools", "Code Window", "x"])))
        XCTAssertNotNil(refused(mint(menu: ["Tools", "Code Windows"])))
        guard case .authorized(let a) = mint(target: FlowSmokeTarget(pid: 92451, bundleID: uat)) else { return XCTFail("the isolated UAT FLOW is allowed") }
        XCTAssertEqual(a, PressAuthorization(pid: 92451, bundleID: uat, menuPath: path))
        // the child refuses production again before importing Cua, and once more against the live process
        let py = try runner()
        XCTAssertTrue(py.contains("PROD_BUNDLES = {\"com.forceiq.flowai\"}") && py.contains("PROD_APP = \"/applications/flow.app\""))
        let pre = try XCTUnwrap(py.range(of: "def precheck("))
        let prodPre = try XCTUnwrap(py.range(of: "if is_prod_bundle(bundle):", range: pre.upperBound..<py.endIndex))
        XCTAssertLessThan(prodPre.lowerBound, try XCTUnwrap(py.range(of: "import cua_driver")).lowerBound)
        XCTAssertTrue(py.contains("if pid in prot or is_prod_bundle(app.bundle_id) or is_prod_path(app.launch_path):"))
        // and the presser still refuses production before PressGuard, unchanged (ProductionTargetGuardTests); the Cua
        // path re-reads the frontmost app after the approval card and asks ProductionGuard again
        let ps = try src("ForceIQPeak/DesktopPresser.swift")
        XCTAssertTrue(ps.contains("ProductionGuard.reason(pid: again.pid, bundleID: again.bundle, bundlePath: again.path, protectedPids: protectedNow)"))
    }

    // ── 3. STOP kills an in-flight Cua run, the child and what it started, within 100 ms ──
    func testStopKillsAnInFlightCuaRunWithin100ms() async throws {
        let a = try auth()
        let t = try await approved(a)
        var worst = 0
        for i in 0..<5 {
            let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("cua-stop-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: pidFile) }
            let backend = shBackend("sleep 30 & echo $! > \"$1\"; exec sleep 30", [pidFile])
            let child = Box<Int32>(0)
            backend.onSpawn = { child.value = $0 }
            let stop = StopSwitch()
            let run = Task.detached { await backend.invokeMenu(a, t, stop: stop) }
            var grand: Int32 = 0
            for _ in 0..<1000 {
                if let s = try? String(contentsOfFile: pidFile, encoding: .utf8), let g = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), g > 0 { grand = g; break }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTAssertGreaterThan(grand, 0, "the child started its own child")
            XCTAssertTrue(Self.alive(child.value) && Self.alive(grand), "in flight before STOP")
            let pressed = Date()
            stop.press(at: pressed)
            let out = await run.value
            let wall = Int(Date().timeIntervalSince(pressed) * 1000)
            XCTAssertTrue(out.stopped && !out.ok, out.detail)
            let lat = try XCTUnwrap(out.stopLatencyMs)
            XCTAssertLessThan(lat, 100, "run \(i): STOP → Cua group gone \(lat) ms")
            XCTAssertLessThan(wall, 100, "run \(i): STOP → invokeMenu returned \(wall) ms")
            XCTAssertFalse(Self.alive(child.value), "the Cua child is gone")
            XCTAssertFalse(Self.alive(grand), "what the Cua child started is gone too")
            worst = max(worst, lat, wall)
        }
        print("cua STOP worst latency over 5 runs: \(worst) ms")
        // STOP before the spawn: nothing starts
        let before = CuaBackend.spawnCount, stop = StopSwitch()
        stop.press()
        let out = await shBackend("exit 0").invokeMenu(a, t, stop: stop)
        XCTAssertTrue(out.stopped); XCTAssertEqual(CuaBackend.spawnCount, before)
        // and the presser checks STOP after the approval card, right before handing over to Cua, with nothing in between
        let ps = try src("ForceIQPeak/DesktopPresser.swift")
        let stopAt = try XCTUnwrap(ps.range(of: "if stop.isPressed { return PressResult(pressed: false, stopped: true, detail: \"STOP right before the Cua run"))
        let call = try XCTUnwrap(ps.range(of: ".invokeMenu("))
        XCTAssertLessThan(stopAt.lowerBound, call.lowerBound)
        XCTAssertEqual(ps[stopAt.upperBound..<call.lowerBound].components(separatedBy: "await").count - 1, 1, "only the Cua call itself awaits")
    }

    // ── 4. approval card required: no card, no run; voice- or link-only, no run ──
    func testApprovalCardRequiredBeforeAnyCuaRun() async throws {
        let a = try auth()
        let desk = ApprovalDesk()
        XCTAssertFalse(desk.approve(cardID: "anything", source: .tap), "no card on screen: nothing to approve")
        let card = CuaApprovalCard.make(a, app: "FLOW")
        XCTAssertTrue(card.does.contains("Tools › Code Window") && card.does.contains("Accessibility") && card.does.contains("no typing"), card.does)
        XCTAssertTrue(card.touches.contains("pid 92451") && card.touches.contains(uat) && card.touches.contains("No files"), card.touches)
        let shown = Box<[String]>([])
        desk.onRequest { shown.value.append($0.id) }
        let stop = StopSwitch()
        let wait = Task.detached { await desk.waitForApproval(card, stop: stop, timeoutMs: 400) }
        for _ in 0..<200 where desk.current == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(shown.value, [card.id], "the card is shown before anything can run")
        XCTAssertFalse(desk.approve(cardID: card.id, source: .voice), "voice never approves")
        XCTAssertFalse(desk.approve(cardID: card.id, source: .link), "a link never approves")
        XCTAssertFalse(desk.approve(cardID: "other", source: .tap), "a tap on another card doesn't approve this one")
        let none = await wait.value
        XCTAssertEqual(none, .timedOut, "no Run tap: nothing approved")
        XCTAssertNil(desk.current)
        XCTAssertFalse(desk.approve(cardID: card.id, source: .tap), "a card that is gone can't be approved")
        // STOP or Close while the card is up: nothing approved
        let s2 = StopSwitch()
        let w2 = Task.detached { await desk.waitForApproval(card, stop: s2, timeoutMs: 3000) }
        for _ in 0..<200 where desk.current == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        s2.press()
        let stopped = await w2.value
        XCTAssertEqual(stopped, .stopped)
        let w3 = Task.detached { await desk.waitForApproval(card, stop: StopSwitch(), timeoutMs: 3000) }
        for _ in 0..<200 where desk.current == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        desk.decline(cardID: card.id)
        XCTAssertFalse(desk.approve(cardID: card.id, source: .tap), "closed: Run no longer counts")
        let declined = await w3.value
        XCTAssertEqual(declined, .declined)
        // a ticket only covers the target its card named; another target is refused without spawning anything
        let t = try await approved(a, desk: desk)
        let other = try auth(pid: 92452)
        let before = CuaBackend.spawnCount
        let out = await shBackend("exit 0").invokeMenu(other, t, stop: StopSwitch())
        XCTAssertFalse(out.ok); XCTAssertTrue(out.detail.contains("another target"))
        XCTAssertEqual(CuaBackend.spawnCount, before)
        // in the app: the card's Run (a tap) is the only approval; the presser waits for it before Cua; nothing on the
        // voice or URL paths can approve or reach Cua
        let ps = try src("ForceIQPeak/DesktopPresser.swift")
        let waitAt = try XCTUnwrap(ps.range(of: "CuaWiring.shared.desk.waitForApproval(card, stop: stop"))
        XCTAssertLessThan(waitAt.lowerBound, try XCTUnwrap(ps.range(of: ".invokeMenu(")).lowerBound)
        var approvers: [String] = []
        for (f, s) in try allSources() where s.contains(".approve(cardID:") { approvers.append(f) }
        XCTAssertEqual(approvers, ["ForceIQPeak/DryRunViews.swift"])
        let views = try src("ForceIQPeak/DryRunViews.swift")
        XCTAssertTrue(views.contains("CuaWiring.shared.desk.approve(cardID: c.id, source: .tap)"))
        XCTAssertTrue(views.contains("Button(action: { model.approveCua() })") && views.contains("accessibilityIdentifier(\"peak-cua-run\")"))
        XCTAssertTrue(views.contains("Text(\"What it does: \" + card.does)") && views.contains("Text(\"What it touches: \" + card.touches)"))
        for f in ["ForceIQPeak/Voice.swift", "PeakCore/Voice.swift", "PeakCore/URLRouter.swift", "PeakCore/VoiceCommands.swift"] {
            let s = try src(f)
            XCTAssertFalse(s.contains("CuaWiring") || s.contains("approveCua") || s.contains("invokeMenu"), "\(f) can't reach Cua")
        }
        // a dictated command only makes a card (with the Cua sentence); nothing runs without the card's Run
        let tr = FakeTransport(), store = ThreePOStore(transport: tr)
        var runs = 0
        store.commandContext = { ClientCommandContext(roster: ["Sample Skater"], flowApp: "FLOW", desktopMode: .live, cua: true) }
        store.onCommandRun = { _ in runs += 1; return "ran" }
        await store.sendDictation("open Sample Skater's latest FLOW package and hit the code button")
        let c = try XCTUnwrap(store.transcript.messages.last?.proposals.first)
        XCTAssertTrue(c.touches.contains("Cua makes that press") && c.touches.contains("tap its Run"), c.touches)
        XCTAssertEqual(runs, 0, "voice alone runs nothing")
        XCTAssertFalse(ClientCommandContext(roster: [], desktopMode: .off, cua: true).cua, "Cua text only in live mode")
    }

    // ── 5. choke point: Cua can act only through DesktopPresser's guarded path ──
    func testCuaCanOnlyActThroughDesktopPresser() throws {
        var spawn: [String] = [], invoke: [String] = [], runnerRefs: [String] = [], wiring: [String] = []
        for (f, s) in try allSources() {
            spawn += Array(repeating: f, count: s.components(separatedBy: "posix_spawn(").count - 1)
            invoke += Array(repeating: f, count: s.components(separatedBy: ".invokeMenu(").count - 1)
            if s.contains("peak_cua_runner") || s.contains(".venv-peak-cua") || s.contains("cua_driver") { runnerRefs.append(f) }
            if s.contains("CuaWiring.shared.backend") { wiring.append(f) }
        }
        XCTAssertEqual(spawn, ["PeakCore/DesktopCua.swift"], "the only process launch for Cua")
        XCTAssertEqual(invoke, ["ForceIQPeak/DesktopPresser.swift"], "the only Cua call, once")
        XCTAssertEqual(runnerRefs, ["PeakCore/DesktopCua.swift"])
        XCTAssertEqual(Set(wiring), ["ForceIQPeak/DesktopPresser.swift", "ForceIQPeak/AppDelegate.swift"])
        let app = try src("ForceIQPeak/AppDelegate.swift")
        for line in app.split(separator: "\n") where line.contains("CuaWiring.shared.backend") {
            XCTAssertTrue(line.contains("!= nil") || line.contains("== nil"), "AppDelegate only asks whether Cua is on: \(line)")
        }
        // inside DesktopPresser: same function as the AX press, after its production guard and PressGuard; then mint
        // (every check again), the approval card, a fresh re-check, STOP, and Cua
        let ps = try src("ForceIQPeak/DesktopPresser.swift")
        func at(_ s: String) throws -> String.Index { try XCTUnwrap(ps.range(of: s), s).lowerBound }
        let order = try ["func pressCodeWindow(", "ProductionGuard.reason(pid: front.pid", "PressGuard.refusal(", "if let cua = CuaWiring.shared.backend {",
                         "func pressViaCua(", "switch mint(candidate, front, MenuItems.menuPath(item))", "CuaWiring.shared.desk.waitForApproval(",
                         "ProductionGuard.reason(pid: again.pid", "guard case .authorized(let auth2) = mint(fresh", "STOP right before the Cua run",
                         ".invokeMenu("].map(at)
        XCTAssertEqual(order, order.sorted(), "the Cua path runs strictly after every guard")
        XCTAssertEqual(ps.components(separatedBy: "pressViaCua(").count - 1, 2, "defined once, called once (from pressCodeWindow)")
        let fn = try at("func pressCodeWindow("), call = try at("return await pressViaCua("), axPress = try at("AXUIElementPerformAction(")
        XCTAssertTrue(fn < call && call < axPress, "the Cua branch sits inside pressCodeWindow, before the AX press")
        // the tokens can't be forged: no public initializer (a compile-time fence for the app target)
        let core = try src("PeakCore/DesktopCua.swift")
        for ok in ["    init(pid: Int32, bundleID: String, menuPath: [String]) {", "    init(card: CuaApprovalCard) {", "    init(config: CuaConfig) {"] {
            XCTAssertTrue(core.contains(ok), ok)
            XCTAssertFalse(core.contains("public" + ok.dropFirst(3)), "public " + ok)
        }
        XCTAssertEqual(core.components(separatedBy: "ApprovalTicket(card:").count - 1, 1, "minted only in ApprovalDesk.approve")
        XCTAssertEqual(core.components(separatedBy: "PressAuthorization(pid:").count - 1, 1, "minted only in PressAuthorization.mint")
        XCTAssertEqual(core.components(separatedBy: "CuaBackend(config:").count - 1, 1, "built only in CuaBackend.make")
        // the child calls three cua-driver tools and nothing that clicks, types, scripts or opens
        let py = try runner()
        let calls = Set(py.matches(of: /driver\.([a-z_]+)\(/).map { String($0.output.1) })
        XCTAssertEqual(calls, ["list_apps", "list_windows", "invoke_menu", "shutdown"])
        for bad in ["click", "type_text", "press_key", "hotkey", "drag(", "scroll", "move_cursor", "clipboard", "set_window_frame", "call_tool",
                    "get_desktop_state", "get_window_state", "subprocess", "os.system", "Popen", "open -a", "launch_app", "connect(",
                    "request_mac_os_permissions", "open_mac_os_screen_recording_settings", "screencapture"] {
            XCTAssertFalse(py.contains(bad), "the Cua child must not use \(bad)")
        }
        XCTAssertTrue(py.contains("cd.CuaDriver.create(cd.DriverOptions(claude_code_compatibility=False), embedded=True)"), "embedded, never the daemon")
        // the child's environment carries no secrets and keeps temp files out of /tmp
        let env = CuaConfig.childEnvironment(["ANTHROPIC_API_KEY": "sk-x", "ANTHROPIC_ADMIN_KEY": "sk-y", "GOAT_TOKEN": "t", "TMPDIR": "/tmp/",
                                              "FORCEIQ_PEAK_CUA_LIVE": "1", "FORCEIQ_PEAK_PROTECTED_PIDS": "11311"])
        XCTAssertNil(env["ANTHROPIC_API_KEY"]); XCTAssertNil(env["ANTHROPIC_ADMIN_KEY"]); XCTAssertNil(env["GOAT_TOKEN"])
        XCTAssertFalse(env.values.contains { $0.hasPrefix("sk-") })
        XCTAssertEqual(env["TMPDIR"], NSHomeDirectory() + "/ForceIQ/peak-tmp/cua/")
        XCTAssertEqual(env["FORCEIQ_PEAK_CUA_LIVE"], "1"); XCTAssertEqual(env["FORCEIQ_PEAK_PROTECTED_PIDS"], "11311")
        XCTAssertEqual(env["CUA_DRIVER_EMBEDDED"], "1"); XCTAssertEqual(env["CUA_TELEMETRY_ENABLED"], "false")
        XCTAssertNil(env[CuaConfig.smokeHoldEnv], "no smoke hold unless asked")
        XCTAssertEqual(CuaConfig.childEnvironment([CuaConfig.smokeHoldEnv: "3000"])[CuaConfig.smokeHoldEnv], "3000")
        for bad in ["", "-1", "10001", "1e3", "300 ", "x"] {
            XCTAssertNil(CuaConfig.childEnvironment([CuaConfig.smokeHoldEnv: bad])[CuaConfig.smokeHoldEnv], bad)
        }
        let std = CuaConfig.standard(resources: "/x/ForceIQ Peek.app/Contents/Resources", env: [:])
        XCTAssertEqual(std.executable, NSHomeDirectory() + "/ForceIQ/.venv-peak-cua/bin/python")
        XCTAssertEqual(std.arguments, ["-I", "-B", "/x/ForceIQ Peek.app/Contents/Resources/cua/peak_cua_runner.py"])
    }

    // ── the run summary names the route that pressed ──
    func testSummaryNamesTheCuaRoute() {
        let step = DryRunStep(id: 3, kind: .codeWindowButton, title: "Press FLOW's Code Window", client: "Sample Skater",
                              app: "FLOW", bundleID: "com.forceiq.flowai", strategies: [])
        func report(_ detail: String, pressed: Bool = true) -> DryRunReport {
            DryRunReport(client: "Sample Skater", action: "flow_package_code",
                         results: [DryRunStepResult(step: step, attempts: [], located: nil, note: nil, ms: 1,
                                                    press: PressResult(pressed: pressed, detail: detail, ms: 1))],
                         stop: nil, totalMs: 1, live: true)
        }
        XCTAssertTrue(report("cua pressed FLOW's 'Tools > Code Window' menu item (cua-driver invoke_menu, pid 7)").summary
            .contains("Pressed FLOW's Code Window once (Cua, through Accessibility)"))
        XCTAssertTrue(report("pressed FLOW's 'Code Window' menu item (AXPress, pid 7)").summary.contains("once (AXPress)"))
        XCTAssertFalse(report("cua pressed x", pressed: false).viaCua)
    }

    // ── Cua's log lines carry no client names ──
    func testCuaResultsNeverNameTheClient() throws {
        // the Cua path's own results never name the client: the request carries pid, bundle, menu path and ticket only
        let ps = try src("ForceIQPeak/DesktopPresser.swift")
        let body = String(ps[try XCTUnwrap(ps.range(of: "func pressViaCua(")).lowerBound...])
        XCTAssertFalse(body.contains("\\(step.client"), "no client name in Cua results")
        let core = try src("PeakCore/DesktopCua.swift")
        XCTAssertTrue(core.contains("let req: [String: Any] = [\"op\": \"invoke_menu\", \"pid\": Int(auth.pid), \"bundle_id\": auth.bundleID, \"menu_path\": auth.menuPath,"))
    }
}

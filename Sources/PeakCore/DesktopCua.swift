import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Desktop actions: Cua (trycua, MIT; the cua-driver package) as a second BACKEND for the one live action, never a second
// way to act. Cua runs only from AXCodeWindowPresser.pressCodeWindow (ForceIQPeak/DesktopPresser.swift), after the same
// production guard, smoke-target match and PressGuard as the AX press, after an approval card's Run tap, and after a STOP
// check. Nothing else can start it:
//  - no backend exists unless the gate is open (CuaBackend.make returns nil), so with the flag off nothing imports,
//    spawns or calls Cua;
//  - invokeMenu needs a PressAuthorization (minted only by PressAuthorization.mint, which re-runs every guard) and an
//    ApprovalTicket (minted only by ApprovalDesk.approve for the card on screen, from a tap). Neither has a public init.
// The Cua child is ~/ForceIQ/.venv-peak-cua/bin/python running peak_cua_runner.py (shipped in the app's Resources/cua),
// in its own process group with a minimal environment (no inherited secrets) and TMPDIR under ~/ForceIQ/peak-tmp/cua.
// STOP kills the whole group (SIGKILL) and reaps it; CuaBackendTests measures that under 100 ms.

public enum CuaGate {
    public static let env = "FORCEIQ_PEAK_CUA_LIVE"
    /// Cua only inside the existing three gates (mode .live = scratch GOAT_PEAK_ROOT + settings.json desktopActions=true
    /// from that root + FORCEIQ_PEAK_DESKTOP_LIVE=1), plus settings.json `cuaActions` = true (same root, no UI) plus
    /// FORCEIQ_PEAK_CUA_LIVE=1. Anything else: off (the AX backend, or nothing).
    public static func enabled(env: [String: String], cuaActions: Bool, mode: DesktopActionMode) -> Bool {
        mode == .live && cuaActions && env[Self.env] == "1"
    }
}

/// The checks a press needs, re-run as one pure function. A PressAuthorization exists only when every one passed.
public struct PressAuthorization: Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String
    public let menuPath: [String]
    init(pid: Int32, bundleID: String, menuPath: [String]) { self.pid = pid; self.bundleID = bundleID; self.menuPath = menuPath }

    public enum Mint: Equatable, Sendable { case authorized(PressAuthorization), refused(String) }

    /// Same order as the AX press: smoke target names nothing production → the frontmost app isn't production FLOW →
    /// it is the smoke target (when one is set) → PressGuard (exact AXMenuItem 'Code Window', one match, enabled, FLOW
    /// frontmost, front window is the client's package) → the menu path ends in that exact item.
    public static func mint(frontPid: Int32, frontBundle: String?, frontPath: String?, protectedPids: Set<Int32>,
                            target: FlowSmokeTarget?, candidate: PressCandidate, flowBundle: String, packagePath: String,
                            client: String, menuPath: [String]) -> Mint {
        if let why = target?.refusal(protectedPids: protectedPids) { return .refused("refused: \(why); nothing pressed") }
        if let why = ProductionGuard.reason(pid: frontPid, bundleID: frontBundle, bundlePath: frontPath, protectedPids: protectedPids) {
            return .refused("refused: the frontmost app is \(why); nothing pressed")
        }
        if let t = target, !t.matches(pid: frontPid, bundleID: frontBundle) {
            return .refused("the frontmost FLOW (pid \(frontPid)) isn't the smoke target; nothing pressed")
        }
        if candidate.pid != frontPid { return .refused("the menu item isn't in the frontmost app; nothing pressed") }
        if let why = PressGuard.refusal(candidate, flowBundle: flowBundle, packagePath: packagePath, client: client) { return .refused(why) }
        guard menuPath.count == 2, menuPath.last == PressGuard.title, !(menuPath.first ?? "").isEmpty, let b = frontBundle else {
            return .refused("the '\(PressGuard.title)' menu path couldn't be read exactly; nothing pressed")
        }
        return .authorized(PressAuthorization(pid: frontPid, bundleID: b, menuPath: menuPath))
    }
}

// ── approval card: a plain description of what Cua will do and what it touches, then Run ──

public enum RunSource: String, Sendable { case tap, voice, link }

public struct CuaApprovalCard: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let does: String
    public let touches: String
    public let pid: Int32
    public let bundleID: String
    public let menuPath: [String]
    public static func make(_ a: PressAuthorization, app: String, id: String = UUID().uuidString) -> CuaApprovalCard {
        let path = a.menuPath.joined(separator: " › ")
        return CuaApprovalCard(
            id: id, title: "Cua will press \(app)'s \(path)",
            does: "Cua invokes \(app)'s menu item \(path) once, through macOS Accessibility (the menu item itself: no clicks by position, no typing, no keys).",
            touches: "Only that \(app) process (pid \(a.pid), \(a.bundleID)) and the window it opens. No files, no other app, no database, no network.",
            pid: a.pid, bundleID: a.bundleID, menuPath: a.menuPath)
    }
}

/// Proof that the card on screen got an explicit Run tap. Minted only by ApprovalDesk.approve.
public struct ApprovalTicket: Equatable, Sendable {
    public let cardID: String
    public let pid: Int32
    public let bundleID: String
    public let menuPath: [String]
    init(card: CuaApprovalCard) { cardID = card.id; pid = card.pid; bundleID = card.bundleID; menuPath = card.menuPath }
    public func covers(_ a: PressAuthorization) -> Bool { pid == a.pid && bundleID == a.bundleID && menuPath == a.menuPath }
}

public enum ApprovalOutcome: Equatable, Sendable { case approved(ApprovalTicket), stopped, declined, timedOut }

/// One card at a time. The presser shows a card and waits; only a tap on that card's Run approves it (voice and links
/// never do). STOP, Close or the timeout end the wait with nothing approved.
public final class ApprovalDesk: @unchecked Sendable {
    private let lock = NSLock()
    private var shown: CuaApprovalCard?
    private var ticket: ApprovalTicket?
    private var declined = false
    private var handler: (@Sendable (CuaApprovalCard) -> Void)?
    public init() {}

    /// The UI's hook: called (off the main thread) when a card needs showing.
    public func onRequest(_ f: @escaping @Sendable (CuaApprovalCard) -> Void) { lock.withLock { handler = f } }
    public var current: CuaApprovalCard? { lock.withLock { shown } }

    /// Run on the card. Only a tap, only on the card that is on screen, only once.
    @discardableResult public func approve(cardID: String, source: RunSource) -> Bool {
        lock.withLock {
            guard source == .tap, let c = shown, c.id == cardID, ticket == nil, !declined else { return false }
            ticket = ApprovalTicket(card: c)
            return true
        }
    }
    public func decline(cardID: String) { lock.withLock { if shown?.id == cardID { declined = true } } }

    public func waitForApproval(_ card: CuaApprovalCard, stop: StopSwitch, timeoutMs: Int) async -> ApprovalOutcome {
        let h: (@Sendable (CuaApprovalCard) -> Void)? = lock.withLock { shown = card; ticket = nil; declined = false; return handler }
        h?(card)
        defer { lock.withLock { if shown?.id == card.id { shown = nil } } }
        let deadline = Date().addingTimeInterval(Double(max(0, timeoutMs)) / 1000)
        while true {
            if stop.isPressed { return .stopped }
            let (t, d) = lock.withLock { (ticket, declined) }
            if let t, t.cardID == card.id { return .approved(t) }
            if d { return .declined }
            if Date() >= deadline { return .timedOut }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// ── the Cua child process ──

public struct CuaConfig: Sendable, Equatable {
    public static let venv = "~/ForceIQ/.venv-peak-cua"
    public static let tmp = "~/ForceIQ/peak-tmp/cua"
    public static let runnerName = "peak_cua_runner.py"
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
    }
    static func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

    /// The venv's python running the runner shipped in the app (Resources/cua). A minimal environment: nothing is
    /// inherited except the protected pids, so no key or token reaches the child; TMPDIR is ~/ForceIQ/peak-tmp/cua/;
    /// Cua runs embedded (never the CuaDriver.app daemon), with telemetry off.
    public static func standard(resources: String?, env: [String: String]) -> CuaConfig {
        let runner = env["FORCEIQ_PEAK_CUA_RUNNER"].flatMap { $0.isEmpty ? nil : $0 }
            ?? ((resources ?? "") as NSString).appendingPathComponent("cua/" + runnerName)
        return CuaConfig(executable: expand(venv) + "/bin/python", arguments: ["-I", "-B", runner], environment: childEnvironment(env))
    }

    public static let smokeHoldEnv = "FORCEIQ_PEAK_CUA_SMOKE_HOLD_MS"

    public static func childEnvironment(_ env: [String: String]) -> [String: String] {
        var e: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "TMPDIR": expand(tmp) + "/",
            CuaGate.env: env[CuaGate.env] == "1" ? "1" : "0",
            "CUA_DRIVER_EMBEDDED": "1", "CUA_DRIVER_DISABLE_UNRESTRICTED": "1", "CUA_TELEMETRY_ENABLED": "false", "DO_NOT_TRACK": "1",
            "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1", "LANG": "en_US.UTF-8",
        ]
        if let p = env[ProductionGuard.protectedPidsEnv] { e[ProductionGuard.protectedPidsEnv] = p }
        // smoke only: the child waits this long after its checks so a live STOP lands mid-run (digits, ≤ 10 s)
        if let h = env[smokeHoldEnv], !h.isEmpty, h.count <= 5, h.allSatisfy({ ("0"..."9").contains($0) }), let ms = Int(h), ms <= 10_000 {
            e[smokeHoldEnv] = h
        }
        return e
    }
}

public struct CuaOutcome: Equatable, Sendable {
    public var ok: Bool
    public var stopped: Bool
    public var detail: String
    public var ms: Int
    public var stopLatencyMs: Int?          // STOP pressed → the child's whole process group gone (killed and reaped)
    public var childPid: Int32?
}

public final class CuaBackend: @unchecked Sendable {
    nonisolated(unsafe) private static var spawns = 0
    private static let countLock = NSLock()
    /// How many Cua children were ever started in this process (tests assert it stays 0 with the flag off).
    public static var spawnCount: Int { countLock.withLock { spawns } }

    public let config: CuaConfig
    /// Called right after the child starts (tests use it to press STOP mid-run).
    public var onSpawn: (@Sendable (Int32) -> Void)?
    init(config: CuaConfig) { self.config = config }

    /// nil unless CuaGate is open: with the flag off there is no backend, so nothing can spawn or call Cua.
    public static func make(env: [String: String], cuaActions: Bool, mode: DesktopActionMode, config: CuaConfig) -> CuaBackend? {
        CuaGate.enabled(env: env, cuaActions: cuaActions, mode: mode) ? CuaBackend(config: config) : nil
    }

    /// The one Cua call: invoke `auth.menuPath` in process `auth.pid`, once. Needs the approval ticket for exactly that
    /// target. STOP before the spawn: nothing starts. STOP during the run: the child's process group is killed and reaped.
    public func invokeMenu(_ auth: PressAuthorization, _ ticket: ApprovalTicket, stop: StopSwitch, timeoutMs: Int = 15000) async -> CuaOutcome {
        let t0 = Date()
        func ms(_ d: Date = Date()) -> Int { Int((d.timeIntervalSince(t0) * 1000).rounded()) }
        guard ticket.covers(auth) else {
            return CuaOutcome(ok: false, stopped: false, detail: "the approval card was for another target; nothing pressed", ms: ms())
        }
        if stop.isPressed { return CuaOutcome(ok: false, stopped: true, detail: "STOP before Cua started; nothing pressed", ms: ms()) }
        let req: [String: Any] = ["op": "invoke_menu", "pid": Int(auth.pid), "bundle_id": auth.bundleID, "menu_path": auth.menuPath,
                                  "ticket": ticket.cardID]
        guard let body = try? JSONSerialization.data(withJSONObject: req) else {
            return CuaOutcome(ok: false, stopped: false, detail: "couldn't encode the Cua request; nothing pressed", ms: ms())
        }
        let child: ChildProcess
        do { child = try ChildProcess.spawn(config.executable, config.arguments, env: config.environment, stdin: body + Data("\n".utf8)) } catch {
            return CuaOutcome(ok: false, stopped: false, detail: "Cua didn't start (\(error)); nothing pressed", ms: ms())
        }
        Self.countLock.withLock { Self.spawns += 1 }
        onSpawn?(child.pid)
        let deadline = t0.addingTimeInterval(Double(timeoutMs) / 1000)
        while true {
            if stop.isPressed {
                child.killGroup()
                let gone = child.waitGroupGone(limitMs: 500)
                let lat = stop.pressedAt.map { Int((gone.timeIntervalSince($0) * 1000).rounded()) }
                return CuaOutcome(ok: false, stopped: true, detail: "STOPPED: the Cua run was killed (process group \(child.pid)); nothing more pressed",
                                  ms: ms(), stopLatencyMs: lat.map { max(0, $0) }, childPid: child.pid)
            }
            if let status = child.reapIfExited() {
                child.killGroup()                                    // nothing the child started may outlive it
                let out = child.readOutput()
                return Self.outcome(status: status, stdout: out, ms: ms(), pid: child.pid)
            }
            if Date() >= deadline {
                child.killGroup(); _ = child.waitGroupGone(limitMs: 500)
                return CuaOutcome(ok: false, stopped: false, detail: "Cua timed out after \(timeoutMs) ms and was killed", ms: ms(), childPid: child.pid)
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// The runner prints one JSON line: {"ok": bool, "detail": "...", "effect": "...", "route": "..."}. No names, no titles.
    static func outcome(status: Int32, stdout: String, ms: Int, pid: Int32) -> CuaOutcome {
        let line = stdout.split(separator: "\n").last.map(String.init) ?? ""
        let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        let ok = (obj?["ok"] as? Bool) == true && status == 0
        var detail = (obj?["detail"] as? String) ?? "no result from Cua (exit \(status))"
        if let e = obj?["effect"] as? String { detail += " effect=\(e)" }
        if let r = obj?["route"] as? String { detail += " route=\(r)" }
        return CuaOutcome(ok: ok, stopped: false, detail: detail, ms: ms, childPid: pid)
    }
}

/// Spawns the one Cua child in a new process group (so STOP can kill the child and anything it started), stdin from a pipe,
/// stdout to a pipe, stderr discarded.
final class ChildProcess: @unchecked Sendable {
    struct SpawnError: Error, CustomStringConvertible { let code: Int32; var description: String { "spawn errno \(code)" } }
    let pid: pid_t
    private let outFD: Int32
    private var reaped = false
    private var buffer = Data()
    private init(pid: pid_t, outFD: Int32) { self.pid = pid; self.outFD = outFD }
    deinit { close(outFD) }

    static func spawn(_ exe: String, _ args: [String], env: [String: String], stdin: Data) throws -> ChildProcess {
        var inP: [Int32] = [0, 0], outP: [Int32] = [0, 0]
        guard pipe(&inP) == 0, pipe(&outP) == 0 else { throw SpawnError(code: errno) }
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, inP[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outP[1], 1)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        for fd in [inP[0], inP[1], outP[0], outP[1]] { posix_spawn_file_actions_addclose(&fa, fd) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &fa, &attr, argv, envp)
        close(inP[0]); close(outP[1])
        guard rc == 0 else { close(inP[1]); close(outP[0]); throw SpawnError(code: rc) }
        _ = fcntl(outP[0], F_SETFL, fcntl(outP[0], F_GETFL) | O_NONBLOCK)
        stdin.withUnsafeBytes { p in _ = write(inP[1], p.baseAddress, p.count) }
        close(inP[1])
        return ChildProcess(pid: pid, outFD: outP[0])
    }

    /// Drain stdout without blocking (the runner prints one short line).
    private func drain() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(outFD, &chunk, chunk.count)
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]); if buffer.count > 65536 { buffer = buffer.suffix(65536) } } else { break }
        }
    }
    func reapIfExited() -> Int32? {
        drain()
        guard !reaped else { return 0 }
        var st: Int32 = 0
        let r = waitpid(pid, &st, WNOHANG)
        guard r == pid else { return nil }
        reaped = true
        drain()
        return (st & 0x7f) == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)
    }
    func readOutput() -> String { drain(); return String(decoding: buffer, as: UTF8.self) }
    func killGroup() { _ = kill(-pid, SIGKILL); if !reaped { _ = kill(pid, SIGKILL) } }

    /// Reap the child, then wait (1 ms slices) until no process is left in its group. Returns when that happened.
    func waitGroupGone(limitMs: Int) -> Date {
        let end = Date().addingTimeInterval(Double(limitMs) / 1000)
        if !reaped { var st: Int32 = 0; if waitpid(pid, &st, 0) == pid { reaped = true } }
        while Date() < end {
            if kill(-pid, 0) == -1 && errno == ESRCH { break }
            usleep(1000)
        }
        return Date()
    }
}


/// Process-wide wiring, set once at launch from the gate. `backend` nil = Cua off (the presser uses the AX press).
public final class CuaWiring: @unchecked Sendable {
    public static let shared = CuaWiring()
    private let lock = NSLock()
    private var _backend: CuaBackend?
    private var installed = false
    public let desk = ApprovalDesk()
    public var backend: CuaBackend? { lock.withLock { _backend } }
    /// Once, at launch, with CuaBackend.make's result. Later calls change nothing.
    public func install(_ b: CuaBackend?) { lock.withLock { if !installed { installed = true; _backend = b } } }
}

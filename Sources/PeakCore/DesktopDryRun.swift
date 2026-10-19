import Foundation

// Desktop actions (Cua) STOP dry run. LOCATE AND REPORT ONLY.
//
// The two headline commands ("open <client>'s latest FLOW package and hit the code-window button", "start a meeting with
// <client>") are planned as steps. Each step's target is located the safe way first: a deep link Peak already owns, the
// app's URL scheme, App Intents, then an Accessibility element lookup, and Cua last. Nothing is clicked, typed, opened or
// written in another app. The one effect a dry run may have is bringing FLOW forward (what the card's Run already does).
// A visible STOP aborts at once, between steps or during one; what was stopped is logged.
//
// The locator protocol has no perform / click / key API at all (DesktopDryRunTests scans these sources and fails if one
// becomes reachable). The one live action (pressing FLOW's 'Code Window' menu item) is a separate protocol,
// DesktopPresser (DesktopLive.swift), with its single AXPress call site in ForceIQPeak/DesktopPresser.swift.
// settings.json `desktopActions` stays OFF by default and has no UI toggle.

public enum DesktopActionMode: String, CaseIterable, Sendable { case off, dryRun = "dry_run", live }

public enum DesktopActionGate {
    public static let dryRunEnv = "FORCEIQ_PEAK_DESKTOP_DRYRUN"
    public static let liveEnv = "FORCEIQ_PEAK_DESKTOP_LIVE"

    /// The scratch root from GOAT_PEAK_ROOT (expanded), or nil when unset or the coach's own root (~/ForceIQ/peak or under it).
    public static func scratchRoot(env: [String: String]) -> String? {
        guard let root = env["GOAT_PEAK_ROOT"], !root.isEmpty else { return nil }
        let r = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL.path
        let coach = URL(fileURLWithPath: ("~/ForceIQ/peak" as NSString).expandingTildeInPath).standardizedFileURL.path
        return r.hasPrefix(coach + "/") || r == coach ? nil : r
    }

    /// - dry run: FORCEIQ_PEAK_DESKTOP_DRYRUN=1 and a scratch GOAT_PEAK_ROOT (the settings flag is not an input).
    /// - live: FORCEIQ_PEAK_DESKTOP_LIVE=1 and a scratch GOAT_PEAK_ROOT and settings.json `desktopActions` = true read
    ///   from that same scratch root (`stateRoot`), and no dry-run opt-in (a dry-run opt-in always wins).
    /// - otherwise off. The coach's own root never enables anything.
    public static func mode(env: [String: String], desktopActions: Bool = false, stateRoot: String? = nil) -> DesktopActionMode {
        guard let scratch = scratchRoot(env: env) else { return .off }
        if env[dryRunEnv] == "1" { return .dryRun }
        guard env[liveEnv] == "1", desktopActions, let st = stateRoot,
              URL(fileURLWithPath: (st as NSString).expandingTildeInPath).standardizedFileURL.path == scratch else { return .off }
        return .live
    }
}

/// Safe-first order. Cua is always last and only reached when everything before it failed to locate the target.
public enum LocateStrategy: String, CaseIterable, Sendable {
    case deepLink = "deep_link", urlScheme = "url_scheme", appIntent = "app_intent", accessibility, cua
    public var rank: Int { Self.allCases.firstIndex(of: self)! }
}

public enum DryRunStepKind: String, Sendable {
    case findPackage = "find_package"            // the client's latest .flowaipkg + the app LaunchServices opens it with
    case bringForward = "bring_forward"          // FLOW only: the one permitted effect
    case codeWindowButton = "code_window_button" // FLOW's code-window button
    case commandApp = "command_app"              // Command installed / running, its URL scheme
    case commandRoute = "command_route"          // the CommandLink page (room / schedule) — validated, never opened
    case startControl = "start_control"          // Command's own start / join control (or the sign-in wall)
}

public struct DryRunStep: Equatable, Sendable, Identifiable {
    public var id: Int
    public var kind: DryRunStepKind
    public var title: String                     // names the client
    public var client: String
    public var app: String
    public var bundleID: String
    public var strategies: [LocateStrategy]      // in safe-first order
    public var hints: [String] = []              // AX title / description / identifier hints
    public var blockers: [String] = []           // AX hints that mean "can't get there" (e.g. a sign-in screen)
    public var link: String? = nil               // deep link to validate (never opened)
}

public struct LocateAttempt: Equatable, Sendable {
    public var strategy: LocateStrategy
    public var found: Bool
    public var detail: String
    public var ms: Int
    public var stopped = false
    public var blocked = false
    public var target: String? = nil             // what was located, when a later step needs it (the package path)
    public init(strategy: LocateStrategy, found: Bool, detail: String, ms: Int, stopped: Bool = false, blocked: Bool = false,
                target: String? = nil) {
        self.strategy = strategy; self.found = found; self.detail = detail; self.ms = ms; self.stopped = stopped; self.blocked = blocked
        self.target = target
    }
}

/// The STOP control's switch. Pressing it is instant and sticky; locators poll it between elements.
public final class StopSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var at: Date?
    public init() {}
    public func press(at t: Date = Date()) { lock.lock(); if at == nil { at = t }; lock.unlock() }
    public var isPressed: Bool { lock.lock(); defer { lock.unlock() }; return at != nil }
    public var pressedAt: Date? { lock.lock(); defer { lock.unlock() }; return at }
}

/// Locate ONLY. By design this protocol has no perform, click, key, type, open or write requirement.
public protocol DesktopLocator: Sendable {
    func locate(_ step: DryRunStep, _ strategy: LocateStrategy, stop: StopSwitch) async -> LocateAttempt
    /// Bring FLOW forward (activation only: no input event). Called only for a FLOW .bringForward step.
    func bringForward(_ step: DryRunStep) async -> String
}

public enum StopPhase: String, Sendable {
    case betweenSteps = "between_steps", duringStep = "during_step"
    case beforePress = "before_press"           // live: STOP after the press was armed, before AXPress — nothing pressed
}

public struct StopRecord: Equatable, Sendable {
    public var step: Int                        // the step that did not run (between) or was cut (during)
    public var stepTitle: String
    public var phase: StopPhase
    public var latencyMs: Int                   // STOP pressed → runner halted
    public var skipped: [String]                // titles of steps that never ran
}

public struct DryRunStepResult: Equatable, Sendable {
    public var step: DryRunStep
    public var attempts: [LocateAttempt]
    public var located: LocateAttempt?
    public var note: String?
    public var ms: Int
    public var press: PressResult? = nil         // live only: the Code Window press (or why it didn't happen)
}

public enum DryRunEvent: Equatable, Sendable {
    case started(client: String, steps: Int)
    case stepStarted(Int)
    case attempt(Int, LocateAttempt)
    case broughtForward(Int, String)            // the one effect a dry run has (FLOW only), with what happened
    case pressArmed(Int, Int)                   // live: step, ms until the press (STOP still halts it)
    case pressSkipped(Int, String)              // live: why the press didn't happen (nothing pressed)
    case pressed(Int, PressResult)              // live: the presser's result
    case stepFinished(Int)
    case stopped(StopRecord)
    case finished
}

public struct DryRunReport: Equatable, Sendable {
    public var client: String
    public var action: String
    public var results: [DryRunStepResult]
    public var stop: StopRecord?
    public var totalMs: Int
    public var live = false
    public var pressed: Bool { results.contains { $0.press?.pressed == true } }
    /// The press went through the Cua backend (cua-driver invoke_menu) rather than Peak's own AXPress.
    public var viaCua: Bool { results.contains { $0.press?.pressed == true && $0.press?.detail.hasPrefix("cua pressed") == true } }
    public var summary: String {
        let located = results.filter { $0.located != nil }.count
        let head = live
            ? "Live run for \(client): \(located) of \(results.count) step(s) located. "
                + (pressed ? "Pressed FLOW's Code Window once (\(viaCua ? "Cua, through Accessibility" : "AXPress")); nothing else was clicked, typed or opened."
                           : "Nothing was pressed, clicked, typed or opened.")
            : "Dry run for \(client): \(located) of \(results.count) step(s) located. Nothing was clicked, typed or opened."
        guard let s = stop else { return head }
        let when = s.phase == .betweenSteps ? "before" : (s.phase == .beforePress ? "right before the press in" : "during")
        return head + " STOPPED \(when) step \(s.step) (\(s.stepTitle)) in \(s.latencyMs) ms; skipped: \(s.skipped.isEmpty ? "none" : s.skipped.joined(separator: "; "))."
    }
}

public struct DesktopApps: Sendable {
    public var flowName: String, flowBundle: String, commandName: String, commandBundle: String
    public init(flowName: String = "FLOW", flowBundle: String = "com.forceiq.flowai",
                commandName: String = "Command", commandBundle: String = "com.forceiq.command") {
        self.flowName = flowName; self.flowBundle = flowBundle; self.commandName = commandName; self.commandBundle = commandBundle
    }
}

public enum DryRunPlanner {
    public static let codeHints = ["code window", "code windows", "code-window", "code"]
    public static let startHints = ["start meeting", "start session", "new meeting", "start call", "join"]
    public static let signInHints = ["sign in", "log in", "sign-in", "login"]

    /// Steps for a confirmed command card (client resolved). nil for anything that isn't a client command.
    /// `live` only retitles FLOW's code-window step (it will be pressed after Run); the meeting plan is the same in every
    /// mode and is never pressed.
    public static func plan(_ card: ProposalCard, apps: DesktopApps = DesktopApps(), live: Bool = false) -> [DryRunStep]? {
        guard card.origin == .command, let client = card.client, !client.isEmpty else { return nil }
        switch card.action {
        case "flow_package", "flow_package_code":
            var s = [DryRunStep(id: 1, kind: .findPackage, title: "Find \(client)'s latest FLOW package", client: client,
                                app: apps.flowName, bundleID: apps.flowBundle, strategies: [.urlScheme]),
                     DryRunStep(id: 2, kind: .bringForward, title: "Bring \(apps.flowName) forward for \(client)", client: client,
                                app: apps.flowName, bundleID: apps.flowBundle, strategies: [])]
            if card.action == "flow_package_code" {
                s.append(DryRunStep(id: 3, kind: .codeWindowButton,
                                    title: live ? "Press \(apps.flowName)'s Code Window for \(client)'s package"
                                                : "Locate \(apps.flowName)'s code-window button for \(client)'s package",
                                    client: client, app: apps.flowName, bundleID: apps.flowBundle,
                                    strategies: LocateStrategy.allCases, hints: codeHints))
            }
            return s
        case "start_meeting":
            return [DryRunStep(id: 1, kind: .commandApp, title: "Locate \(apps.commandName) for \(client)'s meeting", client: client,
                               app: apps.commandName, bundleID: apps.commandBundle, strategies: [.urlScheme]),
                    DryRunStep(id: 2, kind: .commandRoute, title: "Check \(apps.commandName)'s page for \(client) (not opened)", client: client,
                               app: apps.commandName, bundleID: apps.commandBundle, strategies: [.deepLink],
                               link: CommandLink.safe(card.link ?? CommandLink.schedule)),
                    DryRunStep(id: 3, kind: .startControl, title: "Locate \(apps.commandName)'s start control for \(client) (never pressed)",
                               client: client, app: apps.commandName, bundleID: apps.commandBundle,
                               strategies: [.deepLink, .appIntent, .accessibility, .cua], hints: startHints, blockers: signInHints)]
        default:
            return nil
        }
    }
}

/// Runs a plan: steps in order, strategies safe-first, stops at the first located target, checks STOP before every
/// step and every strategy, and hands the switch to the locator so a long lookup stops mid-step.
/// Live (a presser is given): after FLOW's code-window step is located by Accessibility and step 1 found the client's
/// package, the press is armed for `armMs` (STOP halts it), STOP is checked again, and only then the presser runs
/// (which checks STOP once more right before AXPress). Nothing else is ever pressed; the meeting plan has no press.
public struct DryRunRunner: Sendable {
    public let steps: [DryRunStep]
    public let locator: any DesktopLocator
    public let presser: (any DesktopPresser)?
    public let stop: StopSwitch
    public let action: String
    public let pace: UInt64                         // ns between strategies (demo pacing so a STOP can land mid-step); 0 = none
    public let arm: UInt64                          // ns between arming the press and pressing (live only)
    public init(steps: [DryRunStep], locator: any DesktopLocator, stop: StopSwitch, action: String, paceMs: Int = 0,
                presser: (any DesktopPresser)? = nil, armMs: Int = 0) {
        self.steps = steps; self.locator = locator; self.stop = stop; self.action = action; self.pace = UInt64(max(0, paceMs)) * 1_000_000
        self.presser = presser; self.arm = UInt64(max(0, armMs)) * 1_000_000
    }
    public var live: Bool { presser != nil }

    static func ms(_ a: Date, _ b: Date = Date()) -> Int { Int((b.timeIntervalSince(a) * 1000).rounded()) }

    public func run(onEvent: @Sendable (DryRunEvent) -> Void = { _ in }) async -> DryRunReport {
        let t0 = Date()
        let client = steps.first?.client ?? ""
        var results: [DryRunStepResult] = []
        onEvent(.started(client: client, steps: steps.count))
        var packagePath: String?
        func report(_ stop: StopRecord?) -> DryRunReport {
            DryRunReport(client: client, action: action, results: results, stop: stop, totalMs: Self.ms(t0), live: live)
        }
        func halt(_ i: Int, _ phase: StopPhase) -> StopRecord {
            let lat = stop.pressedAt.map { Self.ms($0) } ?? 0
            let r = StopRecord(step: steps[i].id, stepTitle: steps[i].title, phase: phase, latencyMs: max(0, lat),
                               skipped: steps[(phase == .betweenSteps ? i : i + 1)...].map(\.title))
            onEvent(.stopped(r))
            return r
        }
        for (i, step) in steps.enumerated() {
            if stop.isPressed {
                return report(halt(i, .betweenSteps))
            }
            onEvent(.stepStarted(step.id))
            let ts = Date()
            var res = DryRunStepResult(step: step, attempts: [], located: nil, note: nil, ms: 0)
            if step.kind == .bringForward {
                let note = await locator.bringForward(step)
                res.note = note
                onEvent(.broughtForward(step.id, note))
            }
            for strat in step.strategies {
                if stop.isPressed { break }
                let a = await locator.locate(step, strat, stop: stop)
                res.attempts.append(a)
                onEvent(.attempt(step.id, a))
                if a.stopped || stop.isPressed { break }
                if a.found || a.blocked { res.located = a.found ? a : nil; break }
                if pace > 0 { await Self.pause(pace, stop) }
            }
            if step.kind == .findPackage, let t = res.located?.target { packagePath = t }
            var armed = false
            if let presser, step.kind == .codeWindowButton, !stop.isPressed {
                if let why = Self.pressBlocker(res, packagePath: packagePath, client: client) {
                    res.note = why
                    onEvent(.pressSkipped(step.id, why))
                } else if let pkg = packagePath {
                    armed = true
                    onEvent(.pressArmed(step.id, Int(arm / 1_000_000)))
                    if arm > 0 { await Self.pause(arm, stop) }
                    if !stop.isPressed {                          // the last check before handing over; the presser checks again
                        let p = await presser.pressCodeWindow(step, packagePath: pkg, stop: stop)
                        res.press = p
                        onEvent(.pressed(step.id, p))
                    }
                }
            }
            res.ms = Self.ms(ts)
            results.append(res)
            if stop.isPressed {
                let phase: StopPhase = armed && res.press?.pressed != true ? .beforePress : .duringStep
                return report(halt(i, phase))
            }
            onEvent(.stepFinished(step.id))
            if pace > 0 { await Self.pause(pace, stop) }
        }
        onEvent(.finished)
        return report(nil)
    }

    /// Why a live press must not be attempted (nil = arm it): FLOW's code-window target has to be located by
    /// Accessibility (the presser re-finds that exact AXMenuItem), and the client's package has to have been found.
    static func pressBlocker(_ res: DryRunStepResult, packagePath: String?, client: String) -> String? {
        guard let hit = res.located else { return "FLOW's Code Window wasn't located for \(client); nothing pressed" }
        guard hit.strategy == .accessibility else { return "located by \(hit.strategy.rawValue), not Accessibility; nothing pressed" }
        guard packagePath != nil else { return "no FLOW package found for \(client); nothing pressed" }
        return nil
    }

    /// Sleep in 5 ms slices so a STOP during the pause is seen within ~5 ms.
    static func pause(_ ns: UInt64, _ stop: StopSwitch) async {
        var left = ns
        while left > 0 && !stop.isPressed {
            let s = min(left, 5_000_000)
            try? await Task.sleep(nanoseconds: s)
            left -= s
        }
    }
}

public extension DryRunEvent {
    /// One log line per event (no client media; client names only, as on the cards).
    var logLine: String {
        switch self {
        case .started(let c, let n): return "dryrun start client=\(c) steps=\(n)"
        case .stepStarted(let i): return "dryrun step=\(i) start"
        case .attempt(let i, let a): return "dryrun step=\(i) try=\(a.strategy.rawValue) found=\(a.found ? 1 : 0)\(a.blocked ? " blocked=1" : "")\(a.stopped ? " stopped=1" : "") ms=\(a.ms) detail=\(a.detail)"
        case .broughtForward(let i, let n): return "dryrun step=\(i) forward detail=\(n)"
        case .pressArmed(let i, let ms): return "live step=\(i) press armed in_ms=\(ms)"
        case .pressSkipped(let i, let why): return "live step=\(i) press skipped detail=\(why)"
        case .pressed(let i, let p): return "live step=\(i) press pressed=\(p.pressed ? 1 : 0)\(p.stopped ? " stopped=1" : "") ms=\(p.ms) detail=\(p.detail)"
        case .stepFinished(let i): return "dryrun step=\(i) done"
        case .stopped(let r): return "dryrun STOPPED phase=\(r.phase.rawValue) step=\(r.step) latency_ms=\(r.latencyMs) skipped=\(r.skipped.count) [\(r.skipped.joined(separator: " | "))]"
        case .finished: return "dryrun finished"
        }
    }
}

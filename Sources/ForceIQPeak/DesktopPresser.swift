import AppKit
import ApplicationServices
import PeakCore

// The ONE live desktop action: AXPress on FLOW's 'Code Window' menu item, in the frontmost FLOW process, after an
// explicit Run tap. The element is matched by role AXMenuItem and title exactly 'Code Window'; PressGuard must allow it
// (FLOW frontmost, exactly one match, enabled, FLOW's front window is the client's package). STOP is checked right
// before the press. No coordinate clicks, no synthetic typing, no posted events: DesktopDryRunTests pins this file to a
// single AXUIElementPerformAction call (the AXPress action), inside pressCodeWindow, after the guard and the STOP check.
// Production FLOW is never pressed: ProductionGuard refuses the bundle id com.forceiq.flowai, /Applications/FLOW.app, every
// running production-bundle pid and FORCEIQ_PEAK_PROTECTED_PIDS; with a smoke target (FORCEIQ_PEAK_FLOW_TARGET_PID /
// _BUNDLE) the frontmost process must be exactly that isolated FLOW instance.
// Cua backend (CuaGate: the live gates + settings.json cuaActions + the Cua env opt-in, CuaGate.env): the SAME function and the
// SAME guard path up to PressGuard; then, instead of the AX press, PressAuthorization.mint re-runs every check, an
// approval card (what Cua will do, what it touches) waits for its Run tap, the target is re-checked, STOP is checked,
// and CuaBackend.invokeMenu runs Cua once. This is the only place Cua is ever called (CuaBackendTests pins it).

struct AXCodeWindowPresser: DesktopPresser {
    func pressCodeWindow(_ step: DryRunStep, packagePath: String, stop: StopSwitch) async -> PressResult {
        let t0 = Date()
        func ms() -> Int { Int((Date().timeIntervalSince(t0) * 1000).rounded()) }
        if stop.isPressed { return PressResult(pressed: false, stopped: true, detail: "STOP before the press; nothing pressed", ms: ms()) }
        guard step.kind == .codeWindowButton else { return PressResult(pressed: false, detail: "not FLOW's code-window step; nothing pressed", ms: ms()) }
        guard AXIsProcessTrusted() else { return PressResult(pressed: false, detail: "Peek has no Accessibility permission; nothing pressed", ms: ms()) }
        let front = await MainActor.run { () -> (pid: pid_t, bundle: String?, path: String?)? in
            NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, $0.bundleIdentifier, $0.bundleURL?.path) }
        }
        let env = ProcessInfo.processInfo.environment
        let protected = await MainActor.run { ProductionPids.running() }.union(ProductionGuard.protectedPids(env: env))
        let target = FlowSmokeTarget.from(env: env)
        if let why = target?.refusal(protectedPids: protected) {
            return PressResult(pressed: false, detail: "refused: \(why); nothing pressed", ms: ms())
        }
        if let front, let why = ProductionGuard.reason(pid: front.pid, bundleID: front.bundle, bundlePath: front.path, protectedPids: protected) {
            return PressResult(pressed: false, detail: "refused: the frontmost app is \(why); nothing pressed", ms: ms())
        }
        guard let front, front.bundle == step.bundleID else {
            return PressResult(pressed: false, detail: "FLOW is not the frontmost app; nothing pressed", ms: ms())
        }
        if let target, !target.matches(pid: front.pid, bundleID: front.bundle) {
            return PressResult(pressed: false, detail: "the frontmost FLOW (pid \(front.pid)) isn't the smoke target; nothing pressed", ms: ms())
        }
        let app = AXUIElementCreateApplication(front.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let items = MenuItems.find(app, title: PressGuard.title)
        let win = MenuItems.element(app, kAXFocusedWindowAttribute) ?? MenuItems.element(app, kAXMainWindowAttribute)
        let first = items.first
        let candidate = PressCandidate(
            role: first.flatMap { MenuItems.string($0, kAXRoleAttribute) } ?? "",
            title: first.flatMap { MenuItems.string($0, kAXTitleAttribute) } ?? "",
            enabled: first.flatMap { MenuItems.bool($0, kAXEnabledAttribute) } ?? false,
            pid: front.pid, bundleID: front.bundle, frontmostPid: front.pid, matches: items.count,
            documentPath: win.flatMap { MenuItems.string($0, kAXDocumentAttribute) },
            windowTitle: win.flatMap { MenuItems.string($0, kAXTitleAttribute) },
            windowTexts: win.map { w in (MenuItems.string(w, kAXTitleAttribute) ?? "").isEmpty ? MenuItems.staticTexts(w) : [] } ?? [])
        if let why = PressGuard.refusal(candidate, flowBundle: step.bundleID, packagePath: packagePath, client: step.client) {
            return PressResult(pressed: false, detail: why, ms: ms())
        }
        guard let item = first else { return PressResult(pressed: false, detail: "no target; nothing pressed", ms: ms()) }
        if let cua = CuaWiring.shared.backend {
            return await pressViaCua(cua, item: item, candidate: candidate, front: (front.pid, front.bundle, front.path), protected: protected,
                                     target: target, step: step, packagePath: packagePath, stop: stop, t0: t0)
        }
        if stop.isPressed { return PressResult(pressed: false, stopped: true, detail: "STOP right before the press; nothing pressed", ms: ms()) }
        let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
        let pkg = URL(fileURLWithPath: packagePath).lastPathComponent
        return err == .success
            ? PressResult(pressed: true, detail: "pressed FLOW's 'Code Window' menu item (AXPress, pid \(front.pid)) for \(pkg)", ms: ms())
            : PressResult(pressed: false, detail: "AXPress failed (AXError \(err.rawValue)); nothing else tried", ms: ms())
    }
}

extension AXCodeWindowPresser {
    static var approvalTimeoutMs: Int { Int(ProcessInfo.processInfo.environment["FORCEIQ_PEAK_CUA_APPROVAL_MS"] ?? "") ?? 120_000 }

    /// Cua backend, reached only from pressCodeWindow after its production guard, smoke-target match and PressGuard.
    func pressViaCua(_ cua: CuaBackend, item: AXUIElement, candidate: PressCandidate, front: (pid: pid_t, bundle: String?, path: String?),
                     protected: Set<Int32>, target: FlowSmokeTarget?, step: DryRunStep, packagePath: String, stop: StopSwitch, t0: Date) async -> PressResult {
        func ms() -> Int { Int((Date().timeIntervalSince(t0) * 1000).rounded()) }
        func mint(_ c: PressCandidate, _ f: (pid: pid_t, bundle: String?, path: String?), _ path: [String]) -> PressAuthorization.Mint {
            PressAuthorization.mint(frontPid: f.pid, frontBundle: f.bundle, frontPath: f.path, protectedPids: protected, target: target,
                                    candidate: c, flowBundle: step.bundleID, packagePath: packagePath, client: step.client, menuPath: path)
        }
        let auth: PressAuthorization
        switch mint(candidate, front, MenuItems.menuPath(item)) {
        case .refused(let why): return PressResult(pressed: false, detail: "cua: " + why, ms: ms())
        case .authorized(let a): auth = a
        }
        let card = CuaApprovalCard.make(auth, app: step.app)
        let ticket: ApprovalTicket
        switch await CuaWiring.shared.desk.waitForApproval(card, stop: stop, timeoutMs: Self.approvalTimeoutMs) {
        case .stopped: return PressResult(pressed: false, stopped: true, detail: "STOP while the Cua approval card was up; nothing pressed", ms: ms())
        case .declined: return PressResult(pressed: false, detail: "cua: the approval card was closed without Run; nothing pressed", ms: ms())
        case .timedOut: return PressResult(pressed: false, detail: "cua: no Run on the approval card; nothing pressed", ms: ms())
        case .approved(let t): ticket = t
        }
        // the card was up for a while: read the target again and re-run every check before Cua starts
        let again = await MainActor.run { () -> (pid: pid_t, bundle: String?, path: String?)? in
            NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, $0.bundleIdentifier, $0.bundleURL?.path) }
        }
        guard let again, again.pid == auth.pid else { return PressResult(pressed: false, detail: "cua: FLOW is no longer the frontmost app; nothing pressed", ms: ms()) }
        let protectedNow = await MainActor.run { ProductionPids.running() }.union(protected)
        if let why = ProductionGuard.reason(pid: again.pid, bundleID: again.bundle, bundlePath: again.path, protectedPids: protectedNow) {
            return PressResult(pressed: false, detail: "cua: refused: the frontmost app is \(why); nothing pressed", ms: ms())
        }
        let app = AXUIElementCreateApplication(again.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let items = MenuItems.find(app, title: PressGuard.title)
        let win = MenuItems.element(app, kAXFocusedWindowAttribute) ?? MenuItems.element(app, kAXMainWindowAttribute)
        let fresh = PressCandidate(
            role: items.first.flatMap { MenuItems.string($0, kAXRoleAttribute) } ?? "",
            title: items.first.flatMap { MenuItems.string($0, kAXTitleAttribute) } ?? "",
            enabled: items.first.flatMap { MenuItems.bool($0, kAXEnabledAttribute) } ?? false,
            pid: again.pid, bundleID: again.bundle, frontmostPid: again.pid, matches: items.count,
            documentPath: win.flatMap { MenuItems.string($0, kAXDocumentAttribute) },
            windowTitle: win.flatMap { MenuItems.string($0, kAXTitleAttribute) },
            windowTexts: win.map { w in (MenuItems.string(w, kAXTitleAttribute) ?? "").isEmpty ? MenuItems.staticTexts(w) : [] } ?? [])
        guard case .authorized(let auth2) = mint(fresh, again, items.first.map { MenuItems.menuPath($0) } ?? []), auth2 == auth, ticket.covers(auth2) else {
            return PressResult(pressed: false, detail: "cua: the target changed while the approval card was up; nothing pressed", ms: ms())
        }
        if stop.isPressed { return PressResult(pressed: false, stopped: true, detail: "STOP right before the Cua run; nothing pressed", ms: ms()) }
        let out = await cua.invokeMenu(auth2, ticket, stop: stop)
        let path = auth2.menuPath.joined(separator: " > ")
        if out.stopped {
            return PressResult(pressed: false, stopped: true, detail: "cua STOPPED mid-run stop_latency_ms=\(out.stopLatencyMs ?? -1); \(out.detail)", ms: ms())
        }
        return out.ok
            ? PressResult(pressed: true, detail: "cua pressed FLOW's '\(path)' menu item (cua-driver invoke_menu, pid \(auth2.pid)) cua_ms=\(out.ms) \(out.detail)", ms: ms())
            : PressResult(pressed: false, detail: "cua: not pressed (\(out.detail))", ms: ms())
    }
}

/// Read-only menu-bar walk: every menu-bar element (any role) whose title is exactly `title`, so PressGuard can refuse a
/// non-AXMenuItem or an ambiguous match.
enum MenuItems {
    static func find(_ app: AXUIElement, title: String) -> [AXUIElement] {
        guard let bar = element(app, kAXMenuBarAttribute) else { return [] }
        var out: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(bar, 0)]
        var head = 0
        while head < queue.count && head < 4000 {
            let (el, depth) = queue[head]; head += 1
            if depth > 0, string(el, kAXTitleAttribute) == title { out.append(el) }
            if depth < 6 { queue += children(el).map { ($0, depth + 1) } }
        }
        return out
    }
    /// Short AXStaticText values in one window (bounded, read-only): how a title-less FLOW window shows its package.
    static func staticTexts(_ win: AXUIElement, budget: Int = 3000) -> [String] {
        var out: [String] = []
        var queue: [(AXUIElement, Int)] = [(win, 0)]
        var head = 0
        while head < queue.count && head < budget && out.count < 200 {
            let (el, depth) = queue[head]; head += 1
            if string(el, kAXRoleAttribute) == "AXStaticText" {
                for a in [kAXValueAttribute, kAXTitleAttribute] { if let s = string(el, a), !s.isEmpty, s.count <= 120 { out.append(s) } }
            }
            if depth < 14 { queue += children(el).map { ($0, depth + 1) } }
        }
        return out
    }
    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }
    static func string(_ el: AXUIElement, _ attr: String) -> String? { copy(el, attr) as? String }
    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? { (copy(el, attr) as? NSNumber)?.boolValue }
    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func children(_ el: AXUIElement) -> [AXUIElement] { (copy(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    /// The titled menu path from the menu bar down to this item (read-only parent walk), e.g. ["Tools", "Code Window"].
    static func menuPath(_ item: AXUIElement) -> [String] {
        var path: [String] = []
        var el: AXUIElement? = item
        var hops = 0
        while let e = el, hops < 12 {
            if string(e, kAXRoleAttribute) == "AXMenuBar" { break }
            if let t = string(e, kAXTitleAttribute), !t.isEmpty, string(e, kAXRoleAttribute) != "AXMenu" { path.insert(t, at: 0) }
            el = element(e, kAXParentAttribute); hops += 1
        }
        return path
    }
}

/// Pids of every running production FLOW (by bundle id). Read-only.
enum ProductionPids {
    @MainActor static func running() -> Set<Int32> {
        Set(ProductionGuard.productionBundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.map(\.processIdentifier))
    }
}

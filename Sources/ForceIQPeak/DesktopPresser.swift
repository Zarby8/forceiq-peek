import AppKit
import ApplicationServices
import PeakCore

// The ONE live desktop action: AXPress on FLOW's 'Code Window' menu item, in the frontmost FLOW process, after an
// explicit Run tap. The element is matched by role AXMenuItem and title exactly 'Code Window'; PressGuard must allow it
// (FLOW frontmost, exactly one match, enabled, FLOW's front window is the client's package). STOP is checked right
// before the press. No coordinate clicks, no synthetic typing, no posted events: DesktopDryRunTests pins this file to a
// single AXUIElementPerformAction call (the AXPress action), inside pressCodeWindow, after the guard and the STOP check.

struct AXCodeWindowPresser: DesktopPresser {
    func pressCodeWindow(_ step: DryRunStep, packagePath: String, stop: StopSwitch) async -> PressResult {
        let t0 = Date()
        func ms() -> Int { Int((Date().timeIntervalSince(t0) * 1000).rounded()) }
        if stop.isPressed { return PressResult(pressed: false, stopped: true, detail: "STOP before the press; nothing pressed", ms: ms()) }
        guard step.kind == .codeWindowButton else { return PressResult(pressed: false, detail: "not FLOW's code-window step; nothing pressed", ms: ms()) }
        guard AXIsProcessTrusted() else { return PressResult(pressed: false, detail: "Peak has no Accessibility permission; nothing pressed", ms: ms()) }
        let front = await MainActor.run { () -> (pid: pid_t, bundle: String?)? in
            NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, $0.bundleIdentifier) }
        }
        guard let front, front.bundle == step.bundleID else {
            return PressResult(pressed: false, detail: "FLOW is not the frontmost app; nothing pressed", ms: ms())
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
            windowTitle: win.flatMap { MenuItems.string($0, kAXTitleAttribute) })
        if let why = PressGuard.refusal(candidate, flowBundle: step.bundleID, packagePath: packagePath, client: step.client) {
            return PressResult(pressed: false, detail: why, ms: ms())
        }
        guard let item = first else { return PressResult(pressed: false, detail: "no target; nothing pressed", ms: ms()) }
        if stop.isPressed { return PressResult(pressed: false, stopped: true, detail: "STOP right before the press; nothing pressed", ms: ms()) }
        let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
        let pkg = URL(fileURLWithPath: packagePath).lastPathComponent
        return err == .success
            ? PressResult(pressed: true, detail: "pressed FLOW's 'Code Window' menu item (AXPress, pid \(front.pid)) for \(pkg)", ms: ms())
            : PressResult(pressed: false, detail: "AXPress failed (AXError \(err.rawValue)); nothing else tried", ms: ms())
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
}

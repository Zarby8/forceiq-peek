import AppKit
import ApplicationServices
import PeakCore

// The dry run's locator: LOCATE AND REPORT ONLY. Reads Launch Services, app bundles (Info.plist, App Intents metadata),
// the package folder listing, and Accessibility attributes (copy-only). It has no way to press, type, open or write:
// DesktopDryRunTests scans this file and fails if any such API shows up. The single effect is bringForward() for FLOW.

struct AXDesktopLocator: DesktopLocator {
    var packageRoots: [URL] = Self.defaultPackageRoots()
    var axBudget = 8000                // elements per lookup
    var axDeadline: TimeInterval = 4   // seconds per lookup
    /// Live mode: production FLOW (ProductionGuard) is never brought forward. Always on with a smoke target.
    var refuseProduction = false

    func locate(_ step: DryRunStep, _ strategy: LocateStrategy, stop: StopSwitch) async -> LocateAttempt {
        let t0 = Date()
        func done(_ found: Bool, _ detail: String, stopped: Bool = false, blocked: Bool = false) -> LocateAttempt {
            LocateAttempt(strategy: strategy, found: found, detail: detail, ms: Int((Date().timeIntervalSince(t0) * 1000).rounded()),
                          stopped: stopped, blocked: blocked)
        }
        if stop.isPressed { return done(false, "stopped before lookup", stopped: true) }
        let info = await MainActor.run { AppInfo.lookup(step.bundleID) }
        switch strategy {
        case .deepLink:
            switch step.kind {
            case .commandRoute:
                guard let l = step.link, CommandLink.safe(l) == l, let u = URL(string: l) else { return done(false, "link failed CommandLink validation") }
                let handler = await MainActor.run { NSWorkspace.shared.urlForApplication(toOpen: u)?.lastPathComponent }
                let page = l == CommandLink.schedule ? "schedule" : (l.contains("%2Fsessions") ? "room page" : "client page")
                return handler.map { done(true, "\(page) link validated; handled by \($0); not opened") } ?? done(false, "no app handles forceiq-command://")
            case .startControl:
                return done(false, "no start link: Command links open pages only and Peak never sends workflow=")
            default:
                return done(false, "Peak owns no deep link for this target")
            }
        case .urlScheme:
            switch step.kind {
            case .findPackage:
                return await findPackage(step, stop: stop, done)
            case .commandApp:
                guard let i = info else { return done(false, "\(step.app) is not installed") }
                return done(true, "\(i.name) installed; schemes \(i.schemes.isEmpty ? "none" : i.schemes.map { $0 + "://" }.joined(separator: ", ")); "
                            + (i.pid.map { "running (pid \($0))" } ?? "not running"))
            default:
                guard let i = info else { return done(false, "\(step.app) is not installed") }
                return done(false, i.schemes.isEmpty ? "\(i.name) registers no URL scheme" : "\(i.name) schemes \(i.schemes.joined(separator: ", ")) have no action for this target")
            }
        case .appIntent:
            guard let i = info else { return done(false, "\(step.app) is not installed") }
            let meta = i.url.appendingPathComponent("Contents/Resources/Metadata.appintents/extract.actionsdata")
            guard let d = try? Data(contentsOf: meta), let s = String(data: d, encoding: .utf8) else { return done(false, "\(i.name) ships no App Intents") }
            let hit = step.hints.first { s.lowercased().contains($0) }
            return hit.map { done(true, "App Intent mentioning '\($0)' in \(i.name) (not invoked)") } ?? done(false, "\(i.name) App Intents have nothing for this target")
        case .accessibility:
            guard let i = info else { return done(false, "\(step.app) is not installed") }
            guard let pid = i.pid else { return done(false, "\(i.name) is not running; a dry run never launches it") }
            guard AXIsProcessTrusted() else { return done(false, "Peak has no Accessibility permission here; not requested") }
            let r = AXSearch(pid: pid, hints: step.hints, blockers: step.blockers, budget: axBudget, deadline: axDeadline).run(stop: stop)
            if r.stopped { return done(false, "stopped mid-lookup after \(r.visited) element(s)", stopped: true) }
            if let f = r.found { return done(true, "\(f) (\(r.visited) element(s) read; never pressed)") }
            if let b = r.blocker { return done(false, "blocked: \(b) (\(r.visited) element(s) read; not signed in, nothing entered)", blocked: true) }
            return done(false, "no element matching \(step.hints.map { "'\($0)'" }.joined(separator: "/")) in \(r.visited) element(s)\(r.timedOut ? " (time budget hit)" : "")")
        case .cua:
            return done(false, "Cua is last and not wired into Peak; reported only")
        }
    }

    func bringForward(_ step: DryRunStep) async -> String {
        guard step.kind == .bringForward, step.bundleID == DesktopApps().flowBundle || step.app.lowercased() == "flow" else {
            return "not FLOW: nothing brought forward"
        }
        let env = ProcessInfo.processInfo.environment
        let target = FlowSmokeTarget.from(env: env)
        let refuseProduction = self.refuseProduction || target != nil
        return await MainActor.run {
            let protected = ProductionPids.running().union(ProductionGuard.protectedPids(env: env))
            if refuseProduction, let why = target?.refusal(protectedPids: protected) { return "\(step.app) not brought forward: \(why)" }
            // with a smoke target, exactly that instance (by pid, else its bundle id); otherwise the profile's FLOW
            let found: NSRunningApplication?
            if let t = target {
                found = t.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
                    ?? (t.pid == nil ? t.bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first } : nil)
            } else {
                found = NSRunningApplication.runningApplications(withBundleIdentifier: step.bundleID).first
            }
            guard let app = found else { return "\(step.app) is not running; a dry run never launches it" }
            if refuseProduction {
                if let why = ProductionGuard.reason(pid: app.processIdentifier, bundleID: app.bundleIdentifier, bundlePath: app.bundleURL?.path,
                                                    protectedPids: protected) {
                    return "\(step.app) not brought forward: \(why)"
                }
                if let t = target, !t.matches(pid: app.processIdentifier, bundleID: app.bundleIdentifier) {
                    return "\(step.app) not brought forward: pid \(app.processIdentifier) isn't the smoke target"
                }
            }
            return app.activate() ? "\(step.app) brought forward (pid \(app.processIdentifier))" : "\(step.app) did not come forward"
        }
    }

    private func findPackage(_ step: DryRunStep, stop: StopSwitch, _ done: (Bool, String, Bool, Bool) -> LocateAttempt) async -> LocateAttempt {
        let scan = Self.scanPackages(packageRoots, client: step.client, stop: stop)
        if scan.stopped { return done(false, "stopped mid-scan after \(scan.scanned) package(s)", true, false) }
        guard let (pkg, when) = scan.best else {
            return done(false, "no package for \(step.client) under \(packageRoots.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: ", ")) (\(scan.scanned) package(s) scanned)", false, false)
        }
        let opener = await MainActor.run { NSWorkspace.shared.urlForApplication(toOpen: pkg)?.lastPathComponent }
        let f = DateFormatter(); f.dateFormat = "MMM d h:mm a"
        var a = done(true, "\(pkg.lastPathComponent) (modified \(f.string(from: when))) opens with \(opener ?? "no app"); not opened", false, false)
        a.target = pkg.path
        return a
    }

    /// ~/Desktop/FLOW, or FORCEIQ_PEAK_FLOW_PACKAGES (a scratch folder for demo proofs, e.g. under ~/ForceIQ/peak-tmp).
    static func defaultPackageRoots(env: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        if let p = env["FORCEIQ_PEAK_FLOW_PACKAGES"], !p.isEmpty { return [URL(fileURLWithPath: (p as NSString).expandingTildeInPath)] }
        return [URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/FLOW")]
    }

    /// The client's newest .flowaipkg (name contains the client's last name, or all name words). Listing only.
    static func scanPackages(_ roots: [URL], client: String, stop: StopSwitch) -> (best: (URL, Date)?, scanned: Int, stopped: Bool) {
        let toks = client.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
        var scanned = 0
        var best: (URL, Date)?
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let u = e.nextObject() as? URL {
                if stop.isPressed { return (best, scanned, true) }
                if e.level > 3 { e.skipDescendants(); continue }
                guard u.pathExtension.lowercased() == "flowaipkg" else { continue }
                scanned += 1
                let name = u.deletingPathExtension().lastPathComponent.lowercased()
                guard let last = toks.last, name.contains(last) || toks.allSatisfy({ name.contains($0) }) else { continue }
                let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if best == nil || m > best!.1 { best = (u, m) }
            }
        }
        return (best, scanned, false)
    }
}

/// Bundle facts for one app: name, URL, URL schemes, running pid. Read-only.
struct AppInfo {
    var name: String, url: URL, schemes: [String], pid: pid_t?
    @MainActor static func lookup(_ bundleID: String) -> AppInfo? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        // an isolated FLOW test build may not be registered with Launch Services: fall back to the running copy's bundle
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) ?? running?.bundleURL else { return nil }
        let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let schemes = ((plist["CFBundleURLTypes"] as? [[String: Any]]) ?? []).flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        let pid = running?.processIdentifier
        return AppInfo(name: url.deletingPathExtension().lastPathComponent, url: url, schemes: schemes, pid: pid)
    }
}

/// Breadth-first, copy-only walk of one app's Accessibility tree (windows, then the menu bar). Checks STOP at every
/// element. Matches buttons / menu items / links by title, description, identifier or help against the hints (earlier
/// hints rank higher); blockers (e.g. a sign-in screen) are reported when no target is found.
struct AXSearch {
    let pid: pid_t, hints: [String], blockers: [String], budget: Int, deadline: TimeInterval
    struct Result { var found: String?; var blocker: String?; var visited = 0; var stopped = false; var timedOut = false }
    static let targetRoles: Set<String> = ["AXButton", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXLink", "AXMenuBarItem"]

    func run(stop: StopSwitch) -> Result {
        var r = Result()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var queue: [(AXUIElement, Int)] = (elements(app, kAXWindowsAttribute) + elements(app, kAXMenuBarAttribute)).map { ($0, 0) }
        let t0 = Date()
        var bestRank = Int.max, bestText: String?
        var head = 0
        while head < queue.count {
            if stop.isPressed { r.stopped = true; return r }
            if r.visited >= budget || Date().timeIntervalSince(t0) > deadline { r.timedOut = true; break }
            let (el, depth) = queue[head]; head += 1
            r.visited += 1
            let role = string(el, kAXRoleAttribute) ?? ""
            let texts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXHelpAttribute, kAXValueAttribute]
                .compactMap { string(el, $0) }.filter { !$0.isEmpty && $0.count <= 80 }
            let low = texts.map { $0.lowercased() }
            if Self.targetRoles.contains(role), let rank = hints.firstIndex(where: { h in low.contains { Self.matches($0, h) } }), rank < bestRank {
                bestRank = rank; bestText = describe(el, role: role, texts: texts)
                if rank == 0 { break }
            }
            if r.blocker == nil, !blockers.isEmpty, ["AXButton", "AXStaticText", "AXTextField", "AXHeading", "AXLink"].contains(role),
               let b = blockers.first(where: { h in low.contains { Self.matches($0, h) } }) {
                r.blocker = "'\(b)' \(describe(el, role: role, texts: texts))"
            }
            if depth < 40 { queue += elements(el, kAXChildrenAttribute).map { ($0, depth + 1) } }
        }
        r.found = bestText
        return r
    }

    /// Whole-word match ("code" matches "Code Windows", not "Barcode").
    static func matches(_ text: String, _ hint: String) -> Bool {
        guard let rg = text.range(of: hint) else { return false }
        let before = rg.lowerBound == text.startIndex ? nil : text[text.index(before: rg.lowerBound)]
        let after = rg.upperBound == text.endIndex ? nil : text[rg.upperBound]
        return !(before?.isLetter ?? false) && !(after?.isLetter ?? false)
    }

    func describe(_ el: AXUIElement, role: String, texts: [String]) -> String {
        var s = "\(role) '\(texts.first ?? "")'"
        if let id = string(el, kAXIdentifierAttribute), !id.isEmpty { s += " id=\(id)" }
        if let p = point(el), let z = size(el) { s += String(format: " at (%.0f,%.0f) %.0fx%.0f", p.x, p.y, z.width, z.height) }
        return s
    }

    func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }
    func string(_ el: AXUIElement, _ attr: String) -> String? { copy(el, attr) as? String }
    func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        guard let v = copy(el, attr) else { return [] }
        if CFGetTypeID(v) == AXUIElementGetTypeID() { return [v as! AXUIElement] }
        return (v as? [AXUIElement]) ?? []
    }
    func point(_ el: AXUIElement) -> CGPoint? {
        guard let v = copy(el, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero; return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }
    func size(_ el: AXUIElement) -> CGSize? {
        guard let v = copy(el, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero; return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
}

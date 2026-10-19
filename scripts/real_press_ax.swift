// Helper for real_press_smoke.sh (compiled by it into $TMPDIR; not part of the app). Accessibility on exactly the two
// processes the smoke owns: READS the isolated FLOW's windows, presses ONLY Peak's own Run / STOP buttons in the demo
// Peak instance the smoke launched, and (STOP rerun prep) closes an open 'Code Window' window in the isolated FLOW.
// Every command refuses production FLOW first: bundle id com.forceiq.flowai, /Applications/FLOW.app, any running
// production-bundle pid, or a pid in FORCEIQ_PEAK_PROTECTED_PIDS. It never activates, launches, types or clicks.
import AppKit
import ApplicationServices
import Foundation

let productionBundles: Set<String> = ["com.forceiq.flowai"]
let productionPaths = ["/applications/flow.app"]

func productionPids() -> Set<Int32> {
    var s = Set(productionBundles.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.map(\.processIdentifier))
    for p in (ProcessInfo.processInfo.environment["FORCEIQ_PEAK_PROTECTED_PIDS"] ?? "").split(whereSeparator: { $0 == "," || $0 == " " }) {
        if let v = Int32(p), v > 0 { s.insert(v) }
    }
    return s
}
func isProdBundle(_ b: String?) -> Bool { productionBundles.contains((b ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
func isProdPath(_ p: String?) -> Bool {
    guard let p, !p.isEmpty else { return false }
    let n = URL(fileURLWithPath: p).standardizedFileURL.path.lowercased()
    return productionPaths.contains { n == $0 || n.hasPrefix($0 + "/") }
}
/// nil = not production. Same rules as PeakCore ProductionGuard.reason.
func refusal(pid: Int32, bundle: String?, path: String?, protected: Set<Int32>) -> String? {
    if protected.contains(pid) { return "pid \(pid) is protected (production FLOW)" }
    if isProdBundle(bundle) { return "production FLOW (bundle \(bundle!))" }
    if isProdPath(path) { return "production FLOW (/Applications/FLOW.app)" }
    if (bundle ?? "").isEmpty { return "pid \(pid) has no readable bundle id" }
    return nil
}
func refuse(_ why: String) -> Never { print("REFUSED: \(why)"); exit(3) }
/// The isolated FLOW, resolved by pid; refused if it is production.
func isolated(_ pidArg: String) -> NSRunningApplication {
    guard let pid = Int32(pidArg), pid > 0 else { refuse("not a pid: \(pidArg)") }
    let prot = productionPids()
    if prot.contains(pid) { refuse("pid \(pid) is protected (production FLOW)") }
    guard let app = NSRunningApplication(processIdentifier: pid) else { print("no running app with pid \(pid)"); exit(4) }
    if let why = refusal(pid: pid, bundle: app.bundleIdentifier, path: app.bundleURL?.path, protected: prot) { refuse(why) }
    return app
}
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func now() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }
func codeWindowItems(_ app: AXUIElement) -> [String] {
    var out: [String] = []
    func walk(_ e: AXUIElement, _ d: Int, _ path: String) {
        if d > 6 { return }
        let t = attr(e, "AXTitle") as? String ?? ""
        if d > 0 && t == "Code Window" {
            out.append("\(path) > 'Code Window' role=\(attr(e, "AXRole") as? String ?? "") enabled=\((attr(e, "AXEnabled") as? Bool) ?? false)")
        }
        for c in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { walk(c, d + 1, t.isEmpty ? path : (path.isEmpty ? t : path + " > " + t)) }
    }
    if let bar = attr(app, "AXMenuBar") { walk(bar as! AXUIElement, 0, "") }
    return out
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: real_press_ax target <pid|-> <bundle|-> | windows <flowpid> | press-peak <peakpid> <peak app path> <button> | close-code-window <flowpid> | selftest"); exit(2) }
switch args[1] {
case "target":                  // resolve the isolated FLOW from a pid and/or bundle id; print it or refuse
    let prot = productionPids()
    let pidArg = args.count > 2 ? args[2] : "-", bArg = args.count > 3 ? args[3] : "-"
    if bArg != "-" && isProdBundle(bArg) { refuse("production FLOW (bundle \(bArg))") }
    var app: NSRunningApplication?
    if pidArg != "-" {
        guard let p = Int32(pidArg), p > 0 else { refuse("not a pid: \(pidArg)") }
        if prot.contains(p) { refuse("pid \(p) is protected (production FLOW)") }
        app = NSRunningApplication(processIdentifier: p)
        if let a = app, bArg != "-", a.bundleIdentifier != bArg { refuse("pid \(p) is \(a.bundleIdentifier ?? "?"), not \(bArg)") }
    } else if bArg != "-" {
        let all = NSRunningApplication.runningApplications(withBundleIdentifier: bArg)
        if all.count != 1 { print("expected exactly one running \(bArg), found \(all.count)"); exit(4) }
        app = all.first
    }
    guard let a = app else { print("no such running app"); exit(4) }
    if let why = refusal(pid: a.processIdentifier, bundle: a.bundleIdentifier, path: a.bundleURL?.path, protected: prot) { refuse(why) }
    print("target pid=\(a.processIdentifier) bundle=\(a.bundleIdentifier!) app=\(a.bundleURL?.path ?? "?") protected_pids=\(prot.sorted().map(String.init).joined(separator: ","))")
case "windows":                 // READ-ONLY window list of the isolated FLOW
    let a = isolated(args[2])
    let app = AXUIElementCreateApplication(a.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1.0)
    let ws = (attr(app, "AXWindows") as? [AXUIElement]) ?? []
    let titles = ws.map { attr($0, "AXTitle") as? String ?? "" }
    print("t=\(now()) pid=\(a.processIdentifier) bundle=\(a.bundleIdentifier!) frontmost=\(a.isActive ? "yes" : "no") windows=\(ws.count) code_window_windows=\(titles.filter { $0 == "Code Window" }.count)")
    for (i, w) in ws.enumerated() {
        print("  w\(i): title='\(titles[i])' subrole=\(attr(w, "AXSubrole") as? String ?? "-") main=\((attr(w, "AXMain") as? Bool) ?? false)")
    }
    for m in codeWindowItems(app) { print("  menu: \(m)") }
case "press-peak":              // press ONE of Peak's own buttons (Run / STOP) in the demo Peak this smoke launched
    guard let pid = Int32(args[2]), let a = NSRunningApplication(processIdentifier: pid) else { print("no peak pid"); exit(4) }
    let want = args[4]
    let exe = URL(fileURLWithPath: args[3]).standardizedFileURL.path
    guard a.bundleIdentifier == "com.forceiq.peak", a.bundleURL?.standardizedFileURL.path == exe else { refuse("pid \(pid) is not the smoke's own Peak build") }
    guard AXIsProcessTrusted() else { print("untrusted"); exit(2) }
    let app = AXUIElementCreateApplication(pid)
    func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
        if d > 40 { return nil }
        let names = [attr(e, "AXDescription"), attr(e, "AXTitle"), attr(e, "AXIdentifier")].compactMap { $0 as? String }
        if (attr(e, "AXRole") as? String) == "AXButton" && names.contains(want) { return e }
        for c in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { if let f = find(c, d + 1) { return f } }
        return nil
    }
    let t0 = now()
    for _ in 0..<60 {
        for w in (attr(app, "AXWindows") as? [AXUIElement]) ?? [] {
            if let b = find(w, 0) {
                let tp = now(); let r = AXUIElementPerformAction(b, kAXPressAction as CFString)
                print("pressed Peak's \(want) result=\(r.rawValue) search_start=\(t0) press_t=\(tp)"); exit(r == .success ? 0 : 1)
            }
        }
        usleep(50_000)
    }
    print("no \(want) button in Peak pid \(pid)"); exit(1)
case "close-code-window":       // STOP rerun prep: close the isolated FLOW's 'Code Window' window (its close button)
    let a = isolated(args[2])
    let app = AXUIElementCreateApplication(a.processIdentifier)
    var closed = 0
    for w in (attr(app, "AXWindows") as? [AXUIElement]) ?? [] where (attr(w, "AXTitle") as? String) == "Code Window" {
        if let c = attr(w, "AXCloseButton"), AXUIElementPerformAction(c as! AXUIElement, kAXPressAction as CFString) == .success { closed += 1 }
    }
    print("t=\(now()) closed_code_windows=\(closed) pid=\(a.processIdentifier)")
case "selftest":                // the refusal rules on synthetic inputs (touches no process)
    let cases: [(String, Int32, String?, String?, Set<Int32>, Bool)] = [
        ("pid 11311 protected", 11311, "com.forceiq.flowai.uat.x", "/Users/x/DerivedData/FLOW.app", [11311], true),
        ("production bundle", 500, "com.forceiq.flowai", "/Users/x/DerivedData/FLOW.app", [], true),
        ("production bundle, case/space", 500, " COM.FORCEIQ.FLOWAI ", nil, [], true),
        ("production app path", 500, "com.forceiq.flowai.uat.x", "/Applications/FLOW.app", [], true),
        ("no bundle id", 500, nil, "/Users/x/DerivedData/FLOW.app", [], true),
        ("isolated uat build", 500, "com.forceiq.flowai.uat.x", "/Users/x/DerivedData/FLOW.app", [11311], false),
    ]
    var ok = true
    for (name, pid, b, p, prot, want) in cases {
        let r = refusal(pid: pid, bundle: b, path: p, protected: prot)
        print("\(name): \(r.map { "REFUSED: " + $0 } ?? "allowed")"); if (r != nil) != want { ok = false; print("  UNEXPECTED") }
    }
    exit(ok ? 0 : 1)
default:
    print("unknown command"); exit(2)
}

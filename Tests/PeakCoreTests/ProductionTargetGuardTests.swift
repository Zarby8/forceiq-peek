import Foundation
import XCTest
@testable import PeakCore

// Production FLOW is never a live desktop-action target: the bundle id com.forceiq.flowai, /Applications/FLOW.app, any
// protected pid (e.g. Chris's running FLOW, 11311 on the M5), and a process with no readable bundle id are refused by
// ProductionGuard; the smoke-only target (FORCEIQ_PEAK_FLOW_TARGET_PID / _BUNDLE) can't name production either; the
// presser and the locator ask the guard before they press or bring anything forward; and real_press_smoke.sh refuses.

@MainActor final class ProductionTargetGuardTests: XCTestCase {
    let uat = "com.forceiq.flowai.uat.run-20261019t101913z-34722"
    let uatPath = "/Users/x/.forceiq/demo/candidate/DerivedData/Build/Products/Release/FLOW.app"

    func testRefusesProductionPid11311() throws {
        let prot = ProductionGuard.protectedPids(env: [ProductionGuard.protectedPidsEnv: "11311"])
        XCTAssertEqual(prot, [11311])
        // refused even when it claims a non-production bundle and path: the pid alone is enough
        let why = try XCTUnwrap(ProductionGuard.reason(pid: 11311, bundleID: uat, bundlePath: uatPath, protectedPids: prot))
        XCTAssertTrue(why.contains("11311") && why.contains("production FLOW"), why)
        XCTAssertNotNil(ProductionGuard.reason(pid: 11311, bundleID: "com.forceiq.flowai", bundlePath: "/Applications/FLOW.app", protectedPids: prot))
        XCTAssertEqual(ProductionGuard.protectedPids(env: [ProductionGuard.protectedPidsEnv: " 11311, 42 x,-3 0"]), [11311, 42])
        XCTAssertEqual(ProductionGuard.protectedPids(env: [:]), [])
    }

    func testRefusesTheProductionBundleIdForAnyPid() throws {
        for b in ["com.forceiq.flowai", "COM.FORCEIQ.FLOWAI", " com.forceiq.flowai ", "Com.ForceIQ.FlowAI\n"] {
            XCTAssertTrue(ProductionGuard.isProductionBundle(b), b)
            let why = try XCTUnwrap(ProductionGuard.reason(pid: 500, bundleID: b, bundlePath: uatPath, protectedPids: []), b)
            XCTAssertTrue(why.contains("production FLOW (bundle com.forceiq.flowai") || why.lowercased().contains("com.forceiq.flowai"), why)
        }
        // test builds with their own bundle id are not production
        for b in [uat, "com.forceiq.flowai.uitests", "com.forceiq.flowaix", "com.forceiq.peak"] { XCTAssertFalse(ProductionGuard.isProductionBundle(b), b) }
        XCTAssertFalse(ProductionGuard.isProductionBundle(nil)); XCTAssertFalse(ProductionGuard.isProductionBundle(""))
    }

    func testRefusesTheProductionAppPathAndUnknownBundles() {
        for p in ["/Applications/FLOW.app", "/Applications/FLOW.app/", "/applications/flow.app", "/Applications/FLOW.app/Contents/MacOS/FLOW",
                  "/Applications/./FLOW.app"] {
            XCTAssertTrue(ProductionGuard.isProductionAppPath(p), p)
            XCTAssertNotNil(ProductionGuard.reason(pid: 500, bundleID: uat, bundlePath: p, protectedPids: []), p)
        }
        for p in [uatPath, "/Applications/FLOW.app.bak", "/Applications/FLOWAI.app", "/Users/x/Applications/FLOW.app"] {
            XCTAssertFalse(ProductionGuard.isProductionAppPath(p), p)
        }
        XCTAssertNotNil(ProductionGuard.reason(pid: 500, bundleID: nil, bundlePath: uatPath, protectedPids: []), "no bundle id: refused")
        XCTAssertNotNil(ProductionGuard.reason(pid: 500, bundleID: "  ", bundlePath: uatPath, protectedPids: []))
    }

    func testAllowsOnlyAnIsolatedNonProductionBuild() {
        XCTAssertNil(ProductionGuard.reason(pid: 92451, bundleID: uat, bundlePath: uatPath, protectedPids: [11311]))
        XCTAssertNil(ProductionGuard.reason(pid: 92451, bundleID: uat, bundlePath: nil, protectedPids: []))
    }

    func testSmokeTargetCanNeverNameProduction() throws {
        XCTAssertNil(FlowSmokeTarget.from(env: [:]))
        XCTAssertNil(FlowSmokeTarget.from(env: [FlowSmokeTarget.pidEnv: " ", FlowSmokeTarget.bundleEnv: ""]))
        let byPid = try XCTUnwrap(FlowSmokeTarget.from(env: [FlowSmokeTarget.pidEnv: "11311"]))
        XCTAssertEqual(byPid, FlowSmokeTarget(pid: 11311))
        XCTAssertNotNil(byPid.refusal(protectedPids: [11311]), "pid 11311 (production FLOW) is refused as a target")
        let byBundle = try XCTUnwrap(FlowSmokeTarget.from(env: [FlowSmokeTarget.bundleEnv: "com.forceiq.flowai"]))
        XCTAssertTrue(byBundle.refusal(protectedPids: [])?.contains("production FLOW") == true)
        XCTAssertNotNil(FlowSmokeTarget(bundleID: "COM.FORCEIQ.FLOWAI").refusal(protectedPids: []))
        for bad in ["abc", "-5", "0", "12x"] {
            let t = try XCTUnwrap(FlowSmokeTarget.from(env: [FlowSmokeTarget.pidEnv: bad]))
            XCTAssertTrue(t.invalid, bad); XCTAssertNotNil(t.refusal(protectedPids: []), bad)
            XCTAssertFalse(t.matches(pid: 92451, bundleID: uat), bad)
        }
        let ok = try XCTUnwrap(FlowSmokeTarget.from(env: [FlowSmokeTarget.pidEnv: "92451", FlowSmokeTarget.bundleEnv: uat]))
        XCTAssertNil(ok.refusal(protectedPids: [11311]))
        XCTAssertTrue(ok.matches(pid: 92451, bundleID: uat))
        XCTAssertFalse(ok.matches(pid: 11311, bundleID: uat), "another pid is not the target")
        XCTAssertFalse(ok.matches(pid: 92451, bundleID: "com.forceiq.flowai"), "another bundle is not the target")
        XCTAssertTrue(FlowSmokeTarget(bundleID: uat).matches(pid: 1, bundleID: uat))
        XCTAssertFalse(FlowSmokeTarget().matches(pid: 1, bundleID: uat), "an empty target matches nothing")
    }

    // ── the presser and the locator ask the guard first ──
    static let sources = DesktopDryRunTests.sourcesDir
    func src(_ f: String) throws -> String { try String(contentsOf: Self.sources.appendingPathComponent(f), encoding: .utf8) }

    func testPresserRefusesProductionBeforeThePressGuardAndTheSingleAXPress() throws {
        let ps = try src("ForceIQPeak/DesktopPresser.swift")
        let running = try XCTUnwrap(ps.range(of: "ProductionPids.running()"), "every running production FLOW pid is protected")
        let target = try XCTUnwrap(ps.range(of: "target?.refusal(protectedPids: protected)"))
        let prod = try XCTUnwrap(ps.range(of: "ProductionGuard.reason(pid: front.pid, bundleID: front.bundle, bundlePath: front.path, protectedPids: protected)"))
        let match = try XCTUnwrap(ps.range(of: "!target.matches(pid: front.pid, bundleID: front.bundle)"))
        let pressGuard = try XCTUnwrap(ps.range(of: "PressGuard.refusal("))
        let press = try XCTUnwrap(ps.range(of: "AXUIElementPerformAction("))
        XCTAssertTrue(running.lowerBound < target.lowerBound && target.lowerBound < prod.lowerBound && prod.lowerBound < match.lowerBound
                      && match.lowerBound < pressGuard.lowerBound && pressGuard.lowerBound < press.lowerBound)
        XCTAssertTrue(ps.contains("ProductionGuard.protectedPids(env: env)"))
        XCTAssertTrue(ps.contains("refused: the frontmost app is \\(why); nothing pressed"))
        XCTAssertTrue(ps.contains("NSRunningApplication.runningApplications(withBundleIdentifier: $0)"))
    }

    func testLocatorNeverBringsProductionForwardInLiveMode() throws {
        let loc = try src("ForceIQPeak/DesktopLocator.swift")
        let fwd = try XCTUnwrap(loc.range(of: "func bringForward"))
        let act = try XCTUnwrap(loc.range(of: ".activate("))
        let body = loc[fwd.lowerBound..<act.lowerBound]
        XCTAssertTrue(body.contains("let refuseProduction = self.refuseProduction || target != nil"), "a smoke target always refuses production")
        XCTAssertTrue(body.contains("target?.refusal(protectedPids: protected)"))
        XCTAssertTrue(body.contains("ProductionGuard.reason(pid: app.processIdentifier, bundleID: app.bundleIdentifier, bundlePath: app.bundleURL?.path"))
        XCTAssertTrue(body.contains("!t.matches(pid: app.processIdentifier, bundleID: app.bundleIdentifier)"))
        XCTAssertTrue(body.contains("NSRunningApplication(processIdentifier: $0)"), "a pid target activates exactly that instance")
        let app = try src("ForceIQPeak/AppDelegate.swift")
        XCTAssertTrue(app.contains("locator: AXDesktopLocator(refuseProduction: live)"), "live mode refuses production FLOW in the locator")
        XCTAssertTrue(app.contains("if ProductionGuard.isProductionBundle(b) { log.log(\"desktop smoke target refused: production FLOW\") } else { a.flowBundle = b }"))
    }

    // ── a title-less FLOW window shows its package as a static text; a client-named scratch symlink finds it ──
    func testFrontWindowMatchedByItsPackageTextAndThroughASymlink() throws {
        let pkg = "/Users/x/.forceiq/demo/FLOW-Demo.flowaipkg"
        func cand(_ title: String?, _ texts: [String], doc: String? = nil) -> PressCandidate {
            PressCandidate(role: "AXMenuItem", title: "Code Window", enabled: true, pid: 9, bundleID: uat, frontmostPid: 9,
                           documentPath: doc, windowTitle: title, windowTexts: texts)
        }
        XCTAssertTrue(PressGuard.frontWindowIsPackage(cand("", ["ANALYSIS", "FLOW-DEMO"]), packagePath: pkg))
        XCTAssertTrue(PressGuard.frontWindowIsPackage(cand("", [" flow-demo "]), packagePath: pkg))
        XCTAssertFalse(PressGuard.frontWindowIsPackage(cand("", ["FLOW-DEMO 2", "FLOW", "DEMO_PACKAGE"]), packagePath: pkg), "exact text only")
        XCTAssertFalse(PressGuard.frontWindowIsPackage(cand(nil, ["FLOW-DEMO"]), packagePath: pkg), "no window title attribute: refused")
        XCTAssertFalse(PressGuard.frontWindowIsPackage(cand("FLOW", ["FLOW-DEMO"]), packagePath: pkg), "a non-empty title decides alone")
        XCTAssertFalse(PressGuard.frontWindowIsPackage(cand("", ["TOB"]), packagePath: "/p/Tob.flowaipkg"), "short names never match")
        let refused = PressGuard.refusal(cand("", ["OTHER-PACKAGE"]), flowBundle: uat, packagePath: pkg, client: "Sample Skater")
        XCTAssertTrue(refused?.hasSuffix("nothing pressed") == true)
        XCTAssertNil(PressGuard.refusal(cand("", ["FLOW-DEMO"]), flowBundle: uat, packagePath: pkg, client: "Sample Skater"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peak-prodguard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("demo/FLOW-Demo.flowaipkg"), links = dir.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        let link = links.appendingPathComponent("Sample Skater (FLOW-Demo).flowaipkg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertTrue(PressGuard.frontWindowIsPackage(cand("", ["FLOW-DEMO"]), packagePath: link.path), "the link resolves to the open package")
        XCTAssertTrue(PressGuard.frontWindowIsPackage(cand("FLOW", [], doc: real.absoluteString), packagePath: link.path), "AXDocument vs link")
        XCTAssertFalse(PressGuard.frontWindowIsPackage(cand("FLOW", [], doc: "file:///Users/x/Other.flowaipkg"), packagePath: link.path))
    }

    // ── only the exact package name matches: a partial or prefix name (title or static text) is refused ──
    func testWindowGuardRefusesPartialOrPrefixPackageName() throws {
        let pkg = "/Users/x/.forceiq/demo/FLOW-Demo.flowaipkg"
        func cand(_ title: String?, _ texts: [String] = []) -> PressCandidate {
            PressCandidate(role: "AXMenuItem", title: "Code Window", enabled: true, pid: 9, bundleID: uat, frontmostPid: 9,
                           documentPath: nil, windowTitle: title, windowTexts: texts)
        }
        // the exact name is accepted, by title or (title-less window) by static text
        XCTAssertTrue(PressGuard.frontWindowIsPackage(cand("FLOW-Demo"), packagePath: pkg))
        XCTAssertTrue(PressGuard.frontWindowIsPackage(cand("", ["FLOW-DEMO"]), packagePath: pkg))
        let partial = ["FLOW-Dem", "FLOW-Demo-extra", "FLOW-Demo 2", "FLOW-Demo.bak", "My FLOW-Demo", "LOW-Demo", "xFLOW-Demo",
                       "FLOW-Demo — FLOW-Demo-extra", "FLOW-DemoFLOW-Demo"]
        for p in partial {
            XCTAssertFalse(PressGuard.frontWindowIsPackage(cand(p), packagePath: pkg), "title '\(p)' must be refused")
            XCTAssertFalse(PressGuard.frontWindowIsPackage(cand("", [p]), packagePath: pkg), "text '\(p)' must be refused")
            XCTAssertFalse(PressGuard.frontWindowIsPackage(cand("", [p.uppercased()]), packagePath: pkg), "text '\(p.uppercased())' must be refused")
            let why = try XCTUnwrap(PressGuard.refusal(cand(p), flowBundle: uat, packagePath: pkg, client: "Sample Skater"), p)
            XCTAssertTrue(why.hasSuffix("nothing pressed"), why)
        }
        // a longer package is not matched by a window showing its prefix, either
        XCTAssertFalse(PressGuard.frontWindowIsPackage(cand("FLOW-Demo"), packagePath: "/Users/x/.forceiq/demo/FLOW-Demo-extra.flowaipkg"))
        XCTAssertFalse(PressGuard.frontWindowIsPackage(cand("", ["FLOW-DEMO"]), packagePath: "/Users/x/.forceiq/demo/FLOW-Demo-extra.flowaipkg"))
    }

    // ── the smoke script refuses production before it looks at or launches anything ──
    func testSmokeScriptRefusesProduction() throws {
        let script = Self.sources.deletingLastPathComponent().appendingPathComponent("scripts/real_press_smoke.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))
        func run(_ args: [String], env extra: [String: String] = [:]) throws -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path] + args
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: ProductionGuard.protectedPidsEnv)
            for (k, v) in extra { env[k] = v }
            p.environment = env
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run(); p.waitUntilExit()
            return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        }
        for b in ["com.forceiq.flowai", "COM.FORCEIQ.FLOWAI", "Com.ForceIQ.FlowAI"] {
            let (code, out) = try run(["--bundle", b, "--package", "/nonexistent.flowaipkg"])
            XCTAssertEqual(code, 3, out); XCTAssertTrue(out.hasPrefix("REFUSED: production FLOW (bundle"), out)
        }
        let (code, out) = try run(["--pid", "11311", "--bundle", uat, "--check-only"], env: [ProductionGuard.protectedPidsEnv: "11311"])
        XCTAssertEqual(code, 3, out); XCTAssertTrue(out.hasPrefix("REFUSED: pid 11311 is protected"), out)
        let (c2, o2) = try run(["--pid", "abc"])
        XCTAssertEqual(c2, 3, o2)
        let s = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(s.contains("PROD_BUNDLE=com.forceiq.flowai") && s.contains("PROD_APP=/Applications/FLOW.app"))
        XCTAssertTrue(s.contains("pgrep -f \"^$PROD_APP/Contents/MacOS/\""), "every running production FLOW pid is protected")
        XCTAssertTrue(s.contains("FORCEIQ_PEAK_PROTECTED_PIDS=\"$PROTECTED\""), "Peek gets the same protected pids")
        XCTAssertFalse(s.contains("open -a") || s.contains("screencapture") || s.contains("osascript"))
        XCTAssertTrue(s.contains("\"hiddenDisplays\": [], \"globallyHidden\": False"), "settings.json Peek actually loads")
    }
}

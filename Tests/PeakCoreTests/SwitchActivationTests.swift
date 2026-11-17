import Foundation
import XCTest
@testable import PeakCore

// The switcher activation plan — the state matrix behind AppLauncher's calls.
// The bug: activating a running full-screen app never moved the user to its Space.
// Measured live (Nov 17, 2026) against a sacrificial full-screen app: activate() — bare and
// with .activateAllWindows — returned true and changed nothing; NSWorkspace.openApplication
// errored; a Launch Services reopen (`open -b`) switched Spaces every time.

final class SwitchActivationTests: XCTestCase {
    func testNotRunningLaunches() {
        XCTAssertEqual(SwitchActivation.plan(running: false, hidden: false), .launch)
        XCTAssertEqual(SwitchActivation.plan(running: false, hidden: true), .launch, "hidden is meaningless when not running")
    }

    func testRunningReopensThroughLaunchServices() {
        XCTAssertEqual(SwitchActivation.plan(running: true, hidden: false), .reopen,
                       "a Launch Services reopen is what carries the user to a full-screen Space")
        XCTAssertEqual(SwitchActivation.plan(running: true, hidden: true), .reopen,
                       "a reopen also unhides: hidden no longer changes the plan")
    }

    /// The app side performs the plan (source-level wiring, like GPUGuardTests).
    func testAppLauncherPerformsThePlan() throws {
        let base = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/SwitchActivationTests.swift", with: "Sources/ForceIQPeak/")
        let support = try String(contentsOfFile: base + "Support.swift", encoding: .utf8)
        let launcher = support.components(separatedBy: "@MainActor enum AppLauncher").last?
            .components(separatedBy: "// ─────").first ?? ""
        XCTAssertTrue(launcher.contains("SwitchActivation.plan(running: true, hidden: running.isHidden)"), "the plan decides")
        XCTAssertTrue(launcher.contains("LocalCommand.runStatus"), "the reopen runs through the audited facade")
        XCTAssertTrue(launcher.contains("\"-b\""), "the reopen is `open -b <bundleID>`")
        XCTAssertFalse(launcher.contains(".activateAllWindows"), "the all-windows activation is gone: it returned true and changed nothing")
        XCTAssertFalse(launcher.contains("running.activate("), "no NSRunningApplication.activate on the running path")
    }

    /// The session jumper's app activation shares the reopen path (same bug, second site).
    func testSessionJumperReopensToo() throws {
        let base = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/SwitchActivationTests.swift", with: "Sources/ForceIQPeak/")
        let jumper = try String(contentsOfFile: base + "SessionJumper.swift", encoding: .utf8)
        XCTAssertTrue(jumper.contains("LocalCommand.runStatus"), "the jumper reopens through the audited facade")
        XCTAssertTrue(jumper.contains("\"-b\""), "the jumper's reopen is `open -b <bundleID>`")
    }
}

import Foundation
import XCTest
@testable import PeakCore

// The switcher activation plan — the state matrix behind AppLauncher's calls.
// The bug: activating a running full-screen app never moved the user to its Space.
// Measured live (Nov 17, 2026): on a single display a reopen (`open -b`) switched Spaces and
// activate() did not; on Christopher's three-display desk the reopen ALSO failed to switch —
// activate(), `open -b`, an Accessibility raise, and AppleScript activate all made the app
// frontmost and left the display on its old Space. The app side therefore SpaceJumps first.

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

    /// Both switch sites move the display into the app's Space BEFORE the reopen — the
    /// reopen alone does not switch Spaces on a multi-display desk (Christopher's report).
    func testBothSitesSpaceJumpBeforeReopening() throws {
        let base = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/SwitchActivationTests.swift", with: "Sources/ForceIQPeak/")
        let support = try String(contentsOfFile: base + "Support.swift", encoding: .utf8)
        let launcher = support.components(separatedBy: "@MainActor enum AppLauncher").last?
            .components(separatedBy: "// ─────").first ?? ""
        let jump = launcher.range(of: "SpaceJump.jumpToWindowSpace(of: running)")
        let reopen = launcher.range(of: "LocalCommand.runStatus")
        XCTAssertNotNil(jump, "the launcher jumps to the app's Space")
        XCTAssertNotNil(reopen)
        if let jump, let reopen { XCTAssertLessThan(jump.lowerBound, reopen.lowerBound, "the jump precedes the reopen") }
        let jumper = try String(contentsOfFile: base + "SessionJumper.swift", encoding: .utf8)
        XCTAssertTrue(jumper.contains("SpaceJump.jumpToWindowSpace(of: app)"), "the jumper jumps too")
        let bridge = try String(contentsOfFile: base + "SpaceJump.swift", encoding: .utf8)
        XCTAssertTrue(bridge.contains("SLSManagedDisplaySetCurrentSpace"), "the jump is SkyLight's managed-space setter")
        XCTAssertTrue(bridge.contains("dlsym"), "symbols resolve at runtime — a missing one degrades to the plain reopen")
    }

    /// The session jumper's app activation shares the reopen path (same bug, second site).
    func testSessionJumperReopensToo() throws {
        let base = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/SwitchActivationTests.swift", with: "Sources/ForceIQPeak/")
        let jumper = try String(contentsOfFile: base + "SessionJumper.swift", encoding: .utf8)
        XCTAssertTrue(jumper.contains("LocalCommand.runStatus"), "the jumper reopens through the audited facade")
        XCTAssertTrue(jumper.contains("\"-b\""), "the jumper's reopen is `open -b <bundleID>`")
    }
}

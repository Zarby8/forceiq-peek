import Foundation
import XCTest
@testable import PeakCore

// Stage 4: the switcher activation plan — the state matrix behind AppLauncher's AppKit calls.
// The bug: a bare activate() on a running full-screen app never moved the user to its Space.

final class SwitchActivationTests: XCTestCase {
    func testNotRunningLaunches() {
        XCTAssertEqual(SwitchActivation.plan(running: false, hidden: false), .launch)
        XCTAssertEqual(SwitchActivation.plan(running: false, hidden: true), .launch, "hidden is meaningless when not running")
    }

    func testRunningWindowedRaisesAllWindows() {
        XCTAssertEqual(SwitchActivation.plan(running: true, hidden: false),
                       .activate(allWindows: true, unhideFirst: false),
                       "all-windows activation is what carries the user to a full-screen Space")
    }

    func testRunningHiddenUnhidesFirst() {
        XCTAssertEqual(SwitchActivation.plan(running: true, hidden: true),
                       .activate(allWindows: true, unhideFirst: true))
    }

    func testRunningFullScreenIsTheAllWindowsCase() {
        // A full-screen app is simply running + not hidden from the plan's point of view; the
        // all-windows activation is the case that switches Spaces to reach it.
        let plan = SwitchActivation.plan(running: true, hidden: false)
        guard case .activate(let allWindows, _) = plan else { return XCTFail("expected .activate, got \(plan)") }
        XCTAssertTrue(allWindows)
    }

    /// The app side performs the plan with the real options (source-level wiring, like GPUGuardTests).
    func testAppLauncherPerformsThePlan() throws {
        let base = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/SwitchActivationTests.swift", with: "Sources/ForceIQPeak/")
        let support = try String(contentsOfFile: base + "Support.swift", encoding: .utf8)
        let launcher = support.components(separatedBy: "@MainActor enum AppLauncher").last?
            .components(separatedBy: "// ─────").first ?? ""
        XCTAssertTrue(launcher.contains("SwitchActivation.plan(running: true, hidden: running.isHidden)"), "the plan decides")
        XCTAssertTrue(launcher.contains(".activateAllWindows"), "all-windows activation is performed")
        XCTAssertTrue(launcher.contains(".activateIgnoringOtherApps"))
        XCTAssertTrue(launcher.contains("running.unhide()"), "hidden apps are unhidden first")
        XCTAssertFalse(launcher.contains("running.activate()"), "the bare activate() that missed full-screen Spaces is gone")
    }
}

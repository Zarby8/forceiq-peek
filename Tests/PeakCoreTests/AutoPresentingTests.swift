import Foundation
import XCTest
@testable import PeakCore

/// Presenting turns itself on while Command is live on this Mac (meetings run in the Command app) and off when it ends,
/// unless the coach turned it off for that meeting. Fake clients only.
@MainActor final class AutoPresentingTests: XCTestCase {
    func controller(_ root: URL = tmpRoot(), log: MemLog? = nil) -> PeakController {
        PeakController(prefs: PeakPrefs(stateRoot: root), profile: fixtureProfile("profile-coach-a"), hotkey: FakeHotkey(), logger: log)
    }
    let alert = PeakAlert(id: "m1", kind: .meetingSoon, client: "Sample Skater", line: "Sample Skater in 9 min", holdSeconds: 0.05, plainLine: "A session in 9 min")

    func testThePolicyMatrix() {
        for manual in [false, true] { for auto in [false, true] { for live in [false, true] { for sup in [false, true] {
            let want = manual || (auto && live && !sup)
            XCTAssertEqual(PresentingPolicy.effective(manual: manual, autoEnabled: auto, commandLive: live, suppressed: sup), want)
        } } } }
    }

    func testCommandLiveTurnsPresentingOnAndItsEndTurnsItOffWithoutPersisting() {
        let root = tmpRoot(); let log = MemLog(); let c = controller(root, log: log)
        XCTAssertFalse(c.presenting)
        c.setCommandLive(true)
        XCTAssertTrue(c.presenting); XCTAssertTrue(c.presentingAuto)
        XCTAssertFalse(PeakPrefs(stateRoot: root).presenting, "automatic presenting is never written down")
        XCTAssertTrue(log.lines.contains("state presenting=on reason=command-live"))
        c.setCommandLive(false)
        XCTAssertFalse(c.presenting); XCTAssertFalse(c.presentingAuto)
        XCTAssertTrue(log.lines.contains("state presenting=off"))
    }

    func testAnUnreadableLiveStatusChangesNothing() {
        let c = controller()
        c.setCommandLive(nil); XCTAssertFalse(c.presenting)
        c.setCommandLive(true); c.setCommandLive(nil)
        XCTAssertTrue(c.presenting, "can't tell: stay as it was, never un-hide a shared screen on a failed read")
    }

    func testTurnedOffInSettingsItNeverTurnsItselfOn() {
        let r = tmpRoot()
        try! Data(#"{"autoPresenting": false}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        let c = controller(r)
        c.setCommandLive(true); XCTAssertFalse(c.presenting)
    }

    func testPresentingByHandStaysAfterTheMeetingEnds() {
        let root = tmpRoot(); let c = controller(root)
        c.setCommandLive(true); c.setPresenting(true)
        XCTAssertFalse(c.presentingAuto, "now it is by hand")
        c.setCommandLive(false)
        XCTAssertTrue(c.presenting, "the coach turned it on; only the coach turns it off")
        XCTAssertTrue(controller(root).presenting, "and it survives a relaunch")
    }

    func testTurningItOffDuringAMeetingHoldsUntilThatMeetingEndsThenTheNextOneIsAutomaticAgain() {
        let c = controller()
        c.setCommandLive(true); XCTAssertTrue(c.presenting)
        c.setPresenting(false)
        XCTAssertFalse(c.presenting, "Show details: the coach wants it visible")
        c.setCommandLive(true); XCTAssertFalse(c.presenting, "repeated live reads don't flip it back")
        c.setCommandLive(false); XCTAssertFalse(c.presenting)
        c.setCommandLive(true); XCTAssertTrue(c.presenting, "the next meeting presents again")
    }

    func testAPeekWhileAutoPresentingShowsOnlyThePlainLine() {
        let c = controller()
        c.setCommandLive(true)
        c.showPeek(alert, on: "D1")
        XCTAssertEqual(c.peek?.line, "A session in 9 min"); XCTAssertEqual(c.peek?.client, "")
    }

    func testAnAutoPresentingStartClearsWhatIsOnTheSheet() {
        let c = controller()
        c.showPeek(alert, on: "D1"); XCTAssertNotNil(c.peek)
        c.setCommandLive(true)
        XCTAssertNil(c.peek); XCTAssertNil(c.askText); XCTAssertEqual(c.tab, .home)
    }

    func testAutoPresentingDefaultsOnAndReadsLeniently() {
        let r = tmpRoot()
        XCTAssertTrue(PeakPrefs(stateRoot: r).autoPresenting)
        try! Data(#"{"autoPresenting": null}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        XCTAssertTrue(PeakPrefs(stateRoot: r).autoPresenting)
        try! Data(#"{"autoPresenting": "no"}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        let bad = PeakPrefs(stateRoot: r)
        XCTAssertTrue(bad.autoPresenting, "an unreadable file leaves it on: the privacy-safe side")
        XCTAssertTrue(bad.loadIssue?.contains("autoPresenting") ?? false)
        XCTAssertTrue(PeakPrefs.Doc.CodingKeys.allCases.map(\.stringValue).contains("autoPresenting"))
    }

    func testEveryFeedReadReportsCommandLiveToTheController() throws {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/AutoPresentingTests.swift", with: "Sources/ForceIQPeak/AppDelegate.swift")
        let app = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(app.components(separatedBy: "controller.setCommandLive(s.gpuWindow?.live)").count - 1,
                       app.components(separatedBy: "gpuLight.update(s.gpuWindow").count - 1, "every place the light updates also tells the controller")
    }
}

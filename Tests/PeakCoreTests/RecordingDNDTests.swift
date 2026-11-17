import Foundation
import XCTest
@testable import PeakCore

// Recording DND: the tracker state machine, the controller's darkness, and the feed parse.
// Fake names only; every clock is injected.

final class RecordingDNDTrackerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testTrueEngagesFalseReleases() {
        var tr = RecordingDNDTracker()
        XCTAssertFalse(tr.update(recording: false, meetingEnd: nil, now: t0))
        XCTAssertTrue(tr.update(recording: true, meetingEnd: nil, now: t0))
        XCTAssertTrue(tr.engaged)
        XCTAssertEqual(tr.engagedAt, t0)
        XCTAssertFalse(tr.update(recording: false, meetingEnd: nil, now: t0.addingTimeInterval(600)))
        XCTAssertNil(tr.engagedAt)
    }

    func testFirstReadTrueAtLaunchEngages() {
        var tr = RecordingDNDTracker()
        XCTAssertTrue(tr.update(recording: true, meetingEnd: t0.addingTimeInterval(3600), now: t0))
    }

    func testNilNeverChangesAnything() {
        var tr = RecordingDNDTracker()
        XCTAssertFalse(tr.update(recording: nil, meetingEnd: nil, now: t0))
        XCTAssertTrue(tr.update(recording: true, meetingEnd: nil, now: t0))
        XCTAssertTrue(tr.update(recording: nil, meetingEnd: nil, now: t0.addingTimeInterval(600)), "unknown never releases")
    }

    func testStuckBoundWithMeetingEndForceReleasesAndLatches() {
        var tr = RecordingDNDTracker()
        let end = t0.addingTimeInterval(3600)   // meeting ends 1 h after it starts recording
        XCTAssertTrue(tr.update(recording: true, meetingEnd: end, now: t0))
        XCTAssertTrue(tr.update(recording: true, meetingEnd: end, now: end.addingTimeInterval(44 * 60)), "inside the 45 min grace")
        XCTAssertFalse(tr.update(recording: true, meetingEnd: end, now: end.addingTimeInterval(46 * 60)), "past end + grace: force-released")
        XCTAssertTrue(tr.latchedIgnore)
        XCTAssertFalse(tr.update(recording: true, meetingEnd: end.addingTimeInterval(7200), now: end.addingTimeInterval(50 * 60)),
                       "latched: a stuck-on true is ignored")
        XCTAssertFalse(tr.update(recording: nil, meetingEnd: nil, now: end.addingTimeInterval(55 * 60)), "nil does not clear the latch")
        XCTAssertFalse(tr.update(recording: false, meetingEnd: nil, now: end.addingTimeInterval(3600)), "false clears the latch")
        XCTAssertFalse(tr.latchedIgnore)
        XCTAssertTrue(tr.update(recording: true, meetingEnd: nil, now: end.addingTimeInterval(3700)), "after the latch clears, true engages again")
    }

    func testStuckBoundWithoutMeetingEndIsThreeHours() {
        var tr = RecordingDNDTracker()
        XCTAssertTrue(tr.update(recording: true, meetingEnd: nil, now: t0))
        XCTAssertTrue(tr.update(recording: true, meetingEnd: nil, now: t0.addingTimeInterval(3 * 3600 - 60)))
        XCTAssertFalse(tr.update(recording: true, meetingEnd: nil, now: t0.addingTimeInterval(3 * 3600 + 60)))
        XCTAssertTrue(tr.latchedIgnore)
    }

    func testFalseWhileEngagedClearsEngagementTime() {
        var tr = RecordingDNDTracker()
        _ = tr.update(recording: true, meetingEnd: nil, now: t0)
        _ = tr.update(recording: false, meetingEnd: nil, now: t0.addingTimeInterval(60))
        XCTAssertTrue(tr.update(recording: true, meetingEnd: nil, now: t0.addingTimeInterval(120)))
        XCTAssertEqual(tr.engagedAt, t0.addingTimeInterval(120), "a new engagement starts a new clock")
    }
}

@MainActor final class RecordingDNDControllerTests: XCTestCase {
    func makeController() -> PeakController {
        PeakController(prefs: PeakPrefs(stateRoot: tmpRoot()), profile: fixtureProfile("profile-coach-a"), hotkey: FakeHotkey())
    }
    let alert = PeakAlert(id: "m1", kind: .meetingSoon, client: "Sample Skater", line: "Sample Skater in 9 min", holdSeconds: 0.05, plainLine: "A session in 9 min")

    func testDarknessHidesPanelsRefusesExpandAndPeek() {
        let c = makeController()
        XCTAssertTrue(c.panelVisible(on: "any-display"))
        c.setRecording(true, meetingEnd: nil)
        XCTAssertTrue(c.recordingDND)
        XCTAssertFalse(c.panelVisible(on: "any-display"), "no panel on any display while recording")
        c.expand()
        XCTAssertFalse(c.expanded, "expand is refused while dark")
        c.showPeek(alert, on: "any-display")
        XCTAssertNil(c.peek, "no peek while dark")
        c.setRecording(false, meetingEnd: nil)
        XCTAssertFalse(c.recordingDND)
        XCTAssertTrue(c.panelVisible(on: "any-display"), "release restores visibility")
        c.expand()
        XCTAssertTrue(c.expanded)
    }

    func testExpandedStateSurvivesTheDarkPeriod() {
        let c = makeController()
        c.expand()
        XCTAssertTrue(c.expanded)
        c.setRecording(true, meetingEnd: nil)
        XCTAssertTrue(c.expanded, "DND hides the panel but preserves the expanded state")
        XCTAssertFalse(c.panelVisible(on: "any-display"))
        c.setRecording(false, meetingEnd: nil)
        XCTAssertTrue(c.expanded, "on release the panel returns as it was")
        XCTAssertTrue(c.panelVisible(on: "any-display"))
    }

    func testAnotherCoachLiveAndRecordingElsewhereNeverDarkens() {
        // The engine hard-scopes its `recording` flag to the owner's own booking, so while another
        // coach's session is live the reads stay false — and false reads never darken Peek, however
        // many arrive, even with a meeting end set (the owner's own next session rides the same
        // snapshot). This is the app-level half of the hard scope: only a positively-true flag,
        // which the engine now only produces for the owner's own recording, can darken Peek.
        let c = makeController()
        let end = Date().addingTimeInterval(3600)
        for _ in 0..<3 { c.setRecording(false, meetingEnd: end) }
        XCTAssertFalse(c.recordingDND)
        XCTAssertTrue(c.panelVisible(on: "any-display"))
        c.expand()
        XCTAssertTrue(c.expanded)
    }

    func testUnknownReadsChangeNothing() {
        let c = makeController()
        c.setRecording(nil, meetingEnd: nil)
        XCTAssertFalse(c.recordingDND)
        c.setRecording(true, meetingEnd: nil)
        c.setRecording(nil, meetingEnd: nil)
        XCTAssertTrue(c.recordingDND, "an unknown read never releases DND")
    }
}

final class RecordingSignalParseTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(RecordingSignal.parse(["ok": true, "recording": true]), true)
        XCTAssertEqual(RecordingSignal.parse(["ok": true, "recording": false]), false)
        XCTAssertNil(RecordingSignal.parse(["ok": true]), "absent (old engine) is unknown")
        XCTAssertNil(RecordingSignal.parse(["ok": false, "recording": true]), "an error doc is unknown")
        XCTAssertNil(RecordingSignal.parse(["ok": true, "recording": "yes"]), "a non-bool is unknown")
    }
}

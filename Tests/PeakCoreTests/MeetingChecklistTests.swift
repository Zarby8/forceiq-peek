import Foundation
import XCTest
@testable import PeakCore

/// The live coaching checklist: stages, elapsed/remaining, the collapsed pill line, the parking
/// lot and the ten-minute nudge. Pure timing + local state; no engine, no network, no client names.
@MainActor final class MeetingChecklistTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_418_400)              // a fixed instant
    func span(startMinutes: Double, endMinutes: Double, source: String = "command") -> GPUSpan {
        GPUSpan(start: t0.addingTimeInterval(startMinutes * 60), end: t0.addingTimeInterval(endMinutes * 60), source: source)
    }
    /// A meeting that started 38 min ago, 60 min long (22 min left).
    var liveSpan: GPUSpan { span(startMinutes: -38, endMinutes: 22) }

    func testNoSpanOrNotLiveMeansNoChecklist() {
        let m = MeetingChecklistModel()
        XCTAssertFalse(m.isLive(now: t0))
        XCTAssertNil(m.collapsedText(now: t0))
        XCTAssertEqual(m.update(spans: [], live: true, now: t0), .none)
        XCTAssertEqual(m.update(spans: [liveSpan], live: false, now: t0), .none)
        XCTAssertFalse(m.isLive(now: t0))
    }

    func testCalendarSpansNeverCountAsTheMeeting() {
        let m = MeetingChecklistModel()
        XCTAssertEqual(m.update(spans: [span(startMinutes: -38, endMinutes: 22, source: "calendar")], live: true, now: t0), .none)
        XCTAssertFalse(m.isLive(now: t0))
    }

    func testElapsedAndRemaining() {
        let m = MeetingChecklistModel()
        _ = m.update(spans: [liveSpan], live: true, now: t0)
        XCTAssertTrue(m.isLive(now: t0))
        XCTAssertEqual(m.elapsedText(now: t0), "38:00")
        XCTAssertEqual(Int(m.remainingSeconds(now: t0) ?? -1), 22 * 60)
    }

    func testCollapsedLineMarksCoveredCurrentAndLater() {
        let m = MeetingChecklistModel()
        _ = m.update(spans: [liveSpan], live: true, now: t0)
        XCTAssertEqual(m.collapsedText(now: t0), "38:00 · READ ● · TECH ○ · EXEC ○ · FIN ○")
        m.toggle(.read)
        XCTAssertEqual(m.collapsedText(now: t0), "38:00 · READ ✓ · TECH ● · EXEC ○ · FIN ○")
        m.toggle(.technique)
        XCTAssertEqual(m.collapsedText(now: t0), "38:00 · READ ✓ · TECH ✓ · EXEC ● · FIN ○")
        m.toggle(.execution); m.toggle(.finishing)
        XCTAssertEqual(m.collapsedText(now: t0), "38:00 · READ ✓ · TECH ✓ · EXEC ✓ · FIN ✓")
        m.toggle(.read)
        XCTAssertEqual(m.collapsedText(now: t0), "38:00 · READ ● · TECH ✓ · EXEC ✓ · FIN ✓")
    }

    func testParkingLotIsTheUncoveredStagesInOrder() {
        let m = MeetingChecklistModel()
        _ = m.update(spans: [liveSpan], live: true, now: t0)
        XCTAssertEqual(m.parkingLot, [.read, .technique, .execution, .finishing])
        m.toggle(.read); m.toggle(.execution)
        XCTAssertEqual(m.parkingLot, [.technique, .finishing])
    }

    func testClosingPickIsSeparateFromCovered() {
        let m = MeetingChecklistModel()
        _ = m.update(spans: [liveSpan], live: true, now: t0)
        m.closeOn(.finishing)
        XCTAssertEqual(m.closing, .finishing)
        XCTAssertFalse(m.covered.contains(.finishing))
        XCTAssertEqual(m.parkingLot, [.read, .technique, .execution, .finishing])
    }

    func testNudgeFiresOnceInTheLastTenMinutes() {
        let m = MeetingChecklistModel()
        // 22 min left: not due.
        XCTAssertEqual(m.update(spans: [liveSpan], live: true, now: t0), .none)
        XCTAssertFalse(m.nudgeShown)
        // 10:00 left exactly: due, and the lot shows.
        let at10 = t0.addingTimeInterval(12 * 60)
        XCTAssertEqual(m.update(spans: [liveSpan], live: true, now: at10), .fire)
        XCTAssertTrue(m.nudgeShown)
        // A later tick in the same span: shown, but never fires twice.
        XCTAssertEqual(m.update(spans: [liveSpan], live: true, now: at10.addingTimeInterval(60)), .none)
        XCTAssertTrue(m.nudgeShown)
        // Dismissed: stays dismissed for this span.
        m.dismissNudge()
        XCTAssertFalse(m.nudgeShown)
        XCTAssertEqual(m.update(spans: [liveSpan], live: true, now: at10.addingTimeInterval(120)), .none)
    }

    func testNudgeNeverFiresWhenTheMeetingIsNotLive() {
        let m = MeetingChecklistModel()
        let at10 = t0.addingTimeInterval(12 * 60)
        XCTAssertEqual(m.update(spans: [liveSpan], live: false, now: at10), .none)
        XCTAssertFalse(m.nudgeShown)
        // A span that has already ended: not due.
        let ended = span(startMinutes: -70, endMinutes: -10)
        XCTAssertEqual(m.update(spans: [ended], live: true, now: t0), .none)
    }

    func testNewMeetingResetsState() {
        let m = MeetingChecklistModel()
        _ = m.update(spans: [liveSpan], live: true, now: t0)
        m.toggle(.read); m.toggle(.technique); m.closeOn(.execution)
        let next = span(startMinutes: 120, endMinutes: 180)
        _ = m.update(spans: [next], live: true, now: t0.addingTimeInterval(150 * 60))
        XCTAssertTrue(m.covered.isEmpty)
        XCTAssertNil(m.closing)
        XCTAssertFalse(m.nudgeShown)
        XCTAssertEqual(m.elapsedText(now: t0.addingTimeInterval(150 * 60)), "30:00")
    }
}

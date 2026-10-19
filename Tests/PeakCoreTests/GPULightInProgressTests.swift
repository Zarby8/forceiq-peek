import Foundation
import XCTest
@testable import PeakCore

/// The 5090 light holds from 2 h before a meeting THROUGH its end (TRON 10.19.2026). The bookings read is upcoming-only,
/// so a meeting in progress comes from Command's live status or the calendar, and either being unknown or STALE holds
/// the 5090. Each case runs the real engine doc through GPUWindow.parse → GPULightModel → the drop zone's gate.
/// Mocked data, FAKE client names only.
@MainActor final class GPULightInProgressTests: XCTestCase {
    static let now = EngineParse.date("2026-10-19T13:30:00Z")!          // 9:30 AM ET
    static let preview = GPURefusalTests.shiftPreview

    /// A next-meeting doc as engine/peakmeeting.py sends it (bookings upcoming-only: no meeting here unless given).
    func doc(spans: [(String, String, String)] = [], live: Any = false, calendar: String = "ok",
             calendarAt: String? = "2026-10-19T13:28:00Z", issue: String? = nil) -> [String: Any] {
        var w: [String: Any] = ["read_at": "2026-10-19T13:30:00+00:00",
                                "spans": spans.map { ["start": $0.0, "end": $0.1, "source": $0.2] },
                                "live": live,
                                "sources": ["command_bookings": "ok", "command_live": live is Bool ? "ok" : "unknown", "calendar": calendar]]
        w["calendar_at"] = calendarAt ?? NSNull()
        w["calendar_issue"] = issue ?? NSNull()
        return ["ok": true, "meeting": NSNull(), "today": [], "gpu_window": w]
    }

    func light(_ d: [String: Any]) -> GPULightModel {
        let m = GPULightModel(); m.clock = { Self.now }
        m.update(GPUWindow.parse(d), at: Self.now)
        return m
    }

    /// The shifts (upscale) drop zone, gated by this light. Returns the phase and whether anything reached the engine.
    func drop(with m: GPULightModel) async -> (DropPhase, Bool) {
        let t = FakeTransport(); t.answers["/api/peak/shift-drop/preview"] = (200, Self.preview)
        let d = DropStore(transport: t); d.gpuHold = { m.hold() }
        d.received(URL(fileURLWithPath: "/Users/x/Alpha_DemoHawks_10.18.2026.mp4"))
        await d.preview(.shift)
        return (d.phase, !t.posts.isEmpty)
    }

    // (1) started 20 min ago (9:10 AM ET), not in the upcoming-only bookings, but live AND on the calendar → red, refused
    func testMeetingInProgressFromLiveAndCalendarIsRedAndTheDropZoneIsRefused() async {
        let m = light(doc(spans: [("2026-10-19T13:10:00+00:00", "2026-10-19T14:10:00+00:00", "calendar")], live: true))
        XCTAssertEqual(m.state(), .red("meeting in progress (started 9:10 AM ET)"))
        let why = "Meeting in progress (started 9:10 AM ET): 5090 GPU jobs are held so the recorder isn't disturbed. Nothing ran."
        XCTAssertEqual(m.hold(), why)
        let (phase, reached) = await drop(with: m)
        XCTAssertEqual(phase, .failed(why))
        XCTAssertFalse(reached, "refused: nothing reached the engine")
        let late = EngineParse.date("2026-10-19T14:09:30Z")!                   // a fresh read a minute before it ends
        m.update(GPUWindow.parse(doc(spans: [("2026-10-19T13:10:00+00:00", "2026-10-19T14:10:00+00:00", "calendar")], live: true,
                                     calendarAt: "2026-10-19T14:09:00Z")), at: late)
        XCTAssertEqual(m.state(now: late), .red("meeting in progress (started 9:10 AM ET)"), "held through its end")
    }

    func testCommandLiveAloneIsAMeetingInProgress() {
        let m = light(doc(live: true))
        XCTAssertEqual(m.state(), .red("meeting in progress (Command is live on this Mac)"))
        XCTAssertEqual(m.hold(), "Meeting in progress (Command is live on this Mac): 5090 GPU jobs are held so the recorder isn't disturbed. Nothing ran.")
    }

    // (2) ended 30 min ago, nothing upcoming → green, GPU actions allowed
    func testMeetingThatEnded30MinAgoIsGreenAndGPUActionsAreAllowed() async {
        let m = light(doc(spans: [("2026-10-19T12:00:00+00:00", "2026-10-19T13:00:00+00:00", "calendar")], live: false))
        XCTAssertEqual(m.state(), .green)
        XCTAssertNil(m.hold())
        let (phase, reached) = await drop(with: m)
        guard case .described = phase else { return XCTFail("green: the drop zone previews (\(phase))") }
        XCTAssertTrue(reached)
        let t = FakeTransport()
        var o = proposalJSON(action: "recover"); o["inputs"] = ["job": "Test Client Alpha 10.18", "step": "gpu_and_deliver"]
        t.events = [.proposal(ProposalPolicy.card(from: o)!), .done(text: "", costUSD: 0, peakMTD: nil, warn: nil, firstTokenMs: nil)]
        let s = ThreePOStore(transport: t); s.gpuHold = { m.hold() }
        s.draft = "retry the upscale"; await s.send(); await s.run("abc123abc123")
        XCTAssertEqual(t.posts.last?.0, "/api/act", "green: a GPU proposal runs")
    }

    func testTheLightTurnsGreenAtTheMeetingsEndNotBefore() {
        let m = light(doc(spans: [("2026-10-19T13:10:00+00:00", "2026-10-19T14:10:00+00:00", "calendar")], live: false,
                          calendarAt: "2026-10-19T14:09:00Z"))
        XCTAssertTrue(m.state(now: EngineParse.date("2026-10-19T14:09:59Z")!).holdsGPU)
        m.update(GPUWindow.parse(doc(spans: [], live: false, calendarAt: "2026-10-19T14:10:00Z")), at: EngineParse.date("2026-10-19T14:10:00Z")!)
        XCTAssertEqual(m.state(now: EngineParse.date("2026-10-19T14:10:00Z")!), .green)
    }

    // (3) the live-status read failing → red (unknown), even with clear bookings and a clear, fresh calendar
    func testLiveStatusFailureIsRedEvenWhenBookingsAndCalendarAreClear() async {
        let m = light(doc(spans: [], live: NSNull()))
        XCTAssertEqual(m.state(), .unknown("Command's live status couldn't be read"))
        XCTAssertEqual(m.state().dotHex, Brand.redHex)
        let (phase, reached) = await drop(with: m)
        XCTAssertEqual(phase, .failed("Meeting status unknown (Command's live status couldn't be read): 5090 GPU jobs are held until Peak can see there's no meeting within 2 h. Nothing ran."))
        XCTAssertFalse(reached)
    }

    // (4) the calendar STALE or unknown → red (unknown)
    func testStaleCalendarIsRed() async {
        let m = light(doc(spans: [], live: false, calendarAt: "2026-10-19T13:20:00Z"))       // fetched 10 min ago
        XCTAssertEqual(m.state(), .unknown("calendar STALE (read 9:20 AM ET, 10 min ago)"))
        let (phase, reached) = await drop(with: m)
        if case .failed(let why) = phase { XCTAssertTrue(why.hasPrefix("Meeting status unknown (calendar STALE (read 9:20 AM ET, 10 min ago))"), why) }
        else { XCTFail("stale calendar: refused") }
        XCTAssertFalse(reached)
        XCTAssertEqual(light(doc(live: false, calendarAt: "2026-10-19T13:25:00Z")).state(), .green, "300 s old is still fresh")
        XCTAssertTrue(light(doc(live: false, calendarAt: "2026-10-19T13:24:59Z")).state().holdsGPU, "301 s old is STALE")
    }

    func testUnknownCalendarIsRedInEveryForm() async {
        let unread = light(doc(live: false, calendar: "unknown", calendarAt: nil, issue: "the calendar snapshot couldn't be read"))
        XCTAssertEqual(unread.state(), .unknown("calendar unknown: the calendar snapshot couldn't be read"))
        let (phase, reached) = await drop(with: unread)
        if case .failed = phase {} else { XCTFail("unknown calendar: refused") }
        XCTAssertFalse(reached)
        // "unknown" with a stray time is still unknown; an older engine with no sources at all is unknown.
        XCTAssertTrue(light(doc(live: false, calendar: "unknown", calendarAt: "2026-10-19T13:28:00Z")).state().holdsGPU)
        var old = doc(live: false); var w = old["gpu_window"] as! [String: Any]
        w.removeValue(forKey: "sources"); w.removeValue(forKey: "calendar_at"); old["gpu_window"] = w
        XCTAssertEqual(light(old).state(), .unknown("calendar unknown: calendar status unavailable"))
        XCTAssertEqual(GPULight.evaluate(GPUWindow(spans: [], live: false), readAt: Self.now, now: Self.now),
                       .unknown("calendar unknown: calendar status unavailable"), "the default is unknown: fail closed")
    }

    // (5) in progress per the calendar only (live idle) → red
    func testCalendarOnlyMeetingInProgressIsRedWhileLiveIsIdle() async {
        let m = light(doc(spans: [("2026-10-19T13:10:00+00:00", "2026-10-19T14:10:00+00:00", "calendar")], live: false))
        XCTAssertEqual(m.state(), .red("meeting in progress (started 9:10 AM ET)"))
        let (phase, reached) = await drop(with: m)
        XCTAssertEqual(phase, .failed("Meeting in progress (started 9:10 AM ET): 5090 GPU jobs are held so the recorder isn't disturbed. Nothing ran."))
        XCTAssertFalse(reached)
    }

    func testAConcreteMeetingOutranksAnUnknownSourceInTheMessage() {
        let m = light(doc(spans: [("2026-10-19T13:10:00+00:00", "2026-10-19T14:10:00+00:00", "command")], live: NSNull(),
                          calendar: "unknown", calendarAt: nil, issue: "x"))
        XCTAssertEqual(m.state(), .red("meeting in progress (started 9:10 AM ET)"))
    }
}

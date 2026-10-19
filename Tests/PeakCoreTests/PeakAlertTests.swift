import Foundation
import XCTest
@testable import PeakCore

/// Notch alerts: the peek geometry, the edge trigger, the hover lift, AlertPolicy (what may interrupt and what may not),
/// quiet hours / do-not-disturb prefs, and the controller's peek. Fake clients only; no engine, no screen.
@MainActor final class PeakAlertTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_418_400)
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }
    let m5 = ScreenDescriptor(uuid: "M5", name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 2048, height: 1330),
                              safeAreaTop: 43, auxiliaryTopLeft: CGRect(x: 0, y: 1287, width: 899, height: 43),
                              auxiliaryTopRight: CGRect(x: 1149, y: 1287, width: 899, height: 43))
    let studio = ScreenDescriptor(uuid: "S", name: "Studio Display", frame: CGRect(x: 2048, y: 0, width: 2560, height: 1440),
                                  safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)

    // ── helpers ──
    func snap(meetingIn minutes: Double? = nil, fixes: [FixRow] = [], live: Bool = true, today: [SessionRow]? = nil) -> EngineSnapshot {
        var s = EngineSnapshot()
        if let m = minutes {
            s.meeting = MeetingRow(client: "Sample Skater", scheduledAt: t0.addingTimeInterval(m * 60), durationMinutes: 60, joinURL: nil,
                                   openURL: CommandLink.room(sessionID: "demo_session"))
        }
        s.fixes = fixes; s.today = today
        if live { s.liveAt = t0 }
        return s
    }
    func cards(_ s: EngineSnapshot) -> [PeakCard] {
        (s.meeting.map { CardBuilder.meetingCards($0) } ?? []) + CardBuilder.fixAndApprovalCards(s).cards
    }
    func fix(_ state: String, client: String = "Demo Player", title: String = "Re-render crest title slide") -> FixRow {
        FixRow(title: title, client: client, state: state, message: "")
    }
    func ctx(_ at: Double = 0, expanded: Bool = false, dictating: Bool = false, dnd: Date? = nil, quiet: QuietHours? = nil) -> AlertContext {
        AlertContext(now: t0.addingTimeInterval(at), expanded: expanded, dictating: dictating, dndUntil: dnd, quietHours: quiet, calendar: cal)
    }

    // ── geometry ──
    func testPeekDropsBelowTheNotchAndStaysInTheCanvas() {
        let l = PeakGeometry().layout(for: m5)
        XCTAssertEqual(l.collapsed, CGRect(x: 899, y: 1287, width: 250, height: 43), "collapsed is still exactly the notch")
        XCTAssertEqual(l.peek.maxY, 1330, "the peek hangs from the top edge")
        XCTAssertEqual(l.peek.midX, l.notchRect!.midX, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(l.peek.width, l.collapsed.width)
        XCTAssertEqual(l.peekStrip.maxY, l.notchRect!.minY, accuracy: 0.5, "the text band starts under the notch row")
        XCTAssertEqual(l.peekStrip.minY, l.peek.minY, accuracy: 0.5)
        XCTAssertTrue(l.canvas.contains(l.peek))
        XCTAssertEqual(l.hitRect(.peek), l.peek)
    }

    func testEdgeTriggerIsAThinStripAtTheTopEdgeThatNeverTakesAClick() {
        let l = PeakGeometry().layout(for: m5)
        XCTAssertTrue(l.triggers(at: CGPoint(x: 1024, y: 1329)))
        XCTAssertTrue(l.triggers(at: CGPoint(x: 899 - 35, y: 1329)), "a little past the notch edge")
        XCTAssertFalse(l.triggers(at: CGPoint(x: 899 - 80, y: 1329)), "not the whole menu bar")
        XCTAssertFalse(l.triggers(at: CGPoint(x: 1024, y: 1330 - 20)), "not below the first few points of the edge")
        for s in [PeakLayout.Surface.collapsed, .peek, .home, .chat] {
            XCTAssertNotEqual(l.hitRect(s), l.edgeTrigger, "the trigger is never a surface: it takes no clicks")
        }
        XCTAssertLessThan(l.edgeTrigger.minX, l.collapsed.minX); XCTAssertGreaterThan(l.edgeTrigger.maxX, l.collapsed.maxX)
        XCTAssertEqual(l.edgeTrigger.height, 3)
    }

    func testStudioDisplayHasNoEdgeTriggerAndItsPeekHangsFromThePill() {
        let l = PeakGeometry().layout(for: studio)
        XCTAssertEqual(l.mode, .pill)
        XCTAssertEqual(l.edgeTrigger, .zero)
        XCTAssertFalse(l.triggers(at: CGPoint(x: studio.frame.midX, y: studio.frame.maxY - 1)))
        XCTAssertLessThanOrEqual(l.peek.maxY, studio.frame.maxY)
        XCTAssertLessThan(l.peekStrip.maxY, l.collapsed.minY + 0.5, "the text band sits below the pill")
        XCTAssertTrue(l.canvas.contains(l.peek))
    }

    // ── hover lift ──
    func testTheNotchNeverLiftsOnHoverOnlyThePillDoes() {
        XCTAssertFalse(HoverLift.applies(mode: .notch, hovering: true, expanded: false, reduceMotion: false))
        XCTAssertTrue(HoverLift.applies(mode: .pill, hovering: true, expanded: false, reduceMotion: false))
        XCTAssertFalse(HoverLift.applies(mode: .pill, hovering: true, expanded: true, reduceMotion: false))
        XCTAssertFalse(HoverLift.applies(mode: .pill, hovering: true, expanded: false, reduceMotion: true))
    }

    // ── AlertPolicy: what peeks ──
    func testMeetingWithinTenMinutesPeeksOnceAndNamesTheClient() {
        var p = AlertPolicy()
        let s = snap(meetingIn: 9)
        let a = p.next(snapshot: s, cards: cards(s), context: ctx())
        XCTAssertEqual(a?.kind, .meetingSoon); XCTAssertEqual(a?.client, "Sample Skater")
        XCTAssertEqual(a?.line, "Sample Skater in 9 min")
        XCTAssertNil(p.next(snapshot: s, cards: cards(s), context: ctx(120)), "once per meeting")
    }

    func testMeetingOutsideTheTenMinuteWindowDoesNotPeek() {
        var p = AlertPolicy()
        let far = snap(meetingIn: 42)
        XCTAssertNil(p.next(snapshot: far, cards: cards(far), context: ctx()))
        let started = snap(meetingIn: -1)
        XCTAssertNil(p.next(snapshot: started, cards: cards(started), context: ctx()))
        let edge = snap(meetingIn: 10)
        XCTAssertNotNil(p.next(snapshot: edge, cards: cards(edge), context: ctx()), "exactly 10 min is in the window")
    }

    func testAFixThatFailsAfterLaunchPeeksButOnesAlreadyFailingDoNot() {
        var p = AlertPolicy()
        let old = snap(fixes: [fix("failed")])
        XCTAssertNil(p.next(snapshot: old, cards: cards(old), context: ctx()), "already failing at launch is not news")
        XCTAssertNil(p.next(snapshot: old, cards: cards(old), context: ctx(300)))
        let fresh = snap(fixes: [fix("failed"), fix("failed", title: "Rebuild shift export")])
        let a = p.next(snapshot: fresh, cards: cards(fresh), context: ctx(600))
        XCTAssertEqual(a?.kind, .fixFailed); XCTAssertEqual(a?.client, "Demo Player")
        XCTAssertTrue(a?.line.contains("Demo Player") ?? false)
    }

    func testAFeedWithoutGOATsLiveDocNeverBaselinesOrAlertsOnFixes() {
        var p = AlertPolicy()
        let blind = snap(fixes: [fix("failed")], live: false)
        XCTAssertNil(p.next(snapshot: blind, cards: cards(blind), context: ctx()))
        let real = snap(fixes: [fix("failed")])
        XCTAssertNil(p.next(snapshot: real, cards: cards(real), context: ctx(60)), "the first real read is the baseline, not an alert")
    }

    func testRunningFixesNeverPeek() {
        var p = AlertPolicy()
        let calm = snap(fixes: [])
        _ = p.next(snapshot: calm, cards: cards(calm), context: ctx())
        let running = snap(fixes: [fix("running")])
        XCTAssertNil(p.next(snapshot: running, cards: cards(running), context: ctx(60)))
    }

    func testAClientNotOnTheCoachsCardListNeverPeeks() {
        var p = AlertPolicy()
        let s = snap(meetingIn: 5)
        XCTAssertNil(p.next(snapshot: s, cards: [], context: ctx()), "roster scoping dropped the card, so nothing peeks")
    }

    // ── AlertPolicy: what holds one back ──
    func testHeldAlertsAreNotSpentAndFireWhenTheGateLifts() {
        var p = AlertPolicy()
        let s = snap(meetingIn: 9)
        XCTAssertNil(p.next(snapshot: s, cards: cards(s), context: ctx(expanded: true)))
        XCTAssertEqual(p.lastSuppression, .expanded)
        XCTAssertNil(p.next(snapshot: s, cards: cards(s), context: ctx(30, dictating: true)))
        XCTAssertEqual(p.lastSuppression, .dictating)
        XCTAssertNil(p.next(snapshot: s, cards: cards(s), context: ctx(60, dnd: t0.addingTimeInterval(3600))))
        XCTAssertEqual(p.lastSuppression, .doNotDisturb)
        XCTAssertNotNil(p.next(snapshot: s, cards: cards(s), context: ctx(90, dnd: t0.addingTimeInterval(60))), "DND already over")
    }

    func testQuietHoursWrapMidnightAndUseLocalTime() {
        let q = QuietHours(start: "22:00", end: "07:00")!
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: h, minute: m))! }
        XCTAssertTrue(q.contains(at(23), calendar: cal)); XCTAssertTrue(q.contains(at(3), calendar: cal))
        XCTAssertTrue(q.contains(at(22), calendar: cal)); XCTAssertFalse(q.contains(at(7), calendar: cal))
        XCTAssertFalse(q.contains(at(12), calendar: cal))
        let day = QuietHours(start: "09:00", end: "10:30")!
        XCTAssertTrue(day.contains(at(10, 15), calendar: cal)); XCTAssertFalse(day.contains(at(10, 30), calendar: cal))
        XCTAssertFalse(QuietHours(start: "08:00", end: "08:00")!.contains(at(8), calendar: cal), "start == end is no window")
        XCTAssertNil(QuietHours(start: "25:00", end: "07:00")); XCTAssertNil(QuietHours(start: "7:00", end: "08:00"))
        XCTAssertNil(QuietHours(start: "ab:cd", end: "07:00"))
    }

    func testQuietHoursHoldAnAlert() {
        var p = AlertPolicy()
        let s = snap(meetingIn: 9)
        let q = QuietHours(startMinute: 0, endMinute: 24 * 60 - 1)
        XCTAssertNil(p.next(snapshot: s, cards: cards(s), context: ctx(quiet: q)))
        XCTAssertEqual(p.lastSuppression, .quietHours)
    }

    func testNothingPeeksDuringALiveMeeting() {
        var p = AlertPolicy()
        let live = SessionRow(client: "Demo Player", scheduledAt: t0.addingTimeInterval(-20 * 60), durationMinutes: 60)   // ends t0 + 40 min
        let during = snap(meetingIn: 9, today: [live])
        XCTAssertNil(p.next(snapshot: during, cards: cards(during), context: ctx()))
        XCTAssertEqual(p.lastSuppression, .liveMeeting)
        let after = snap(meetingIn: 50, today: [live])
        XCTAssertNil(p.next(snapshot: after, cards: cards(after), context: ctx(39 * 60)), "still live at 39 min; 11 min out anyway")
        XCTAssertNotNil(p.next(snapshot: after, cards: cards(after), context: ctx(41 * 60)), "the session ended, the next one is 9 min out")
    }

    func testOnlyOnePeekPerMinute() {
        var p = AlertPolicy()
        let first = snap(meetingIn: 9, fixes: [fix("running")])
        XCTAssertNotNil(p.next(snapshot: first, cards: cards(first), context: ctx()))
        let second = snap(meetingIn: 9, fixes: [fix("running"), fix("failed", title: "Another fix")])
        XCTAssertNil(p.next(snapshot: second, cards: cards(second), context: ctx(30)))
        XCTAssertEqual(p.lastSuppression, .cooldown)
        XCTAssertNotNil(p.next(snapshot: second, cards: cards(second), context: ctx(61)))
    }

    // ── prefs ──
    func testQuietHoursAndDNDPrefsLoadLeniently() {
        let r = tmpRoot()
        XCTAssertNil(PeakPrefs(stateRoot: r).quietHours); XCTAssertNil(PeakPrefs(stateRoot: r).dndUntil)
        try! Data(#"{"quietHoursStart":"22:00","quietHoursEnd":"07:00"}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        XCTAssertEqual(PeakPrefs(stateRoot: r).quietHours, QuietHours(startMinute: 22 * 60, endMinute: 7 * 60))
        try! Data(#"{"quietHoursStart":"22:00"}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        XCTAssertNil(PeakPrefs(stateRoot: r).quietHours, "one end alone is no window")
        try! Data(#"{"quietHoursStart":"25:00","quietHoursEnd":"07:00"}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        let bad = PeakPrefs(stateRoot: r)
        XCTAssertNil(bad.quietHours, "an invalid clock time fails closed")
        XCTAssertTrue(bad.loadIssue?.contains("quietHoursStart") ?? false)
        try! Data(#"{"dndUntil":"later"}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        XCTAssertTrue(PeakPrefs(stateRoot: r).loadIssue?.contains("dndUntil") ?? false)
        let keys = PeakPrefs.Doc.CodingKeys.allCases.map(\.stringValue)
        for k in ["quietHoursStart", "quietHoursEnd", "dndUntil"] { XCTAssertTrue(keys.contains(k)) }
    }

    func testDNDRoundTripsAndTomorrowMorningIsSevenLocal() {
        let r = tmpRoot()
        let p = PeakPrefs(stateRoot: r)
        let until = t0.addingTimeInterval(3600)
        p.dndUntil = until
        XCTAssertEqual(PeakPrefs(stateRoot: r).dndUntil?.timeIntervalSince1970 ?? 0, until.timeIntervalSince1970, accuracy: 0.001)
        p.dndUntil = nil
        XCTAssertNil(PeakPrefs(stateRoot: r).dndUntil)
        let night = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 23, minute: 30))!
        let m = DoNotDisturb.tomorrowMorning(after: night, calendar: cal)
        let c = cal.dateComponents([.day, .hour, .minute], from: m)
        XCTAssertEqual(c.day, 20); XCTAssertEqual(c.hour, 7); XCTAssertEqual(c.minute, 0)
        let early = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 5))!
        XCTAssertEqual(cal.component(.day, from: DoNotDisturb.tomorrowMorning(after: early, calendar: cal)), 19, "before 7: this morning")
    }

    // ── controller ──
    func controller(_ log: MemLog? = nil) -> PeakController {
        PeakController(prefs: PeakPrefs(stateRoot: tmpRoot()), profile: fixtureProfile("profile-coach-a"), hotkey: FakeHotkey(), logger: log)
    }
    let alert = PeakAlert(id: "meeting:Sample Skater:1", kind: .meetingSoon, client: "Sample Skater", line: "Sample Skater in 9 min", holdSeconds: 0.05)

    func testPeekRetractsByItselfAndLogsTheKindNeverTheClient() async {
        let log = MemLog(); let c = controller(log)
        c.showPeek(alert, on: "D1")
        XCTAssertEqual(c.peek, alert); XCTAssertEqual(c.peekDisplay, "D1")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(c.peek); XCTAssertNil(c.peekDisplay)
        XCTAssertTrue(log.lines.contains("state peek=meeting-soon")); XCTAssertTrue(log.lines.contains("state peek=off"))
        XCTAssertFalse(log.lines.contains { $0.contains("Sample Skater") }, "logs carry states, never a client")
    }

    func testExtendingKeepsThePeekPastItsHold() async {
        let c = controller()
        c.showPeek(PeakAlert(id: "x", kind: .fixFailed, client: "Demo Player", line: "Demo Player: a fix failed", holdSeconds: 0.1), on: "D1")
        try? await Task.sleep(nanoseconds: 60_000_000)
        c.extendPeek(seconds: 0.4)
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNotNil(c.peek, "the pointer is on it, so it stays")
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(c.peek)
    }

    func testTappingThePeekOpensTheSheetOnItsDisplayAndHandsTheAlertOver() {
        let c = controller(); var opened: PeakAlert?
        c.onPeekOpen = { opened = $0 }
        c.showPeek(alert, on: "D2")
        c.openPeek()
        XCTAssertTrue(c.expanded); XCTAssertEqual(c.activeDisplay, "D2"); XCTAssertNil(c.peek)
        XCTAssertEqual(opened, alert)
    }

    func testOnlyAVisibleCollapsedPeakPeeks() {
        let c = controller()
        c.expand()
        c.showPeek(alert, on: "D1")
        XCTAssertNil(c.peek, "already open")
        c.collapse(); c.hide()
        c.showPeek(alert, on: "D1")
        XCTAssertNil(c.peek, "hidden")
        c.show(); c.showPeek(alert, on: "D1"); XCTAssertNotNil(c.peek)
        c.expand(); XCTAssertNil(c.peek, "opening it dismisses the peek")
        c.collapse(); c.showPeek(alert, on: "D1"); c.hide(); XCTAssertNil(c.peek)
    }

    func testPeekShellColorsAreBrandTokensOnly() throws {
        let views = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/PeakAlertTests.swift", with: "Sources/ForceIQPeak/Views.swift"), encoding: .utf8)
        let line = views.components(separatedBy: "func peekLine").last?.components(separatedBy: "Collapsed + idle").first ?? ""
        XCTAssertTrue(line.contains("Color.white")); XCTAssertTrue(line.contains("Color.peakGold") && line.contains("Color.peakGreen"))
        XCTAssertFalse(line.contains("opacity") || line.contains(".secondary") || line.contains("gray") || line.contains("0x"), "pure white, no gray, no stray hex")
    }
}

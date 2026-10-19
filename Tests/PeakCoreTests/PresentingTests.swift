import Foundation
import XCTest
@testable import PeakCore

/// Presenting mode: nothing client-private on a shared screen. Fake clients only.
@MainActor final class PresentingTests: XCTestCase {
    let alert = PeakAlert(id: "meeting:Sample Skater:1", kind: .meetingSoon, client: "Sample Skater", line: "Sample Skater in 9 min",
                          holdSeconds: 0.05, plainLine: "A session in 9 min")

    func controller(_ root: URL = tmpRoot(), log: MemLog? = nil) -> PeakController {
        PeakController(prefs: PeakPrefs(stateRoot: root), profile: fixtureProfile("profile-coach-a"), hotkey: FakeHotkey(), logger: log)
    }

    func testRedactedAlertNamesNoClientAndKeepsItsKind() {
        let r = Presenting.redact(alert)
        XCTAssertEqual(r.client, ""); XCTAssertEqual(r.line, "A session in 9 min"); XCTAssertEqual(r.kind, .meetingSoon)
        XCTAssertEqual(r.id, alert.id); XCTAssertEqual(r.holdSeconds, alert.holdSeconds)
        XCTAssertFalse(r.line.contains("Sample Skater") || r.plainLine.contains("Sample Skater"))
    }

    func testEveryAlertKindHasAPlainLineWithoutTheClient() {
        for k in [PeakAlertKind.meetingSoon, .fixFailed] {
            let a = PeakAlert(id: "x", kind: k, client: "Demo Player", line: "Demo Player: x", holdSeconds: 1)
            XCTAssertFalse(a.plainLine.isEmpty); XCTAssertFalse(a.plainLine.contains("Demo Player"))
        }
    }

    func testThePolicyBuildsThePlainLineFromTheSameMinutes() {
        var p = AlertPolicy()
        let t0 = Date(timeIntervalSince1970: 1_792_418_400)
        var s = EngineSnapshot()
        s.meeting = MeetingRow(client: "Sample Skater", scheduledAt: t0.addingTimeInterval(9 * 60), durationMinutes: 60, joinURL: nil,
                               openURL: CommandLink.room(sessionID: "demo_session"))
        let a = p.next(snapshot: s, cards: CardBuilder.meetingCards(s.meeting!), context: AlertContext(now: t0))
        XCTAssertEqual(a?.plainLine, "A session in 9 min")
    }

    func testAPeekWhilePresentingShowsOnlyThePlainLine() {
        let log = MemLog(); let c = controller(log: log)
        c.setPresenting(true)
        c.showPeek(alert, on: "D1")
        XCTAssertEqual(c.peek?.line, "A session in 9 min"); XCTAssertEqual(c.peek?.client, "")
        c.openPeek()
        XCTAssertFalse(log.lines.contains { $0.contains("Sample Skater") })
    }

    func testTurningItOnClearsWhatIsAlreadyShowingAndPersists() {
        let root = tmpRoot()
        let c = controller(root)
        c.showPeek(alert, on: "D1"); c.openAsk("what did Sample Skater do"); c.tab = .threePO
        XCTAssertTrue(c.expanded)
        c.collapse(); c.showPeek(alert, on: "D1")
        c.openAsk("what did Sample Skater do")
        XCTAssertNotNil(c.askText)
        c.setPresenting(true)
        XCTAssertTrue(c.presenting); XCTAssertNil(c.peek); XCTAssertNil(c.askText); XCTAssertEqual(c.tab, .home)
        XCTAssertTrue(controller(root).presenting, "a relaunch never un-hides a shared screen")
        c.setPresenting(false)
        XCTAssertFalse(controller(root).presenting)
    }

    func testPrefsDefaultOffAndAnUnreadableFileFailsClosedToOn() {
        let r = tmpRoot()
        XCTAssertFalse(PeakPrefs(stateRoot: r).presenting)
        try! Data(#"{"presenting": true}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        XCTAssertTrue(PeakPrefs(stateRoot: r).presenting)
        try! Data(#"{"presenting": null}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        XCTAssertFalse(PeakPrefs(stateRoot: r).presenting, "null = the default")
        try! Data(#"{"presenting": "yes"}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        let bad = PeakPrefs(stateRoot: r)
        XCTAssertNotNil(bad.loadIssue)
        XCTAssertTrue(bad.presenting, "a settings file Peek can't read: hide everything, not nothing")
        XCTAssertTrue(PeakPrefs.Doc.CodingKeys.allCases.map(\.stringValue).contains("presenting"))
    }

    func testEveryClientBearingViewIsGatedOnPresenting() throws {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/PresentingTests.swift", with: "Sources/ForceIQPeak/Views.swift")
        let v = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(v.contains("var showChat: Bool { isExpanded && !controller.presenting"), "3PO chat")
        XCTAssertTrue(v.contains("if controller.presenting {\n                    PresentingNotice"), "the sheet shows the notice first, before cards / drops / ask / 3PO / next-session card")
        XCTAssertTrue(v.contains("nextSession.showsPill && !controller.presenting"), "the Studio pill's client countdown")
        XCTAssertTrue(v.contains("!isExpanded && !controller.presenting && panel.visible && voice.enabled"), "dictated words under the notch")
        XCTAssertTrue(v.contains("isEnabled(.threePO) && !controller.presenting { TabPills"), "the 3PO tab")
        let app = try String(contentsOfFile: path.replacingOccurrences(of: "Views.swift", with: "AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("if controller.presenting { log.log(\"brief held=presenting\"); return Presenting.briefLine }"), "what's my day")
        XCTAssertTrue(app.contains("guard !controller.presenting else { log.log(\"drop refused=presenting\"); return false }"), "file drops")
    }

    func testThePresentingStringsAreShortAndNameNoClient() {
        for t in [Presenting.notice, Presenting.briefLine, Presenting.menuTitle] {
            XCTAssertFalse(t.isEmpty); XCTAssertLessThan(t.count, 50)
        }
    }
}

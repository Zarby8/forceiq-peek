import Foundation
import XCTest
@testable import PeakCore

/// One-tap actions on the peek: Start (a meeting alert) opens Command's session page through the meeting card's Run, Review
/// (an approval alert) lands on that approval's description. Nothing else is ever done from the peek.
@MainActor final class PeekActionsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_418_400)
    func meetingCard() -> PeakCard {
        CardBuilder.meetingCards(MeetingRow(client: "Sample Skater", scheduledAt: t0.addingTimeInterval(9 * 60), durationMinutes: 60, joinURL: nil,
                                            openURL: CommandLink.room(sessionID: "demo_session"))).first!
    }
    func approvalCard(viewOnly: Bool = false) -> PeakCard {
        var s = EngineSnapshot()
        s.approvals = [ApprovalRow(id: "a1b2c3d4e5f6", kind: "proposal", kindLabel: "Claude proposal", title: "Confirm jersey", why: "x", client: "Sample Skater",
                                   gate: viewOnly ? "send" : "routine", touches: ["Messages"], outputs: [], actLabel: viewOnly ? "imessage" : "client_confirm", test: false)]
        return CardBuilder.fixAndApprovalCards(s).cards.first!
    }
    func controller(_ log: MemLog? = nil) -> PeakController {
        PeakController(prefs: PeakPrefs(stateRoot: tmpRoot()), profile: fixtureProfile("profile-coach-a"), hotkey: FakeHotkey(), logger: log)
    }

    // ── the policy attaches the action ──
    func testAMeetingAlertCarriesStartAndAnApprovalAlertCarriesReview() {
        var p = AlertPolicy()
        var s = EngineSnapshot(); s.liveAt = t0; s.approvalsAt = t0
        let m = meetingCard()
        let a = p.next(snapshot: s, cards: [m], context: AlertContext(now: t0))
        XCTAssertEqual(a?.kind, .meetingSoon); XCTAssertEqual(a?.action, .startMeeting); XCTAssertEqual(a?.cardID, m.id)
        XCTAssertEqual(a?.action.buttonTitle, "Start")
        var q = AlertPolicy()
        s.approvals = []
        _ = q.next(snapshot: s, cards: [], context: AlertContext(now: t0))
        let ap = approvalCard()
        s.approvals = [ApprovalRow(id: "a1b2c3d4e5f6", kind: "proposal", kindLabel: "x", title: "Confirm jersey", why: "x", client: "Sample Skater", gate: "routine",
                                   touches: [], outputs: [], actLabel: "client_confirm", test: false)]
        let b = q.next(snapshot: s, cards: [ap], context: AlertContext(now: t0.addingTimeInterval(60)))
        XCTAssertEqual(b?.kind, .approval); XCTAssertEqual(b?.action, .reviewApproval); XCTAssertEqual(b?.cardID, ap.id)
        XCTAssertEqual(b?.action.buttonTitle, "Review")
    }

    func testEveryOtherKindHasNoButton() {
        for k in [PeakAlertKind.fixFailed, .signInExpired, .family, .downloadDone] {
            let a = PeakAlert(id: "x", kind: k, client: "Demo Player", line: "Demo Player: x", holdSeconds: 1, cardID: "c", action: .startMeeting)
            XCTAssertNotNil(a.cardID)
        }
        XCTAssertEqual(PeakAlert(id: "x", kind: .meetingSoon, client: "A", line: "A in 9 min", holdSeconds: 1, action: .startMeeting).action, .none,
                       "an action needs a card to act on")
        XCTAssertNil(PeakAlertAction.none.buttonTitle)
    }

    func testAnActionlessAlertShowsNoButton() throws {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/PeekActionsTests.swift", with: "Sources/ForceIQPeak/Views.swift")
        let v = try String(contentsOfFile: path, encoding: .utf8)
        let inline = v.components(separatedBy: "struct PeekInline").last?.components(separatedBy: "/// The status wing's state").first ?? ""
        XCTAssertTrue(inline.contains("if let title = alert.action.buttonTitle"), "the button exists only when the alert has an action")
        XCTAssertTrue(inline.contains("Button(action: onAction)") && inline.contains("Color.black"), "black text on a brand-color capsule")
        XCTAssertEqual(inline.components(separatedBy: "actionButton\n").count - 1 + inline.components(separatedBy: "actionButton }").count - 1, 2,
                       "the button is in the notch layout and in the Studio Display pill layout")
        XCTAssertFalse(inline.contains("opacity") || inline.contains("gray") || inline.contains(".secondary"))
    }

    // ── presenting ──
    func testPresentingKeepsStartButDropsReview() {
        let start = Presenting.redact(PeakAlert(id: "m", kind: .meetingSoon, client: "Sample Skater", line: "Sample Skater in 9 min", holdSeconds: 1,
                                                plainLine: "A session in 9 min", cardID: "meeting:1", action: .startMeeting))
        XCTAssertEqual(start.action, .startMeeting); XCTAssertEqual(start.cardID, "meeting:1"); XCTAssertEqual(start.client, "")
        let review = Presenting.redact(PeakAlert(id: "a", kind: .approval, client: "Sample Skater", line: "Sample Skater: needs your OK", holdSeconds: 1,
                                                 cardID: "approval:a1b2c3d4e5f6", action: .reviewApproval))
        XCTAssertEqual(review.action, .none); XCTAssertNil(review.cardID)
    }

    // ── the controller ──
    func testTheButtonRetractsThePeekAndHandsTheAlertAndDisplayToTheApp() {
        let log = MemLog(); let c = controller(log)
        var got: (PeakAlert, String?)?
        c.onPeekAction = { got = ($0, $1) }
        let a = PeakAlert(id: "m", kind: .meetingSoon, client: "Sample Skater", line: "Sample Skater in 9 min", holdSeconds: 5, cardID: "meeting:1", action: .startMeeting)
        c.showPeek(a, on: "D2")
        c.performPeekAction()
        XCTAssertNil(c.peek); XCTAssertEqual(got?.0, a); XCTAssertEqual(got?.1, "D2")
        XCTAssertTrue(log.lines.contains("state peek-action=start-meeting"))
        XCTAssertFalse(log.lines.contains { $0.contains("Sample") }, "logs name the action, never the client")
    }

    func testAnAlertWithoutAnActionIgnoresTheButton() {
        let c = controller(); var calls = 0
        c.onPeekAction = { _, _ in calls += 1 }
        c.performPeekAction(); XCTAssertEqual(calls, 0, "no peek showing")
        c.showPeek(PeakAlert(id: "f", kind: .fixFailed, client: "Demo Player", line: "Demo Player: a fix failed", holdSeconds: 5), on: "D1")
        c.performPeekAction(); XCTAssertEqual(calls, 0); XCTAssertNotNil(c.peek, "nothing happened, so the peek stays until it retracts")
    }

    // ── Start = the meeting card's Run, once ──
    func testQuickStartRunsTheMeetingCardOnceAndLogsNoClient() async {
        let spy = SpyPerformer(); let log = MemLog()
        let vm = CardStackViewModel(performer: spy, logger: log)
        let ok = await vm.quickStart(meetingCard())
        XCTAssertTrue(ok); XCTAssertEqual(spy.performed, [.run])
        XCTAssertTrue(log.lines.contains("card quick-start kind=meeting")); XCTAssertFalse(log.lines.contains { $0.contains("Sample") })
    }

    func testQuickStartRefusesEverythingButAMeetingCard() async {
        let spy = SpyPerformer()
        let vm = CardStackViewModel(performer: spy)
        let a = await vm.quickStart(approvalCard()); XCTAssertFalse(a)
        let v = await vm.quickStart(approvalCard(viewOnly: true)); XCTAssertFalse(v)
        let viewOnlyMeeting = PeakCard(id: "meeting:x", kind: .meeting, client: "Sample Skater", title: "t", detail: "d",
                                       description: CardDescription(inputs: [], touches: [], outputs: []), viewOnly: true, viewOnlyReason: "no",
                                       actions: [.run], startsAt: t0)
        let m = await vm.quickStart(viewOnlyMeeting); XCTAssertFalse(m, "a view-only card never runs")
        XCTAssertEqual(spy.performed, [], "nothing was performed")
    }

    func testTheAppWiresStartToQuickStartAndReviewToTheDescription() throws {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/PeekActionsTests.swift", with: "Sources/ForceIQPeak/AppDelegate.swift")
        let app = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(app.contains("case .startMeeting: Task { @MainActor in await self.cards.quickStart(card) }"))
        XCTAssertTrue(app.contains("self.cards.tap(card); self.controller.tab = .home; self.controller.expand()"), "Review shows the description; Run stays a second tap")
        let block = app.components(separatedBy: "controller.onPeekAction = ").last?.components(separatedBy: "controller.onPeekOpen = ").first ?? ""
        XCTAssertFalse(block.contains("choose(") || block.contains("perform(.run"), "the peek never runs an approval")
    }
}

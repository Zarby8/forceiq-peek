import Foundation
import XCTest
@testable import PeakCore

/// Alert kinds beyond a meeting and a failed fix: Command's sign-in expiring, a new approval, a new family delivery, a shift
/// download finishing. Each is news only (the first read is the baseline), scoped to the coach's roster, redacted while presenting.
@MainActor final class MoreAlertsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_418_400)
    let mine: (String) -> Bool = { ["Sample Skater", "Demo Player"].contains($0) }
    func ctx(_ at: Double = 0) -> AlertContext { AlertContext(now: t0.addingTimeInterval(at), calendar: Calendar(identifier: .gregorian)) }

    func approval(_ id: String, _ client: String = "Sample Skater") -> ApprovalRow {
        ApprovalRow(id: id, kind: "proposal", kindLabel: "Claude proposal", title: "Confirm jersey", why: "x", client: client, gate: "routine",
                    touches: [], outputs: [], actLabel: "client_confirm", test: false)
    }
    func snap(approvals: [ApprovalRow] = [], approvalsKnown: Bool = true, done: [DownloadDone] = [], signIn: Bool = false, family: [FamilyRow] = [], familyOn: Bool = false) -> EngineSnapshot {
        var s = EngineSnapshot()
        s.approvals = approvals; s.approvalsAt = approvalsKnown ? t0 : nil
        s.downloadsDone = done; s.liveAt = t0
        s.commandSignIn = signIn ? CommandSignInNotice() : nil
        s.family = family; s.familyEnabled = familyOn
        return s
    }
    func cards(_ s: EngineSnapshot) -> [PeakCard] {
        (CardBuilder.fixAndApprovalCards(s).cards + CardBuilder.familyCards(s).cards).filter { mine($0.client) }   // the coach filter ModuleRegistry applies
    }
    func next(_ p: inout AlertPolicy, _ s: EngineSnapshot, at: Double = 0) -> PeakAlert? {
        p.next(snapshot: s, cards: cards(s), context: ctx(at), isMyClient: mine)
    }

    // ── approvals ──
    func testANewApprovalPeeksButTheOnesThereAtLaunchDoNot() {
        var p = AlertPolicy()
        XCTAssertNil(next(&p, snap(approvals: [approval("a1b2c3d4e5f6")])), "already waiting at launch: the baseline")
        let a = next(&p, snap(approvals: [approval("a1b2c3d4e5f6"), approval("0f9e8d7c6b5a", "Demo Player")]), at: 60)
        XCTAssertEqual(a?.kind, .approval); XCTAssertEqual(a?.lead, "Demo Player"); XCTAssertEqual(a?.trail, "needs your OK")
        XCTAssertNil(next(&p, snap(approvals: [approval("a1b2c3d4e5f6"), approval("0f9e8d7c6b5a", "Demo Player")]), at: 200), "once")
    }

    func testAnApprovalForAnotherCoachsClientNeverPeeks() {
        var p = AlertPolicy()
        _ = next(&p, snap())
        XCTAssertNil(next(&p, snap(approvals: [approval("a1b2c3d4e5f6", "Someone Else")]), at: 60), "no card exists for a client who isn't this coach's")
    }

    func testAFeedWithoutApprovalsNeverBaselinesThem() {
        var p = AlertPolicy()
        XCTAssertNil(next(&p, snap(approvals: [], approvalsKnown: false)))
        XCTAssertNil(next(&p, snap(approvals: [approval("a1b2c3d4e5f6")]), at: 60), "the first real read is the baseline, not an alert")
    }

    // ── shift downloads ──
    func testAFinishedShiftDownloadPeeksOnceForMyClientOnly() {
        var p = AlertPolicy()
        XCTAssertNil(next(&p, snap(done: [DownloadDone(id: "old.mp4", client: "Sample Skater")])), "finished before launch: baseline")
        let a = next(&p, snap(done: [DownloadDone(id: "old.mp4", client: "Sample Skater"), DownloadDone(id: "new.mp4", client: "Demo Player"),
                                    DownloadDone(id: "other.mp4", client: "Someone Else")]), at: 60)
        XCTAssertEqual(a?.kind, .downloadDone); XCTAssertEqual(a?.lead, "Demo Player"); XCTAssertEqual(a?.trail, "download finished")
        XCTAssertNil(next(&p, snap(done: [DownloadDone(id: "new.mp4", client: "Demo Player"), DownloadDone(id: "other.mp4", client: "Someone Else")]), at: 200))
    }

    // ── Command sign-in ──
    func testSignInExpiringAfterLaunchPeeksButAlreadyExpiredDoesNot() {
        var p = AlertPolicy()
        XCTAssertNil(next(&p, snap(signIn: true)), "expired at launch: the sheet already says so")
        XCTAssertNil(next(&p, snap(signIn: true), at: 60))
        _ = next(&p, snap(signIn: false), at: 120)
        let a = next(&p, snap(signIn: true), at: 180)
        XCTAssertEqual(a?.kind, .signInExpired); XCTAssertEqual(a?.lead, "Command sign-in"); XCTAssertEqual(a?.trail, "expired")
        XCTAssertEqual(a?.client, "", "it names Command, not a client")
    }

    func testAHeldSignInAlertIsNotSpentAndClearsIfSignedInAgain() {
        var p = AlertPolicy()
        _ = next(&p, snap(signIn: false))
        var held = AlertContext(now: t0.addingTimeInterval(60), dndUntil: t0.addingTimeInterval(3600), calendar: Calendar(identifier: .gregorian))
        XCTAssertNil(p.next(snapshot: snap(signIn: true), cards: [], context: held, isMyClient: mine))
        XCTAssertEqual(p.lastSuppression, .doNotDisturb)
        held.dndUntil = nil; held.now = t0.addingTimeInterval(120)
        XCTAssertEqual(p.next(snapshot: snap(signIn: true), cards: [], context: held, isMyClient: mine)?.kind, .signInExpired, "fires when DND lifts")
        var q = AlertPolicy()
        _ = next(&q, snap(signIn: false))
        _ = q.next(snapshot: snap(signIn: true), cards: [], context: AlertContext(now: t0.addingTimeInterval(60), dndUntil: t0.addingTimeInterval(3600), calendar: Calendar(identifier: .gregorian)), isMyClient: mine)
        XCTAssertNil(next(&q, snap(signIn: false), at: 90), "signed in again while held: nothing to say")
        XCTAssertNil(next(&q, snap(signIn: false), at: 200))
    }

    // ── family ──
    func testANewFamilyDeliveryAlertPeeksNamingTheClient() {
        var p = AlertPolicy()
        func fam(_ id: String) -> FamilyRow { FamilyRow(jobID: id, client: "Sample Skater", reason: "No link", link: nil, meetingDate: "2026-10-19") }
        XCTAssertNil(next(&p, snap(family: [fam("j1")], familyOn: true)))
        let a = next(&p, snap(family: [fam("j1"), fam("j2")], familyOn: true), at: 60)
        XCTAssertEqual(a?.kind, .family); XCTAssertEqual(a?.lead, "Sample Skater"); XCTAssertEqual(a?.trail, "family delivery needs you")
        XCTAssertNil(next(&p, snap(family: [], familyOn: false), at: 200), "family off: nothing")
    }

    // ── ordering, colors, presenting ──
    func testTheMostUrgentPeeksFirstAndTheRestWaitTheirTurn() {
        var p = AlertPolicy()
        _ = next(&p, snap())
        let s = snap(approvals: [approval("a1b2c3d4e5f6")], done: [DownloadDone(id: "n.mp4", client: "Demo Player")], signIn: true)
        XCTAssertEqual(next(&p, s, at: 60)?.kind, .signInExpired)
        XCTAssertNil(next(&p, s, at: 90), "cooldown")
        XCTAssertEqual(next(&p, s, at: 130)?.kind, .approval)
        XCTAssertEqual(next(&p, s, at: 200)?.kind, .downloadDone)
        XCTAssertNil(next(&p, s, at: 300))
    }

    func testDotColorsAreBrandGreenForGoodNewsAndGoldForNeedsYou() {
        XCTAssertEqual(PeakAlertKind.meetingSoon.dotHex, Brand.greenHex); XCTAssertEqual(PeakAlertKind.downloadDone.dotHex, Brand.greenHex)
        for k in [PeakAlertKind.fixFailed, .signInExpired, .approval, .family] { XCTAssertEqual(k.dotHex, Brand.goldHex) }
    }

    func testPresentingRedactsEveryKindToAPlainLine() {
        let kinds: [(PeakAlertKind, String)] = [(.approval, "Sample Skater: needs your OK"), (.family, "Sample Skater: family delivery needs you"),
                                                (.downloadDone, "Sample Skater: download finished"), (.fixFailed, "Sample Skater: a fix failed"),
                                                (.meetingSoon, "Sample Skater in 9 min")]
        for (k, line) in kinds {
            let r = Presenting.redact(PeakAlert(id: "x", kind: k, client: "Sample Skater", line: line, holdSeconds: 1))
            XCTAssertEqual(r.client, ""); XCTAssertFalse(r.lead.contains("Sample") || r.trail.contains("Sample"), "\(k)")
            XCTAssertFalse(r.line.isEmpty)
        }
        XCTAssertEqual(Presenting.redact(PeakAlert(id: "s", kind: .signInExpired, client: "", line: "Command sign-in expired", holdSeconds: 1)).line, "Command sign-in expired")
    }

    // ── parse ──
    func testTheLiveDocYieldsOnlyFinishedShiftDownloads() {
        let doc = #"{"fixes":[],"downloads":[{"what":"Shift download · Spiros Giannoulias · Mount St Charles · 10.17.2026","state":"done","file":"G_M_10.17.2026.mp4","at":"t"},{"what":"Shift download · Demo Player · Opp · 10.18.2026","state":"running"},{"what":"Livebarn · Demo Player vs Opp","state":"done","file":"lb.mp4"},{"what":"Shift download · ","state":"done"},{"what":"Shift download · Demo Player · Opp · 10.19.2026","state":"done","at":"2026-10-19T12:00:00Z"}],"counts":{"downloading":1}}"#
        let x = EngineParse.live(Data(doc.utf8))
        XCTAssertEqual(x.done.map(\.client), ["Spiros Giannoulias", "Demo Player"], "a running one, a provider grab and a nameless row are dropped")
        XCTAssertEqual(x.done.first?.id, "G_M_10.17.2026.mp4")
        XCTAssertTrue(x.done.last?.id.hasPrefix("Shift download · Demo Player") ?? false, "no file: id from what + time")
    }

    func testTheAppPassesTheRosterToThePolicy() throws {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/MoreAlertsTests.swift", with: "Sources/ForceIQPeak/AppDelegate.swift")
        let app = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(app.contains("isMyClient: { profile.isMyClient($0) }"))
    }
}

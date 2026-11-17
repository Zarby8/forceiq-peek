import Foundation
import XCTest
@testable import PeakCore

/// The one-thing brief: derived locally from the next-session feed only. Fake clients only
/// ("Sample Skater"); no engine, no network. Nothing here invents a regression or a clip.
final class SessionBriefTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_418_400)              // a fixed instant
    func session(today: Bool = true) -> NextSession {
        NextSession(client: "Sample Skater", scheduledAt: t0.addingTimeInterval(42 * 60), durationMinutes: 60,
                    sessionType: "Breakdown", today: today)
    }
    func since(_ lines: [String], state: String = "ok") -> SinceLastMet {
        SinceLastMet(state: state, lastMet: "2026-10-12", lines: lines, note: "")
    }
    var demoLines: [String] {
        ["Last met 2026-10-12.", "2 games since then.", "1 G, 1 A, 2 P since last met.",
         "Latest: 2026-10-18 vs Demo Wolves, L 1-3.", "Ghost score avg 7.2 since last met."]
    }

    func testNoSessionTodayMeansNoBrief() {
        XCTAssertNil(SessionBriefBuilder.build(session: session(today: false), since: since(demoLines)))
    }

    func testLossLatestIsTheHeadlineAndNamesTheFilm() {
        let b = SessionBriefBuilder.build(session: session(), since: since(demoLines))!
        XCTAssertEqual(b.client, "Sample Skater")
        XCTAssertTrue(b.headline.contains("lost 1-3 to Demo Wolves"), b.headline)
        XCTAssertTrue(b.headline.contains("what broke down"), b.headline)
        XCTAssertTrue(b.filmLine.contains("2026-10-18 vs Demo Wolves"), b.filmLine)
        XCTAssertTrue(b.filmLine.contains("FLOW"), b.filmLine)
        XCTAssertTrue(b.supportLines.contains("Ghost score avg 7.2 since last met."))
        XCTAssertTrue(b.supportLines.contains("1 G, 1 A, 2 P since last met."))
        XCTAssertTrue(b.needsEngineRoute)
        XCTAssertTrue(b.caveat.contains("session-brief engine route"), b.caveat)
    }

    func testWinLatestLeadsWithThatGame() {
        let lines = ["Last met 2026-10-12.", "2 games since then.", "3 G, 2 A, 5 P since last met.",
                     "Latest: 2026-10-18 vs Demo Wolves, W 4-1.", "Ghost score avg 8.1 since last met."]
        let b = SessionBriefBuilder.build(session: session(), since: since(lines))!
        XCTAssertTrue(b.headline.contains("Latest: 2026-10-18 vs Demo Wolves, W 4-1"), b.headline)
        XCTAssertTrue(b.filmLine.contains("2026-10-18 vs Demo Wolves"))
    }

    func testGhostAvgCarriesWhenThereIsNoLatestGame() {
        let lines = ["Last met 2026-10-12.", "2 games since then.", "Ghost score avg 7.9 since last met."]
        let b = SessionBriefBuilder.build(session: session(), since: since(lines))!
        XCTAssertTrue(b.headline.contains("Ghost score avg 7.9"), b.headline)
        XCTAssertTrue(b.filmLine.contains("No game since last met"), b.filmLine)
    }

    func testUnknownSinceSaysSoPlainly() {
        let b = SessionBriefBuilder.build(session: session(), since: since([], state: "unknown"))!
        XCTAssertTrue(b.headline.contains("No Ghost read"), b.headline)
        XCTAssertTrue(b.filmLine.contains("No game since last met"), b.filmLine)
        XCTAssertTrue(b.needsEngineRoute)
    }

    func testGarbledLinesAreIgnoredNeverGuessed() {
        let lines = ["Latest: someday vs ???", "Ghost score avg banana since last met.", "nonsense"]
        let b = SessionBriefBuilder.build(session: session(), since: since(lines))!
        XCTAssertFalse(b.headline.contains("banana"), b.headline)
        XCTAssertFalse(b.headline.contains("???"), b.headline)
        XCTAssertTrue(b.filmLine.contains("No game since last met"), b.filmLine)
    }

    // ── dedupe (Nov 17, 2026): the fact the headline spends never repeats in the
    // support lines — Christopher's screenshot showed the Latest line as the headline
    // AND as the last support line. Each fact appears once on the card. ──

    func testWinLatestAppearsOnceNotInSupport() {
        let lines = ["Last met 2026-10-12.", "2 games since then.", "3 G, 2 A, 5 P since last met.",
                     "Latest: 2026-10-18 vs Demo Wolves, W 4-1.", "Ghost score avg 8.1 since last met."]
        let b = SessionBriefBuilder.build(session: session(), since: since(lines))!
        XCTAssertTrue(b.headline.contains("Latest: 2026-10-18 vs Demo Wolves, W 4-1"), b.headline)
        XCTAssertTrue(b.supportLines.allSatisfy { !$0.hasPrefix("Latest:") }, "\(b.supportLines)")
        XCTAssertEqual(([b.headline] + b.supportLines).filter { $0.contains("W 4-1") }.count, 1)
        XCTAssertTrue(b.supportLines.contains("2 games since then."))
        XCTAssertTrue(b.supportLines.contains("Ghost score avg 8.1 since last met."))
    }

    func testLossLatestAppearsOnceNotInSupport() {
        let b = SessionBriefBuilder.build(session: session(), since: since(demoLines))!
        XCTAssertTrue(b.headline.contains("lost 1-3 to Demo Wolves"), b.headline)
        XCTAssertTrue(b.supportLines.allSatisfy { !$0.hasPrefix("Latest:") }, "\(b.supportLines)")
        // The date the loss headline drops still rides the film line — once.
        XCTAssertTrue(b.filmLine.contains("2026-10-18 vs Demo Wolves"), b.filmLine)
    }

    func testGhostAvgHeadlineDoesNotRepeatTheAvgInSupport() {
        let lines = ["Last met 2026-10-12.", "2 games since then.", "Ghost score avg 7.9 since last met."]
        let b = SessionBriefBuilder.build(session: session(), since: since(lines))!
        XCTAssertTrue(b.headline.contains("Ghost score avg 7.9"), b.headline)
        XCTAssertFalse(b.supportLines.contains("Ghost score avg 7.9 since last met."), "\(b.supportLines)")
        XCTAssertEqual(b.supportLines, ["2 games since then."])
    }

    func testPointsHeadlineDoesNotRepeatThePointsInSupport() {
        let lines = ["Last met 2026-10-12.", "2 games since then.", "1 G, 1 A, 2 P since last met."]
        let b = SessionBriefBuilder.build(session: session(), since: since(lines))!
        XCTAssertTrue(b.headline.contains("1 G, 1 A, 2 P since last met."), b.headline)
        XCTAssertFalse(b.supportLines.contains("1 G, 1 A, 2 P since last met."), "\(b.supportLines)")
        XCTAssertEqual(b.supportLines, ["2 games since then."])
    }
}

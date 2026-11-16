import Foundation
import XCTest
@testable import PeakCore

/// The Running section: upscales and meeting packs as Command reports them. Parsing, the words on each row, the model's polling
/// rules, and source-scan contracts for the view. Sample names only.
@MainActor final class RunningTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_418_400)
    let json = #"{"ok":true,"known":true,"items":[{"id":"u1","lane":"upscale","stage":"running","client":"Sample Skater","what":"Demo City Rockets · 4.17","step":"RIFE interpolation","percent":24.0,"detail":"100 / 400 frames","steps_done":11,"steps_total":20},{"id":"p1","lane":"post_meeting","stage":"attention","client":"Demo Player","what":"Meeting pack 10.20","step":"Waiting for Brain","percent":null,"detail":"","steps_done":5,"steps_total":6}]}"#

    // ── parsing ──
    func testParseReadsBothLanes() {
        let f = EngineParse.running(Data(json.utf8))
        XCTAssertEqual(f?.known, true); XCTAssertEqual(f?.rows.count, 2)
        XCTAssertEqual(f?.rows[0], RunningRow(id: "u1", lane: .upscale, stage: "running", client: "Sample Skater", what: "Demo City Rockets · 4.17",
                                              step: "RIFE interpolation", percent: 24, detail: "100 / 400 frames", stepsDone: 11, stepsTotal: 20))
        XCTAssertEqual(f?.rows[1].lane, .postMeeting); XCTAssertEqual(f?.rows[1].needsLook, true); XCTAssertNil(f?.rows[1].percent)
    }
    func testUnknownIsNotTheSameAsNothingRunning() {
        XCTAssertEqual(EngineParse.running(Data(#"{"ok":true,"known":false,"items":[]}"#.utf8)), RunningFeed(known: false))
        XCTAssertEqual(EngineParse.running(Data(#"{"ok":true,"known":true,"items":[]}"#.utf8)), RunningFeed(known: true, rows: []))
        XCTAssertNil(EngineParse.running(Data(#"{"ok":false,"known":false}"#.utf8))); XCTAssertNil(EngineParse.running(Data("nope".utf8)))
    }
    func testBadRowsAreDroppedAndPercentIsSane() {
        let j = #"{"ok":true,"known":true,"items":[{"id":"","lane":"upscale","stage":"running"},{"id":"x","lane":"download","stage":"running"},{"id":"a","lane":"upscale","stage":"running","percent":140},{"id":"b","lane":"upscale","stage":"running","percent":true},{"id":"c","lane":"upscale","stage":"running","percent":-5}]}"#
        let rows = EngineParse.running(Data(j.utf8))?.rows ?? []
        XCTAssertEqual(rows.map(\.id), ["a", "b", "c"]); XCTAssertEqual(rows[0].percent, 100); XCTAssertNil(rows[1].percent); XCTAssertEqual(rows[2].percent, 0)
    }

    // ── words ──
    func testTitleNamesTheClientAndTheGameAndFallsBackWithoutThem() {
        let r = EngineParse.running(Data(json.utf8))!.rows
        XCTAssertEqual(RunningText.title(r[0]), "Sample Skater · Demo City Rockets · 4.17")
        XCTAssertEqual(RunningText.title(r[1]), "Demo Player · Meeting pack 10.20")
        XCTAssertEqual(RunningText.title(RunningRow(id: "x", lane: .upscale, stage: "queued")), "Upscale")
        XCTAssertEqual(RunningText.title(RunningRow(id: "y", lane: .postMeeting, stage: "queued")), "Meeting pack")
    }
    func testStatusLineAndFootnote() {
        let r = EngineParse.running(Data(json.utf8))!.rows
        XCTAssertEqual(RunningText.status(r[0]), "RIFE interpolation"); XCTAssertEqual(RunningText.status(r[1]), "Needs a look · Waiting for Brain")
        XCTAssertEqual(RunningText.status(RunningRow(id: "q", lane: .upscale, stage: "queued", step: "GPU and NAS delivery")), "Queued · GPU and NAS delivery")
        XCTAssertEqual(RunningText.status(RunningRow(id: "w", lane: .postMeeting, stage: "waiting")), "Waiting")
        XCTAssertEqual(RunningText.footnote(r[0]), "100 / 400 frames · 11 of 20 steps"); XCTAssertEqual(RunningText.footnote(r[1]), "5 of 6 steps")
        XCTAssertNil(RunningText.footnote(RunningRow(id: "n", lane: .upscale, stage: "running")))
    }
    func testPercentText() {
        XCTAssertEqual(RunningText.percent(24), "24%"); XCTAssertEqual(RunningText.percent(100), "100%"); XCTAssertEqual(RunningText.percent(0), "0%")
        XCTAssertEqual(RunningText.percent(7.64), "7.6%"); XCTAssertEqual(RunningText.percent(9.96), "10%", "rounded to one decimal first"); XCTAssertEqual(RunningText.percent(24.4), "24%")
    }

    // ── the model ──
    func model(_ t: FakeTransport, enabled: Bool = true, _ log: MemLog = MemLog()) -> RunningModel { RunningModel(transport: t, enabled: enabled, logger: log) }
    func fake(_ code: Int = 200, _ body: String? = nil) -> FakeTransport {
        let t = FakeTransport(); t.answers[RunningModel.path] = (code, body ?? json); return t
    }
    func testTheFlagOffNeverAsks() async {
        let t = fake(); let m = model(t, enabled: false)
        let sent = await m.tick(expanded: true)
        XCTAssertFalse(sent); XCTAssertTrue(t.gets.isEmpty); XCTAssertNil(m.feed)
    }
    func testNearLiveWithTheSheetOpenAndSlowerClosed() async {
        let t = fake(); let m = model(t)
        _ = await m.tick(now: t0, expanded: true)
        let tooSoon = await m.tick(now: t0.addingTimeInterval(14), expanded: true), due = await m.tick(now: t0.addingTimeInterval(16), expanded: true)
        XCTAssertFalse(tooSoon); XCTAssertTrue(due); XCTAssertEqual(m.feed?.rows.count, 2)
        let closed = await m.tick(now: t0.addingTimeInterval(100), expanded: false)
        XCTAssertTrue(closed)
        let busy = await m.tick(now: t0.addingTimeInterval(159), expanded: false), busyDue = await m.tick(now: t0.addingTimeInterval(161), expanded: false)
        XCTAssertFalse(busy); XCTAssertTrue(busyDue, "closed with something running: about a minute")
    }
    func testClosedAndIdleReadsEveryTwoMinutes() async {
        let t = fake(200, #"{"ok":true,"known":true,"items":[]}"#); let m = model(t)
        _ = await m.tick(now: t0, expanded: false)
        let early = await m.tick(now: t0.addingTimeInterval(119), expanded: false), due = await m.tick(now: t0.addingTimeInterval(121), expanded: false)
        XCTAssertFalse(early); XCTAssertTrue(due)
    }
    func testOpeningTheSheetReadsRightAway() async {
        let t = fake(200, #"{"ok":true,"known":true,"items":[]}"#); let m = model(t)
        _ = await m.tick(now: t0, expanded: false)
        m.nudge()
        let again = await m.tick(now: t0.addingTimeInterval(5), expanded: true)
        XCTAssertTrue(again); XCTAssertEqual(t.gets.count, 2)
    }
    func testOneUnknownReadIsABlipTwoSaySo() async {
        let t = fake(200, #"{"ok":true,"known":false,"items":[]}"#); let m = model(t)
        _ = await m.tick(now: t0, expanded: true)
        XCTAssertNil(m.feed); XCTAssertFalse(m.unavailable)
        _ = await m.tick(now: t0.addingTimeInterval(20), expanded: true)
        XCTAssertTrue(m.unavailable)
        t.answers[RunningModel.path] = (200, json)
        _ = await m.tick(now: t0.addingTimeInterval(40), expanded: true)
        XCTAssertFalse(m.unavailable); XCTAssertEqual(m.feed?.rows.count, 2)
    }
    func testAnEngineWithoutTheFeedShowsNothingAndRetriesSlowly() async {
        let t = FakeTransport(); let m = model(t)                                  // unscripted: 404
        _ = await m.tick(now: t0, expanded: true)
        XCTAssertNil(m.feed); XCTAssertFalse(m.unavailable)
        let early = await m.tick(now: t0.addingTimeInterval(599), expanded: true), later = await m.tick(now: t0.addingTimeInterval(601), expanded: true)
        XCTAssertFalse(early); XCTAssertTrue(later)
    }
    func testForbiddenStopsForGood() async {
        let t = fake(403, "{}"); let m = model(t)
        _ = await m.tick(now: t0, expanded: true)
        let again = await m.tick(now: t0.addingTimeInterval(99_999), expanded: true)
        XCTAssertTrue(m.dead); XCTAssertFalse(again)
    }
    func testATransientFailureKeepsTheLastGoodRowsAndTheLogHasNoNames() async {
        let t = fake(); let log = MemLog(); let m = model(t, log)
        _ = await m.tick(now: t0, expanded: true)
        t.answers[RunningModel.path] = (502, "{}")
        _ = await m.tick(now: t0.addingTimeInterval(16), expanded: true)
        XCTAssertEqual(m.feed?.rows.count, 2, "a 502 is transient")
        XCTAssertEqual(log.lines.first, "running fetch code=200 upscale=1 packs=1")
        XCTAssertFalse(log.lines.joined().contains("Sample") || log.lines.joined().contains("Demo"))
    }

    // ── the view contract (source scans) ──
    func source(_ name: String) throws -> String { try XCTUnwrap(appSourceFiles().first { $0.name == name }).text }
    func body(_ s: String, from a: String, to b: String) throws -> String {
        let r0 = try XCTUnwrap(s.range(of: a), a), r1 = try XCTUnwrap(s.range(of: b, range: r0.upperBound..<s.endIndex), b)
        return String(s[r0.lowerBound..<r1.lowerBound])
    }
    func testTheSectionLivesOnTheHomeViewWhichPresentingReplaces() throws {
        let v = try source("Views.swift")
        let presenting = try XCTUnwrap(v.range(of: "if controller.presenting {"))
        let home = try XCTUnwrap(v.range(of: "PeekHomeScroll(nextSession: nextSession, running: running, cards: cards, checklist: checklist, agents: agents)"))
        XCTAssertLessThan(presenting.lowerBound, home.lowerBound, "the presenting notice is chosen before the home view")
        XCTAssertEqual(v.components(separatedBy: "PeekHomeScroll(").count - 1, 1)
        let list = try source("RunningViews.swift")
        let nudge = try XCTUnwrap(list.range(of: "NudgeSection(model: checklist)"))
        let grid = try XCTUnwrap(list.range(of: "ChecklistGrid(model: checklist)"))
        let brief = try XCTUnwrap(list.range(of: "SessionBriefCard(brief: brief)"))
        let section = try XCTUnwrap(list.range(of: "RunningSection(model: running)"))
        let cards = try XCTUnwrap(list.range(of: "CardList(cards: cards)"))
        XCTAssertLessThan(nudge.lowerBound, grid.lowerBound, "the nudge sits above the checklist")
        XCTAssertLessThan(grid.lowerBound, brief.lowerBound, "the checklist sits above the brief")
        XCTAssertLessThan(brief.lowerBound, section.lowerBound, "the brief sits above the running section")
        XCTAssertLessThan(section.lowerBound, cards.lowerBound, "running cards sit above the waiting cards")
        // Presenting keeps the checklist (stages and times only) but never the brief (it names the client).
        let presentingBody = try body(v, from: "if controller.presenting {", to: "} else if showChat {")
        XCTAssertTrue(presentingBody.contains("ChecklistGrid(model: checklist)"), "the checklist stays usable on a shared screen")
        XCTAssertTrue(presentingBody.contains("NudgeSection(model: checklist)"), "the nudge stays usable on a shared screen")
        XCTAssertFalse(presentingBody.contains("SessionBriefCard"), "the brief names the client: never while presenting")
    }
    func testTheRowsUseOnlyWhiteGoldAndGreenAndNameNothingAboutTheGPUBox() throws {
        let code = codeLines(try source("RunningViews.swift")).joined(separator: "\n")
        for banned in ["opacity(", "gray", "Gray", "secondary", "5090", "ssh", "watchdog", "nvidia"] { XCTAssertFalse(code.contains(banned), banned) }
        XCTAssertTrue(code.contains("foregroundStyle(Color.white)") && code.contains(".peakGold") && code.contains(".peakGreen"))
    }

    // ── overflow scrolling (the expanded running page Chris could not reach the bottom of) ──
    func testClippedRunningPageIsTallerThanTheExpandedViewport() {
        let page = PeekHomeOverflow.clippedRunningPage()
        XCTAssertEqual(page.feed.rows.count, 3)
        XCTAssertEqual(page.waitingRows, 2)
        XCTAssertTrue(page.showsPill)
        XCTAssertEqual(RunningText.title(page.feed.rows[0]), "Sample Skater · Demo City Rockets · 10.30")
        XCTAssertEqual(RunningText.title(page.feed.rows[1]), "Sample Skater")
        XCTAssertEqual(RunningText.title(page.feed.rows[2]), "Upscale")
        XCTAssertEqual(RunningText.status(page.feed.rows[0]), "RIFE interpolation")
        XCTAssertEqual(RunningText.status(page.feed.rows[2]), "Queued · Waiting for the GPU")
        let m = PeekHomeOverflow.measure(runningRows: page.feed.rows.count, waitingRows: page.waitingRows, showsPill: page.showsPill)
        XCTAssertGreaterThan(m.contentHeight, m.viewportHeight)
        XCTAssertTrue(m.overflows)
        XCTAssertTrue(m.scrollingEnabled)
        XCTAssertTrue(m.scrollbarAvailable)
        XCTAssertEqual(m.viewportHeight, PeekHomeOverflow.viewportHeight)
        XCTAssertLessThanOrEqual(PeekHomeOverflow.viewportHeight, Double(PeakGeometry().expandedSize.height))
    }
    func testAShortListDoesNotNeedToScroll() {
        let m = PeekHomeOverflow.measure(runningRows: 1, waitingRows: 0, showsPill: false)
        XCTAssertLessThanOrEqual(m.contentHeight, m.viewportHeight)
        XCTAssertFalse(m.overflows)
        XCTAssertFalse(m.scrollingEnabled)
    }
    func testTheHomeListIsAScrollViewWithAVisibleScrollbar() throws {
        let home = try body(try source("RunningViews.swift"), from: "struct PeekHomeScroll", to: "\nstruct RunningSection")
        XCTAssertTrue(home.contains("ScrollView(.vertical, showsIndicators: true)"), "vertical ScrollView; macOS scrollbar on")
        XCTAssertTrue(home.contains(".scrollIndicators(.visible)"), "scrollbar stays visible")
        XCTAssertFalse(home.contains(".scrollIndicators(.never)"), "a hidden indicator is not a visible scrollbar")
        XCTAssertTrue(home.contains("RunningSection(model: running)"))
        XCTAssertTrue(home.contains("CardList(cards: cards)"))
        let cards = try body(try source("Views.swift"), from: "struct CardList", to: "\nstruct CardRow")
        XCTAssertFalse(cards.contains("ScrollView"), "waiting cards live in PeekHomeScroll; a nested ScrollView would clip again")
        XCTAssertFalse(cards.contains(".scrollIndicators(.never)"))
        let v = try source("Views.swift")
        XCTAssertTrue(v.contains("PeekHomeScroll(nextSession: nextSession, running: running, cards: cards, checklist: checklist, agents: agents)"))
    }
}

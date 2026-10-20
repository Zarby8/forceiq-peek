import Foundation
import XCTest
@testable import PeakCore

/// "Pack ready" and "FLOW package ready": news only (a source or a client is baselined on its first good read), one alert for a
/// burst, never on an unknown source, scoped to the coach's roster, client-free while presenting. Sample names only.
@MainActor final class ReadyAlertTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_418_400)
    let mine: (String) -> Bool = { ["Sample Skater", "Demo Player", "Third Client"].contains($0) }
    let everyone = ["Sample Skater", "Demo Player", "Third Client"]
    func ctx(_ at: Double = 0, dnd: Double? = nil) -> AlertContext {
        AlertContext(now: t0.addingTimeInterval(at), dndUntil: dnd.map { t0.addingTimeInterval($0) }, calendar: Calendar(identifier: .gregorian))
    }
    func item(_ id: String, _ client: String) -> ReadyItem { ReadyItem(id: id, client: client) }
    func snap(_ r: ReadyFeed?) -> EngineSnapshot { var s = EngineSnapshot(); s.ready = r; s.liveAt = t0; return s }
    func feed(packs: [ReadyItem] = [], checked: [String]? = nil, known: Bool = true, flow: [ReadyItem]? = nil) -> ReadyFeed {
        ReadyFeed(packsKnown: known, packsChecked: checked ?? everyone, packs: packs, flowKnown: flow != nil, flow: flow ?? [])
    }
    func next(_ p: inout AlertPolicy, _ r: ReadyFeed?, at: Double = 0, dnd: Double? = nil) -> PeakAlert? {
        p.next(snapshot: snap(r), cards: [], context: ctx(at, dnd: dnd), isMyClient: mine)
    }

    // ── parsing ──
    func testParseReadsBothHalvesAndDropsRowsWithoutAnIDOrClient() {
        let j = #"{"ok":true,"packs":{"known":true,"checked":["Sample Skater"],"failed":1,"items":[{"id":"pack:a:1","client":"Sample Skater","date":"2026-10-17"},{"id":"","client":"Demo Player"},{"id":"pack:b:2","client":""}]},"flow":{"known":false,"items":[]}}"#
        let f = EngineParse.ready(Data(j.utf8))
        XCTAssertEqual(f?.packs, [item("pack:a:1", "Sample Skater")])
        XCTAssertEqual(f?.packsChecked, ["Sample Skater"]); XCTAssertEqual(f?.packsKnown, true); XCTAssertEqual(f?.flowKnown, false)
    }
    func testParseRefusesAFeedTheEngineCouldNotRead() {
        XCTAssertNil(EngineParse.ready(Data(#"{"ok":false,"error":"Couldn't read what is ready."}"#.utf8)))
        XCTAssertNil(EngineParse.ready(Data("not json".utf8)))
    }

    // ── packs ──
    func testANewPackPeeksOnceAndTheOnesThereAtLaunchDoNot() {
        var p = AlertPolicy()
        XCTAssertNil(next(&p, feed(packs: [item("pack:old", "Sample Skater")])), "published before Peek came up: the baseline")
        let a = next(&p, feed(packs: [item("pack:old", "Sample Skater"), item("pack:new", "Sample Skater")]), at: 61)
        XCTAssertEqual(a?.kind, .packReady); XCTAssertEqual(a?.lead, "Sample Skater"); XCTAssertEqual(a?.trail, "pack ready")
        XCTAssertNil(next(&p, feed(packs: [item("pack:old", "Sample Skater"), item("pack:new", "Sample Skater")]), at: 200), "once")
    }
    func testAClientWhoseReadFailedFirstIsBaselinedWhenItRecoversNotAlerted() {
        var p = AlertPolicy()
        XCTAssertNil(next(&p, feed(packs: [item("pack:a", "Sample Skater")], checked: ["Sample Skater"])), "Demo Player's read failed")
        XCTAssertNil(next(&p, feed(packs: [item("pack:a", "Sample Skater"), item("pack:b", "Demo Player")]), at: 61),
                     "Demo Player recovers with a pack that was already there: baseline, not news")
        let a = next(&p, feed(packs: [item("pack:a", "Sample Skater"), item("pack:b", "Demo Player"), item("pack:c", "Demo Player")]), at: 122)
        XCTAssertEqual(a?.lead, "Demo Player"); XCTAssertEqual(a?.kind, .packReady)
    }
    func testAnUnknownPacksSourceNeverBaselines() {
        var p = AlertPolicy()
        XCTAssertNil(next(&p, feed(packs: [], checked: [], known: false)), "no client could be read")
        XCTAssertNil(next(&p, nil), "no feed at all (flag off or an engine without it)")
        XCTAssertNil(next(&p, feed(packs: [item("pack:a", "Sample Skater")]), at: 61), "the first real read is the baseline")
    }
    func testABurstOfPacksPeeksOnceAndCountsThem() {
        var p = AlertPolicy()
        _ = next(&p, feed())
        let burst = [item("p1", "Sample Skater"), item("p2", "Sample Skater"), item("p3", "Sample Skater")]
        let a = next(&p, feed(packs: burst), at: 61)
        XCTAssertEqual(a?.line, "Sample Skater: 3 packs ready"); XCTAssertEqual(a?.plainLine, "3 packs are ready")
        XCTAssertNil(next(&p, feed(packs: burst), at: 200), "all three are spent, none peeks later")
        let many = burst + [item("p4", "Demo Player"), item("p5", "Third Client")]
        let b = next(&p, feed(packs: many), at: 400)
        XCTAssertEqual(b?.line.hasSuffix("+1 more: packs ready"), true, "two new clients: the newest and a count")
        XCTAssertEqual(b?.covers.count, 2)
        XCTAssertNil(next(&p, feed(packs: many), at: 600))
    }
    func testAPackForAnotherCoachsClientNeverPeeks() {
        var p = AlertPolicy()
        _ = next(&p, feed(checked: everyone + ["Someone Else"]))
        XCTAssertNil(next(&p, feed(packs: [item("pack:x", "Someone Else")], checked: everyone + ["Someone Else"]), at: 61))
    }
    func testAHeldPackAlertIsNotSpentAndPeeksWhenDoNotDisturbEnds() {
        var p = AlertPolicy()
        _ = next(&p, feed())
        let r = feed(packs: [item("pack:new", "Sample Skater")])
        XCTAssertNil(next(&p, r, at: 61, dnd: 3600)); XCTAssertEqual(p.lastSuppression, .doNotDisturb)
        XCTAssertEqual(next(&p, r, at: 4000)?.kind, .packReady, "DND over: the held alert fires, it was never spent")
    }

    // ── FLOW packages ──
    func testANewFlowPackagePeeksAndTheOnesThereAtLaunchDoNot() {
        var p = AlertPolicy()
        XCTAssertNil(next(&p, feed(flow: [item("flow:old", "Demo Player")])))
        let a = next(&p, feed(flow: [item("flow:old", "Demo Player"), item("flow:new", "Demo Player")]), at: 61)
        XCTAssertEqual(a?.kind, .flowReady); XCTAssertEqual(a?.lead, "Demo Player"); XCTAssertEqual(a?.trail, "FLOW package ready")
        XCTAssertEqual(a?.plainLine, "A FLOW package is ready")
    }
    func testAnUnknownFlowFolderNeverBaselinesAndNeverReadsAsEmpty() {
        var p = AlertPolicy()
        XCTAssertNil(next(&p, feed(flow: nil)), "folder missing or unreadable: unknown")
        XCTAssertNil(next(&p, feed(flow: [item("flow:a", "Demo Player")]), at: 61), "the first real listing is the baseline")
        XCTAssertNil(next(&p, feed(flow: nil), at: 122), "the folder goes away again: nothing, and nothing forgotten")
        XCTAssertNil(next(&p, feed(flow: [item("flow:a", "Demo Player")]), at: 183), "it comes back with the same package: not news")
    }
    func testFlowOutranksPacksWhenBothAreNew() {
        var p = AlertPolicy()
        _ = next(&p, feed(flow: []))
        let r = feed(packs: [item("pack:n", "Sample Skater")], flow: [item("flow:n", "Demo Player")])
        XCTAssertEqual(next(&p, r, at: 61)?.kind, .flowReady)
        XCTAssertEqual(next(&p, r, at: 130)?.kind, .packReady, "the pack follows once the cooldown passes")
    }

    // ── presenting + view contract ──
    func testPresentingHidesTheClientForBothKinds() {
        let pack = PeakAlert(id: "a", kind: .packReady, client: "Sample Skater", line: "Sample Skater: pack ready", holdSeconds: 6)
        let flow = PeakAlert(id: "b", kind: .flowReady, client: "Demo Player", line: "Demo Player: FLOW package ready", holdSeconds: 6)
        for a in [pack, flow] {
            let r = Presenting.redact(a)
            XCTAssertEqual(r.client, ""); XCTAssertEqual(r.line, a.plainLine)
            XCTAssertFalse(r.line.contains("Sample") || r.line.contains("Demo"))
        }
        XCTAssertEqual(PeakAlertKind.packReady.dotHex, Brand.greenHex); XCTAssertEqual(PeakAlertKind.flowReady.dotHex, Brand.greenHex)
    }
    func testBothKindsRankBelowEveryUrgentKind() {
        let urgent: [PeakAlertKind] = [.meetingSoon, .fixFailed, .signInExpired, .approval, .family, .downloadDone]
        for k in urgent { XCTAssertLessThan(k.priority, PeakAlertKind.flowReady.priority) }
        XCTAssertLessThan(PeakAlertKind.flowReady.priority, PeakAlertKind.packReady.priority)
    }

    // ── the model (cadence, flag, old engines) ──
    func model(_ t: FakeTransport, enabled: Bool = true, _ log: MemLog = MemLog()) -> ReadyModel { ReadyModel(transport: t, enabled: enabled, logger: log) }
    let okJSON = #"{"ok":true,"packs":{"known":true,"checked":["Sample Skater"],"failed":0,"items":[{"id":"pack:a","client":"Sample Skater"}]},"flow":{"known":true,"items":[]}}"#

    func testTheFlagOffNeverAsksTheEngine() async {
        let t = FakeTransport(); t.answers[ReadyModel.path] = (200, okJSON)
        let m = model(t, enabled: false)
        let sent = await m.tick(now: t0)
        XCTAssertFalse(sent); XCTAssertTrue(t.gets.isEmpty); XCTAssertNil(m.feed)
    }
    func testItReadsAtMostEveryTenMinutes() async {
        let t = FakeTransport(); t.answers[ReadyModel.path] = (200, okJSON)
        let m = model(t)
        let first = await m.tick(now: t0), soon = await m.tick(now: t0.addingTimeInterval(599)), due = await m.tick(now: t0.addingTimeInterval(601))
        XCTAssertTrue(first); XCTAssertFalse(soon); XCTAssertTrue(due)
        XCTAssertEqual(t.gets.count, 2); XCTAssertEqual(m.feed?.packs.count, 1)
    }
    func testAnEngineWithoutTheFeedLeavesNoFeedAndRetriesLater() async {
        let t = FakeTransport()                                       // unscripted path: 404
        let m = model(t)
        _ = await m.tick(now: t0)
        XCTAssertNil(m.feed)
        let early = await m.tick(now: t0.addingTimeInterval(1500)), later = await m.tick(now: t0.addingTimeInterval(1801))
        XCTAssertFalse(early); XCTAssertTrue(later)
    }
    func testAForbiddenAnswerStopsForGood() async {
        let t = FakeTransport(); t.answers[ReadyModel.path] = (403, "{}")
        let m = model(t)
        _ = await m.tick(now: t0)
        let again = await m.tick(now: t0.addingTimeInterval(99_999))
        XCTAssertTrue(m.dead); XCTAssertFalse(again)
    }
    func testAFailedReadKeepsTheLastGoodFeedAndTheLogHasNoNames() async {
        let t = FakeTransport(); t.answers[ReadyModel.path] = (200, okJSON)
        let log = MemLog(); let m = model(t, log)
        _ = await m.tick(now: t0)
        t.answers[ReadyModel.path] = (502, #"{"ok":false}"#)
        _ = await m.tick(now: t0.addingTimeInterval(601))
        XCTAssertEqual(m.feed?.packs.count, 1, "a 502 is transient: the last good read stands")
        XCTAssertEqual(log.lines.first, "ready fetch code=200 packs=1 checked=1 packs_known=yes flow=0 flow_known=yes")
        XCTAssertFalse(log.lines.joined().contains("Sample"))
    }

    // ── the preference ──
    func testReadyAlertsAreOnByDefaultAndOffWhenTheKeyIsFalse() {
        func prefs(_ body: String?) -> PeakPrefs {
            let r = tmpRoot()
            if let body { try! Data(body.utf8).write(to: r.appendingPathComponent("settings.json")) }
            return PeakPrefs(stateRoot: r)
        }
        XCTAssertTrue(prefs(nil).readyAlerts); XCTAssertTrue(prefs("{}").readyAlerts)
        XCTAssertFalse(prefs(#"{"readyAlerts": false}"#).readyAlerts)
        XCTAssertTrue(prefs("{ not json").readyAlerts, "an unreadable file is a notice, not a switch")
    }
}

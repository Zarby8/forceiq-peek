import Foundation
import XCTest
@testable import PeakCore

/// Next-session pill + gap warnings: flag, parsing, countdown, the three gaps, back-off, GET-only, actions, roster scoping,
/// brand and CPU guards. Fake clients only ("Sample Skater", "Demo Player", "Test Client Other"); no engine, no network.
@MainActor final class NextSessionTests: XCTestCase {
    let roster = ["Sample Skater", "Demo Player"]
    let t0 = Date(timeIntervalSince1970: 1_792_418_400)              // a fixed instant

    func feed(_ warnings: String = "[]", client: String = "Sample Skater", inMinutes: Double = 42, extra: String = "") -> String {
        let at = ISO8601DateFormatter().string(from: t0.addingTimeInterval(inMinutes * 60))
        return #"{"ok":true,"session":{"client":"\#(client)","scheduled_at":"\#(at)","duration_minutes":60,"session_type":"Breakdown","today":true},"since_last_met":{"state":"ok","last_met":"2026-10-12","lines":["Last met 2026-10-12.","2 games since then."],"note":""},"warnings":\#(warnings)\#(extra)}"#
    }
    func w(_ kind: String, _ state: String, _ client: String = "Sample Skater", note: String = "") -> String {
        #"{"kind":"\#(kind)","state":"\#(state)","client":"\#(client)","text":"\#(client): \#(kind) \#(state)","note":"\#(note)"}"#
    }
    func model(_ body: String = "", code: Int = 200, enabled: Bool = true) -> (NextSessionModel, FakeTransport, MemLog) {
        let t = FakeTransport(); t.answers[NextSessionModel.path] = (code, body.isEmpty ? feed() : body)
        let log = MemLog()
        return (NextSessionModel(transport: t, enabled: enabled, roster: roster, logger: log), t, log)
    }

    // ── the flag ──
    func testFlagDefaultsOffAndIsReadLeniently() {
        let r = tmpRoot()
        XCTAssertFalse(PeakPrefs(stateRoot: r).nextSessionPill, "no file: off")
        try! Data(#"{"nextSessionPill": true}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        XCTAssertTrue(PeakPrefs(stateRoot: r).nextSessionPill, "a partial file keeps the key")
        try! Data(#"{"commandMeetingLink": true, "nextSessionPill": null}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        XCTAssertFalse(PeakPrefs(stateRoot: r).nextSessionPill, "null = the default (off)")
        try! Data(#"{"nextSessionPill": "yes"}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        let bad = PeakPrefs(stateRoot: r)
        XCTAssertFalse(bad.nextSessionPill, "wrong type: fails closed (off)")
        XCTAssertTrue(bad.loadIssue?.contains("nextSessionPill") ?? false)
        XCTAssertTrue(PeakPrefs.Doc.CodingKeys.allCases.map(\.stringValue).contains("nextSessionPill"))
        XCTAssertFalse(NextSessionGate.enabled(setting: false)); XCTAssertTrue(NextSessionGate.enabled(setting: true))
    }

    func testFlagOffMeansNoFetchesEver() async {
        let (m, t, _) = model(enabled: false)
        for i in 0..<5 { let went = await m.tick(now: t0.addingTimeInterval(Double(i) * 3600)); XCTAssertFalse(went) }
        XCTAssertTrue(t.gets.isEmpty && t.posts.isEmpty)
        XCTAssertEqual(m.fetches, 0); XCTAssertFalse(m.showsPill); XCTAssertNil(m.pillText(now: t0))
        m.openCard(); XCTAssertFalse(m.showingCard)
    }

    // ── countdown + client named ──
    func testPillNamesTheClientAndCountsDown() async {
        let (m, t, _) = model()
        let went = await m.tick(now: t0)
        XCTAssertTrue(went); XCTAssertEqual(t.gets, [NextSessionModel.path])
        XCTAssertEqual(m.session?.client, "Sample Skater")
        XCTAssertEqual(m.pillText(now: t0), "Sample Skater in 42m")
        XCTAssertEqual(m.pillText(now: t0.addingTimeInterval(40 * 60)), "Sample Skater in 2m")
        XCTAssertEqual(m.pillText(now: t0.addingTimeInterval(41 * 60 + 30)), "Sample Skater now")
        XCTAssertEqual(m.pillText(now: t0.addingTimeInterval(47 * 60)), "Sample Skater started 5m ago")
        XCTAssertEqual(m.since?.state, "ok"); XCTAssertEqual(m.since?.lastMet, "2026-10-12"); XCTAssertEqual(m.since?.lines.count, 2)
    }

    func testCountdownText() {
        XCTAssertEqual(NextSessionCountdown.text(to: t0.addingTimeInterval(3 * 3600 + 5 * 60), now: t0), "in 3h 5m")
        XCTAssertEqual(NextSessionCountdown.text(to: t0.addingTimeInterval(26 * 3600), now: t0), "in 1d 2h")
        XCTAssertEqual(NextSessionCountdown.text(to: t0.addingTimeInterval(59), now: t0), "now")
        XCTAssertEqual(NextSessionCountdown.text(to: t0.addingTimeInterval(-20 * 60), now: t0), "started")
    }

    // ── the three gaps: present / absent / unknown ──
    func testEachGapPresentTurnsThePillGold() async {
        for k in GapKind.allCases {
            let (m, _, _) = model(feed("[\(w(k.rawValue, "present"))]"))
            await m.tick(now: t0)
            XCTAssertEqual(m.warnings.map(\.kind), [k]); XCTAssertEqual(m.warnings.first?.state, .present)
            XCTAssertTrue(m.gold, "\(k) present → gold")
            XCTAssertEqual(m.warnings.first?.client, "Sample Skater")
        }
    }

    func testEachGapAbsentIsNoWarningAndNoGold() async {
        let (m, _, _) = model(feed("[\(GapKind.allCases.map { w($0.rawValue, "absent") }.joined(separator: ","))]"))
        await m.tick(now: t0)
        XCTAssertTrue(m.warnings.isEmpty); XCTAssertFalse(m.gold); XCTAssertTrue(m.showsPill)
    }

    func testEachGapUnknownIsListedWithItsNoteButNotGold() async {
        let note = "Unknown: Command has no read endpoint for breakdown exports yet"
        let (m, _, _) = model(feed("[\(GapKind.allCases.map { w($0.rawValue, "unknown", note: note) }.joined(separator: ","))]"))
        await m.tick(now: t0)
        XCTAssertEqual(m.warnings.count, 3); XCTAssertTrue(m.warnings.allSatisfy { $0.state == .unknown && $0.note == note })
        XCTAssertFalse(m.gold, "unknown alone keeps the pill green")
    }

    func testUnpaidBoundaryTextComesThroughAsIs() async {
        let body = feed(#"[{"kind":"invoice_unpaid","state":"present","client":"Demo Player","text":"Demo Player: invoice unpaid 7 days ($400.00)","note":""}]"#)
        let (m, _, _) = model(body)
        await m.tick(now: t0)
        XCTAssertEqual(m.warnings.first?.text, "Demo Player: invoice unpaid 7 days ($400.00)"); XCTAssertTrue(m.gold)
    }

    func testWarningsWithoutAClientOrUnknownKindAreDropped() {
        let body = feed(#"[{"kind":"invoice_unpaid","state":"present","client":"","text":"x","note":""},{"kind":"refund","state":"present","client":"Sample Skater","text":"y","note":""}]"#)
        guard case let .loaded(_, _, ws) = NextSessionResult.parse(200, Data(body.utf8)) else { return XCTFail() }
        XCTAssertTrue(ws.isEmpty)
    }

    // ── roster scoping ──
    func testRosterScopingDropsOtherCoachesClients() async {
        let (m, _, _) = model(feed("[\(w("invoice_unpaid", "present", "Test Client Other")),\(w("invoice_unpaid", "present", "Demo Player"))]"))
        await m.tick(now: t0)
        XCTAssertEqual(m.warnings.map(\.client), ["Demo Player"])
        let (o, _, _) = model(feed("[]", client: "Test Client Other"))
        await o.tick(now: t0)
        XCTAssertNil(o.session); XCTAssertFalse(o.showsPill); XCTAssertNil(o.since)
    }

    // ── back-off: 401 / 403 / dead / failures, and the 5-minute poll ──
    func testPollsAtMostEveryFiveMinutes() async {
        let (m, t, _) = model()
        var went = await m.tick(now: t0); XCTAssertTrue(went)
        went = await m.tick(now: t0.addingTimeInterval(30)); XCTAssertFalse(went)
        went = await m.tick(now: t0.addingTimeInterval(299)); XCTAssertFalse(went)
        went = await m.tick(now: t0.addingTimeInterval(300)); XCTAssertTrue(went)
        XCTAssertEqual(t.gets.count, 2)
        XCTAssertEqual(NextSessionModel.pollInterval, 300)
    }

    func test401AndDeadSessionShowTheSignInStateAndWaitThirtyMinutes() async {
        for (code, body) in [(401, "{}"), (200, #"{"ok":false,"auth":"expired","error":"Command sign-in expired, tap to sign in","signin":{"act":"command_signin","label":"Sign in to Command"}}"#)] {
            let (m, t, _) = model(body, code: code)
            await m.tick(now: t0)
            guard case .signedOut = m.result else { return XCTFail("\(code)") }
            XCTAssertFalse(m.showsPill)
            var went = await m.tick(now: t0.addingTimeInterval(1799)); XCTAssertFalse(went)
            went = await m.tick(now: t0.addingTimeInterval(1800)); XCTAssertTrue(went)
            XCTAssertEqual(t.gets.count, 2)
        }
    }

    func test403IsDeadForThisRun() async {
        let (m, t, _) = model(#"{"ok":false,"auth":"forbidden","error":"This Command sign-in can't read the schedule."}"#)
        await m.tick(now: t0)
        guard case .forbidden = m.result else { return XCTFail() }
        XCTAssertTrue(m.dead)
        for h in 1...6 { let went = await m.tick(now: t0.addingTimeInterval(Double(h) * 3600)); XCTAssertFalse(went) }
        XCTAssertEqual(t.gets.count, 1)
    }

    func testFailuresAndMissingRouteWaitTheNormalInterval() async {
        for (code, body) in [(502, #"{"ok":false,"error":"Couldn't read the next session."}"#), (404, ""), (0, "")] {
            let (m, t, _) = model(body.isEmpty ? "{}" : body, code: code)
            await m.tick(now: t0)
            guard case .failed = m.result else { return XCTFail("\(code)") }
            let went = await m.tick(now: t0.addingTimeInterval(60)); XCTAssertFalse(went)
            XCTAssertEqual(t.gets.count, 1)
        }
    }

    // ── read-only: GET only, two clipboard actions ──
    func testOnlyGetsNeverAPostOrStream() async {
        let (m, t, _) = model(feed("[\(w("invoice_missing", "present"))]"))
        m.onCopy = { _ in }
        await m.tick(now: t0)
        m.openCard()
        for a in NextSessionAction.allCases { m.perform(a, on: m.warnings[0]) }
        await m.tick(now: t0.addingTimeInterval(600))
        XCTAssertTrue(t.posts.isEmpty, "no POST and no 3PO stream, ever")
        XCTAssertEqual(Set(t.gets), [NextSessionModel.path])
    }

    func testActionsAreOnlyAskTRONAndCopyAndBothOnlyCopy() async {
        XCTAssertEqual(NextSessionAction.allCases, [.askTRON, .copy])
        XCTAssertEqual(GapWarning.actions.map(\.label), ["Ask TRON", "Copy"])
        let (m, _, log) = model(feed("[\(w("invoice_missing", "present")),\(w("export_missing", "unknown", note: "Unknown: no endpoint"))]"))
        var copied: [String] = []
        m.onCopy = { copied.append($0) }
        await m.tick(now: t0)
        for x in m.warnings { XCTAssertEqual(x.actions, [.askTRON, .copy]) }
        let r1 = m.perform(.askTRON, on: m.warnings[0])
        XCTAssertTrue(r1.contains("nothing was sent"))
        XCTAssertTrue(copied[0].hasPrefix("TRON,") && copied[0].contains("Client: Sample Skater") && copied[0].contains("Don't contact the family"))
        let r2 = m.perform(.copy, on: m.warnings[1])
        XCTAssertTrue(r2.contains("Nothing was sent")); XCTAssertEqual(copied[1], "Sample Skater: export_missing unknown. Unknown: no endpoint")
        let stale = GapWarning(kind: .invoiceUnpaid, state: .present, client: "Test Client Other", text: "x", note: "")
        XCTAssertEqual(m.perform(.copy, on: stale), "Not available."); XCTAssertEqual(copied.count, 2)
        XCTAssertTrue(log.lines.contains("next-session action=ask-tron kind=invoice_missing state=present"))
    }

    func testCardOpensOnlyWithASessionAndClosesOnAuthLoss() async {
        let (m, t, _) = model()
        await m.tick(now: t0)
        m.openCard(); XCTAssertTrue(m.showingCard)
        t.answers[NextSessionModel.path] = (401, "{}")
        await m.tick(now: t0.addingTimeInterval(300))
        XCTAssertFalse(m.showingCard)
    }

    // ── logs: counts and states only ──
    func testLogsCarryNoNames() async {
        let (m, _, log) = model(feed("[\(w("invoice_missing", "present")),\(w("invoice_unpaid", "present", "Demo Player"))]"))
        m.onCopy = { _ in }
        await m.tick(now: t0)
        m.openCard(); m.perform(.askTRON, on: m.warnings[0])
        XCTAssertTrue(log.lines.contains("next-session outcome=ok session=yes gaps=2 unknown=0 gold=yes fetches=1"))
        let all = log.lines.joined(separator: "\n")
        for bad in ["Sample", "Skater", "Demo Player", "2026-10-12"] { XCTAssertFalse(all.contains(bad), bad) }
    }

    // ── brand + CPU guards ──
    func testStyleUsesBrandTokensOnly() {
        XCTAssertEqual(NextSessionStyle.goldHex, Brand.goldHex)
        XCTAssertEqual(NextSessionStyle.okHex, Brand.greenHex)
        XCTAssertEqual(NextSessionStyle.textHex, Brand.whiteHex)
        XCTAssertEqual(NextSessionStyle.textOpacity, 1)
        XCTAssertEqual(NextSessionStyle.outlineHex(gold: true), Brand.goldHex)
        XCTAssertTrue(Brand.allowedTextHex.contains(NextSessionStyle.textHex))
        XCTAssertEqual(NextSessionStyle.tickSeconds, 30, "a coarse local countdown (the views use the literal 30)")
    }

    func testViewsHaveNoHexNoDimNoLoopsAndGlowOnlyOnShapes() throws {
        let v = codeLines(try XCTUnwrap(appSourceFiles().first { $0.name == "NextSessionViews.swift" }).text)
        let core = codeLines(try String(contentsOf: appSources.deletingLastPathComponent().appendingPathComponent("PeakCore/NextSession.swift"), encoding: .utf8))
        for (i, l) in (v + core).enumerated() {
            XCTAssertNil(l.range(of: #"0x[0-9A-Fa-f]{6}|#[0-9A-Fa-f]{6}\b|Color\(red:"#, options: .regularExpression), "line \(i + 1): a hex colour; use the brand token")
        }
        for (i, l) in v.enumerated() {
            for bad in [".opacity(", "repeatForever", "Timer.", "displayLink", "phaseAnimator", "TimelineView(.animation", "Color.gray", ".secondary"] {
                XCTAssertFalse(l.contains(bad), "NextSessionViews.swift:\(i + 1): \(bad)")
            }
            if l.contains(".shadow(") { XCTAssertFalse(l.contains("Text("), "NextSessionViews.swift:\(i + 1): a glow on text") }
            if l.contains("TimelineView(.periodic") { XCTAssertTrue(l.contains("by: 30)"), "the countdown ticks at the coarse rate (NextSessionStyle.tickSeconds)") }
        }
        let shadows = v.filter { $0.contains(".shadow(") }
        XCTAssertEqual(shadows.count, 2, "the pill's capsule and the notch dot: shapes only")
        let joined = v.joined(separator: "\n")
        XCTAssertFalse(joined.contains("Button(action") || joined.contains("Toggle(") || joined.contains("Link("), "only PeakButton (Ask TRON / Copy / Back)")
    }

    func testCardOffersNoRunAndNoSendPaths() throws {
        let v = codeLines(try XCTUnwrap(appSourceFiles().first { $0.name == "NextSessionViews.swift" }).text).joined(separator: "\n")
        for bad in ["engine.post", ".post(", "NSWorkspace", "openURL", "choose(.run)", "act(", "Run\""] { XCTAssertFalse(v.contains(bad), bad) }
        XCTAssertTrue(v.contains("ForEach(w.actions, id: \\.self)"), "the buttons are exactly the warning's actions")
        let core = try String(contentsOf: appSources.deletingLastPathComponent().appendingPathComponent("PeakCore/NextSession.swift"), encoding: .utf8)
        let code = codeLines(core).joined(separator: "\n")
        XCTAssertFalse(code.contains("transport.post") || code.contains("transport.stream"), "the model only GETs")
    }

    func testAppPollsOnlyFromTheExistingRefreshTick() throws {
        let a = codeLines(try XCTUnwrap(appSourceFiles().first { $0.name == "AppDelegate.swift" }).text).joined(separator: "\n")
        XCTAssertEqual(a.components(separatedBy: "Timer.scheduledTimer").count - 1, 1, "no new timer: the existing 30 s refresh drives the 5-min poll")
        XCTAssertTrue(a.contains("NextSessionGate.enabled(setting: prefs.nextSessionPill)"))
        XCTAssertTrue(a.contains("if self.demo { self.demoClipboard = s } else { self.performer.copy(s) }"))
        XCTAssertFalse(a.contains("nextSessionPill ="), "no app-side setter: the flag has no UI")
    }

    func testDemoFeedUsesFakeNamesOnly() {
        guard case let .loaded(s, _, ws) = NextSessionResult.parse(200, Data(DemoData.nextSessionJSON(now: t0).utf8)) else { return XCTFail() }
        let names = Set([s?.client].compactMap { $0} + ws.map(\.client))
        XCTAssertTrue(names.isSubset(of: ["Sample Skater", "Demo Player", "Test Client Other"]), "\(names)")
        XCTAssertEqual(Set(ws.map(\.kind)), Set(GapKind.allCases))
    }
}

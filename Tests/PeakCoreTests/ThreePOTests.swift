import CoreGraphics
import Foundation
import XCTest
@testable import PeakCore

/// A fake engine: records every POST; answers scripted.
final class FakeTransport: ThreePOTransport, @unchecked Sendable {
    var events: [ThreePOEvent] = []
    var posts: [(String, [String: Any])] = []
    var gets: [String] = []
    var answers: [String: (Int, String)] = [:]
    func stream(_ body: Data) -> AsyncStream<ThreePOEvent> {
        let ev = events
        posts.append(("/api/3po/stream", (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]))
        return AsyncStream { c in for e in ev { c.yield(e) }; c.finish() }
    }
    func get(_ path: String) async -> (Int, Data) {
        gets.append(path)
        let a = answers[path] ?? (404, "{}"); return (a.0, Data(a.1.utf8))
    }
    func post(_ path: String, _ body: Data) async -> (Int, Data) {
        posts.append((path, (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]))
        let a = answers[path] ?? (200, #"{"ok":true}"#); return (a.0, Data(a.1.utf8))
    }
}

func proposalJSON(action: String = "rerender", viewOnly: Bool = false, run: Bool = true) -> [String: Any] {
    var o: [String: Any] = ["id": "abc123abc123", "action": action, "label": "Re-render", "client": "Sample Skater",
                            "inputs": ["text": "Sample Skater vs Demo"], "touches": "title folder", "outputs": ["title.png"],
                            "reason": "wrong crest", "message": "Nothing has run.", "status": "proposed", "view_only": viewOnly, "executed": false]
    if run { o["run"] = ["method": "POST", "route": "/api/act", "preview": ["name": action, "args": [:]], "confirm": ["name": action, "args": [:], "confirm": true]] }
    return o
}

final class SSETests: XCTestCase {
    func testParsesFramesAcrossChunkBoundaries() {
        var p = SSEParser()
        XCTAssertTrue(p.feed(Data("event: delta\ndata: {\"type\":\"del".utf8)).isEmpty)
        let f = p.feed(Data("ta\",\"text\":\"Hi\"}\n\n: comment\n\nevent: done\r\ndata: {\"type\":\"done\"}\r\n\r\n".utf8))
        XCTAssertEqual(f.map(\.event), ["delta", "done"])
        XCTAssertEqual(ThreePOEvent.decode(event: f[0].event, data: f[0].data), .delta("Hi"))
    }

    func testDecodesTheContractEvents() {
        XCTAssertEqual(ThreePOEvent.decode(event: "start", data: #"{"type":"start","route":"claude","model_alias":"haiku","mode":"advisor","cache":{"breakpoints":[1,2]}}"#),
                       .start(route: "claude", modelAlias: "haiku", mode: "advisor", cached: true))
        XCTAssertEqual(ThreePOEvent.decode(event: "advisor", data: #"{"type":"advisor","state":"consulting"}"#), .advisor(consulting: true))
        XCTAssertEqual(ThreePOEvent.decode(event: "advisor", data: #"{"type":"advisor","state":"done"}"#), .advisor(consulting: false))
        XCTAssertEqual(ThreePOEvent.decode(event: "error", data: #"{"type":"error","code":"auth_error","message":"x"}"#), .error(code: "auth_error", message: "x"))
        if case .done(_, let cost, let mtd, let warn, let ft) = ThreePOEvent.decode(event: "done", data: #"{"type":"done","text":"ok","usage":{"lines":[],"cost_usd":0.01},"spend":{"peak_mtd_usd":201.5,"warn":true},"first_token_ms":420}"#) {
            XCTAssertEqual(cost, 0.01); XCTAssertEqual(mtd, 201.5); XCTAssertEqual(warn, true); XCTAssertEqual(ft, 420)
        } else { XCTFail("done") }
        XCTAssertEqual(ThreePOEvent.decode(event: "x", data: "not json"), .unknown)
    }
}

final class ProposalPolicyTests: XCTestCase {
    func testRoutineProposalCarriesPreviewThenConfirm() {
        let c = ProposalPolicy.card(from: proposalJSON())!
        XCTAssertFalse(c.viewOnly)
        let pv = try! JSONSerialization.jsonObject(with: c.previewBody!) as! [String: Any]
        let cf = try! JSONSerialization.jsonObject(with: c.confirmBody!) as! [String: Any]
        XCTAssertNil(pv["confirm"]); XCTAssertEqual(cf["confirm"] as? Bool, true)
    }

    func testDangerousActionsAreViewOnlyWhateverTheEngineSays() {
        for a in ["send_email", "imessage_text", "delete_clip", "invoice_create", "book_session", "db_update", "deploy_app", "publish_video"] {
            let c = ProposalPolicy.card(from: proposalJSON(action: a))!
            XCTAssertTrue(c.viewOnly, a); XCTAssertNil(c.previewBody, a); XCTAssertNil(c.confirmBody, a)
        }
    }

    func testNoRunRouteOrWrongRouteIsViewOnly() {
        XCTAssertTrue(ProposalPolicy.card(from: proposalJSON(run: false))!.viewOnly)
        var o = proposalJSON(); o["run"] = ["route": "/api/run", "preview": ["name": "rerender"], "confirm": ["name": "rerender", "confirm": true]]
        XCTAssertTrue(ProposalPolicy.card(from: o)!.viewOnly)
        XCTAssertTrue(ProposalPolicy.card(from: proposalJSON(viewOnly: true))!.viewOnly)
    }
}

@MainActor final class ThreePOStoreTests: XCTestCase {
    func testStreamFillsTranscriptAndPulsesOpus() async {
        let t = FakeTransport()
        t.events = [.start(route: "claude", modelAlias: "haiku", mode: "advisor", cached: true), .advisor(consulting: true),
                    .advisor(consulting: false), .delta("Hello "), .delta("coach"),
                    .proposal(ProposalPolicy.card(from: proposalJSON())!),
                    .done(text: "", costUSD: 0.002, peakMTD: 10, warn: false, firstTokenMs: 300)]
        let s = ThreePOStore(transport: t)
        s.draft = "why is the title wrong"
        await s.send()
        let m = s.transcript.messages
        XCTAssertEqual(m.count, 2); XCTAssertEqual(m[1].text, "Hello coach")
        XCTAssertTrue(m[1].consultedOpus); XCTAssertEqual(s.transcript.opusPulses, 1); XCTAssertTrue(m[1].cached)
        XCTAssertFalse(s.transcript.streaming); XCTAssertFalse(s.transcript.thinking)
        XCTAssertEqual(s.phases["abc123abc123"], .described)
        XCTAssertEqual(t.posts.map(\.0), ["/api/3po/stream"])              // a proposal arriving never posts anything
        XCTAssertEqual(s.transcript.spend.peak?.totalUSD, 10)
    }

    func testRunIsPreviewThenConfirmOnlyOnSecondTap() async {
        let t = FakeTransport()
        t.events = [.proposal(ProposalPolicy.card(from: proposalJSON())!), .done(text: "", costUSD: 0, peakMTD: nil, warn: nil, firstTokenMs: nil)]
        let s = ThreePOStore(transport: t); s.draft = "x"; await s.send()
        await s.confirm("abc123abc123")                                     // confirm before preview: nothing
        XCTAssertEqual(t.posts.filter { $0.0 == "/api/act" }.count, 0)
        await s.run("abc123abc123")
        XCTAssertEqual(t.posts.last?.0, "/api/act"); XCTAssertNil(t.posts.last?.1["confirm"])
        if case .previewed = s.phases["abc123abc123"] {} else { XCTFail("previewed") }
        await s.confirm("abc123abc123")
        XCTAssertEqual(t.posts.last?.1["confirm"] as? Bool, true)
        XCTAssertEqual(s.approvedPops, 1)
    }

    func testViewOnlyProposalNeverPosts() async {
        let t = FakeTransport()
        t.events = [.proposal(ProposalPolicy.card(from: proposalJSON(action: "send_email"))!), .done(text: "", costUSD: 0, peakMTD: nil, warn: nil, firstTokenMs: nil)]
        let s = ThreePOStore(transport: t); s.draft = "x"; await s.send()
        await s.run("abc123abc123"); await s.confirm("abc123abc123")
        XCTAssertTrue(t.posts.allSatisfy { $0.0 == "/api/3po/stream" })
    }

    func testModelPicksAndUnavailableRefused() async {
        let t = FakeTransport()
        t.answers["/api/3po/models"] = (200, #"{"pick":"auto","models":[{"alias":"haiku","label":"Haiku 5.5","available":true},{"alias":"sonnet","label":"Sonnet 5.5","available":true},{"alias":"opus","label":"Opus 5.5","available":false,"reason":"not on this key"}]}"#)
        let s = ThreePOStore(transport: t)
        await s.loadModels()
        XCTAssertEqual(s.transcript.models.rows.map(\.pick), [.auto, .haiku, .sonnet, .opus])
        XCTAssertEqual(ModelPick.forDigit("1"), .haiku); XCTAssertEqual(ModelPick.forDigit("2"), .sonnet); XCTAssertEqual(ModelPick.forDigit("3"), .opus)
        await s.choose(.opus)
        XCTAssertEqual(s.pick, .auto); XCTAssertFalse(t.posts.contains { $0.0 == "/api/3po/model" })
        await s.choose(.sonnet)
        XCTAssertEqual(s.pick, .sonnet); XCTAssertEqual(t.posts.last?.1["pick"] as? String, "sonnet")
        s.draft = "hi"; await s.send()
        XCTAssertEqual(t.posts.last?.1["model"] as? String, "sonnet")
    }

    func testSpendAsksAtMostOncePerMinute() async {
        let t = FakeTransport()
        t.answers["/api/3po/spend"] = (200, #"{"budget_usd":250,"warn_at":0.8,"show_account_line":false,"account":null,"peak":{"total_usd":5,"warn":false}}"#)
        let s = ThreePOStore(transport: t)
        let now = Date()
        await s.refreshSpend(now: now); await s.refreshSpend(now: now.addingTimeInterval(30))
        XCTAssertEqual(t.gets.filter { $0 == "/api/3po/spend" }.count, 1)
        await s.refreshSpend(now: now.addingTimeInterval(61))
        XCTAssertEqual(t.gets.filter { $0 == "/api/3po/spend" }.count, 2)
    }

    func testStreamThatEndsWithoutDoneSaysNothingRan() async {
        let t = FakeTransport(); t.events = [.start(route: "claude", modelAlias: "haiku", mode: "solo", cached: false)]
        let s = ThreePOStore(transport: t); s.draft = "x"; await s.send()
        XCTAssertFalse(s.transcript.streaming); XCTAssertNotNil(s.transcript.messages.last?.error)
    }
}

final class SpendTests: XCTestCase {
    func testAccountLineHiddenUnlessFlag() {
        let off = SpendDoc.parse(Data(#"{"budget_usd":250,"show_account_line":false,"account":null,"peak":{"total_usd":12,"warn":false},"hint":null}"#.utf8))!
        XCTAssertEqual(off.accountState, .hidden)
        let hint = SpendDoc.parse(Data(#"{"budget_usd":250,"show_account_line":true,"account":null,"peak":{"total_usd":12},"hint":"Add an Anthropic admin key to see full account spend."}"#.utf8))!
        XCTAssertEqual(hint.accountState, .hint("Add an Anthropic admin key to see full account spend."))
        // flag on, key fine but the cost report failed for another reason: the engine sends no hint, so the line hides
        let other = SpendDoc.parse(Data(#"{"budget_usd":250,"show_account_line":true,"account":null,"peak":{"total_usd":12},"hint":null,"account_status":500}"#.utf8))!
        XCTAssertEqual(other.accountState, .hidden)
    }

    func testAccountSplitByFamilyAndGoldAt80Percent() {
        let d = SpendDoc.parse(Data(#"{"budget_usd":250,"warn_at":0.8,"show_account_line":true,"account":{"total_usd":201,"by_model":{"opus":100,"sonnet":60,"haiku":30,"web_search":11}},"peak":{"total_usd":20,"by_model":{"haiku":{"usd":20}}}}"#.utf8))!
        guard case .shown(let a) = d.accountState else { return XCTFail("shown") }
        XCTAssertEqual(a.byFamily.map(\.0), ["opus", "sonnet", "haiku", "other"])
        XCTAssertEqual(a.byFamily.map(\.1), [100, 60, 30, 11])
        XCTAssertTrue(a.warn)                       // 201 / 250 = 80.4 %
        XCTAssertFalse(d.peak!.warn)
        var p = d; p.applyTurn(peakMTD: 200, warn: nil); XCTAssertTrue(p.peak!.warn)
    }
}

final class LinkAndRouteTests: XCTestCase {
    func testCommandLinkNeverEmitsWorkflow() {
        let room = CommandLink.room(sessionID: "cs_123")
        XCTAssertEqual(room, "forceiq-command://app/open#path=%2Fsessions%2Flive%3Fsession%3Dcs_123")
        XCTAssertEqual(CommandLink.room(sessionID: nil, clientID: "c9"), "forceiq-command://app/open#path=%2Fclients%2Fc9")
        XCTAssertEqual(CommandLink.room(sessionID: "x&workflow=meeting-with-client"), CommandLink.schedule)
        for bad in ["forceiq-command://app/open#path=%2Fsessions%2Flive%3Fsession%3D1%26workflow%3Dmeeting-with-client",
                    "forceiq-command://app/open#path=%2Fmeetings%2F1", "https://evil.test", "forceiq-command://app/open#path=%2Fadmin"] {
            XCTAssertEqual(CommandLink.safe(bad), CommandLink.schedule, bad)
        }
        for s in [room, CommandLink.safe(room), CommandLink.build(path: "/schedule?workflow=meeting-with-client")] {
            XCTAssertFalse((s.removingPercentEncoding ?? s).lowercased().contains("workflow="), s)
        }
        var snap = EngineSnapshot()
        snap.meeting = MeetingRow(client: "Sample Skater", scheduledAt: Date().addingTimeInterval(600), durationMinutes: 60, joinURL: "https://join.example.test",
                                  openURL: "forceiq-command://app/open#path=%2Fsessions%2Flive%3Fsession%3D1%26workflow%3Dmeeting-with-client")
        let card = CardBuilder.meetingCards(snap.meeting!)[0]
        XCTAssertEqual(card.joinURL, CommandLink.schedule)            // never the join URL, never workflow=
    }

    func testThreePOModelDeepLink() {
        XCTAssertEqual(PeakURLRouter.parse("forceiq-peak://3po?model=opus", allowedBundleIDs: []), .threePOModel(.opus))
        XCTAssertEqual(PeakURLRouter.parse("forceiq-peak://3po?model=auto", allowedBundleIDs: []), .threePOModel(.auto))
        XCTAssertNil(PeakURLRouter.parse("forceiq-peak://3po?model=gpt", allowedBundleIDs: []))
        XCTAssertNil(PeakURLRouter.parse("forceiq-peak://3po?model=opus&send=1", allowedBundleIDs: []))
    }

    @MainActor func testThreePOLinkNeedsTheModule() {
        var picked: [ModelPick] = []
        var p = fixtureProfile("profile-coach-a"); p.modules["3po"] = false
        let c = PeakController(prefs: PeakPrefs(stateRoot: tmpRoot()), profile: p, hotkey: FakeHotkey())
        c.onModelPick = { picked.append($0) }
        c.handle(.threePOModel(.haiku)); XCTAssertTrue(picked.isEmpty)
        p.modules["3po"] = true
        let c2 = PeakController(prefs: PeakPrefs(stateRoot: tmpRoot()), profile: p, hotkey: FakeHotkey())
        c2.onModelPick = { picked.append($0) }
        c2.handle(.threePOModel(.haiku)); XCTAssertEqual(picked, [.haiku])
        c2.handle(.ask("hello")); XCTAssertEqual(c2.tab, .threePO); XCTAssertEqual(c2.askText, "hello")
    }
}

final class CanvasGeometryTests: XCTestCase {
    func testFixedCanvasHoldsEveryState() {
        let g = PeakGeometry()
        let notch = ScreenDescriptor(uuid: "A", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                     auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 660, height: 32), auxiliaryTopRight: CGRect(x: 852, y: 950, width: 660, height: 32))
        let pill = ScreenDescriptor(uuid: "B", name: "Studio Display", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), safeAreaTop: 0,
                                    auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        for s in [notch, pill] {
            let l = g.layout(for: s)
            for r in [l.collapsed, l.expanded, l.chat] { XCTAssertTrue(l.canvas.contains(r), "\(s.name) \(r)") }
            XCTAssertEqual(l.canvas.maxY, s.frame.maxY)                       // pinned to the top edge
            XCTAssertTrue(s.frame.contains(l.canvas))
            XCTAssertGreaterThan(l.chat.height, l.expanded.height)
            XCTAssertEqual(l.hitRect(.collapsed), l.collapsed)
        }
    }
}

@MainActor final class DropTests: XCTestCase {
    func testDropIsPickZoneThenPreviewThenRunThenConfirm() async {
        let t = FakeTransport()
        t.answers["/api/peak/title-drop/preview"] = (200, #"{"ok":true,"token":"0123456789ab","client":"Sample Skater","ready":true,"description":"Re-renders the title."}"#)
        t.answers["/api/peak/title-drop/apply"] = (200, #"{"ok":true,"needs_confirm":true,"confirm_text":"Replace the title files"}"#)
        let d = DropStore(transport: t)
        await d.preview(.title); XCTAssertTrue(t.posts.isEmpty)                 // nothing dropped yet
        d.received(URL(fileURLWithPath: "/Users/x/Films/Some_Game_10.18.2026.mp4"))
        if case .pending(_, let z) = d.phase { XCTAssertEqual(z, .shift) } else { XCTFail("pending") }
        XCTAssertTrue(t.posts.isEmpty)                                         // a drop alone reads nothing
        await d.confirm(); XCTAssertTrue(t.posts.isEmpty)
        await d.preview(.title)
        guard case .described(let p) = d.phase else { return XCTFail("described") }
        XCTAssertEqual(p.client, "Sample Skater")
        await d.run()
        XCTAssertNil(t.posts.last?.1["confirm"])
        guard case .confirming = d.phase else { return XCTFail("confirming") }
        t.answers["/api/peak/title-drop/apply"] = (200, #"{"ok":true,"result":"applied"}"#)
        await d.confirm()
        XCTAssertEqual(t.posts.last?.1["confirm"] as? Bool, true)
        XCTAssertEqual(d.pops, 1)
    }

    func testShiftFixNameRidesOnlyOnConfirm() async {
        let t = FakeTransport()
        t.answers["/api/peak/shift-drop/preview"] = (200, #"{"ok":true,"token":"0123456789ab","valid":false,"fix_name":{"to":"Skater_DemoHawks_10.18.2026.mp4"},"description":"Name fix"}"#)
        t.answers["/api/peak/shift-drop/apply"] = (200, #"{"ok":true,"needs_confirm":true}"#)
        let d = DropStore(transport: t)
        d.received(URL(fileURLWithPath: "/Users/x/film.mp4"))
        await d.preview(.shift); await d.run()
        XCTAssertNil(t.posts.last?.1["name"])
        t.answers["/api/peak/shift-drop/apply"] = (200, #"{"ok":true}"#)
        await d.confirm()
        XCTAssertEqual(t.posts.last?.1["name"] as? String, "Skater_DemoHawks_10.18.2026.mp4")
    }
}

@MainActor final class DropContractTests: XCTestCase {
    func testTitleNeedsChoiceShowsPickerThenPreviewsTheGame() async {
        let t = FakeTransport()
        t.answers["/api/peak/title-drop/preview"] = (200, #"{"ok":false,"kind":"title","needs_choice":true,"client":"Sample Skater","choices":["Game A","Game B"],"message":"Which Sample Skater game?"}"#)
        let d = DropStore(transport: t)
        d.received(URL(fileURLWithPath: "/Users/x/Clients/Sample Skater"))
        await d.preview(.title)
        guard case .choosing(_, let client, let choices, _) = d.phase else { return XCTFail("choosing") }
        XCTAssertEqual(client, "Sample Skater"); XCTAssertEqual(choices, ["Game A", "Game B"])
        await d.preview(.title, game: "Not offered"); XCTAssertEqual(t.posts.count, 1)
        t.answers["/api/peak/title-drop/preview"] = (200, #"{"ok":true,"token":"0123456789ab","client":"Sample Skater","ready":true,"description":"x"}"#)
        await d.preview(.title, game: "Game B")
        XCTAssertEqual(t.posts.last?.1["game"] as? String, "Game B")
        guard case .described = d.phase else { return XCTFail("described") }
    }

    func testShiftTargetExistsBlocksApplyAndProgressPolls() async {
        let t = FakeTransport()
        t.answers["/api/peak/shift-drop/preview"] = (200, #"{"ok":true,"token":"0123456789ab","valid":true,"client":{"name":"Sample Skater"},"name":"Skater_Hawks_10.18.2026.mp4","target_exists":true,"problems":[],"game":null,"date":"2026-10-18","description":"d"}"#)
        let d = DropStore(transport: t)
        d.received(URL(fileURLWithPath: "/Users/x/Skater_Hawks_10.18.2026.mp4"))
        await d.preview(.shift)
        guard case .described(let p) = d.phase else { return XCTFail("described") }
        XCTAssertEqual(p.client, "Sample Skater"); XCTAssertTrue(p.targetExists); XCTAssertFalse(p.canApply)
        await d.run(); XCTAssertEqual(t.posts.count, 1)                       // blocked: no apply call
        t.answers["/api/peak/shift-drop/preview"] = (200, #"{"ok":true,"token":"0123456789ab","valid":true,"client":{"name":"Sample Skater"},"target_exists":false,"description":"d"}"#)
        d.received(URL(fileURLWithPath: "/Users/x/Skater_Hawks_10.18.2026.mp4")); await d.preview(.shift)
        t.answers["/api/peak/shift-drop/apply"] = (200, #"{"ok":true,"needs_confirm":true}"#); await d.run()
        t.answers["/api/peak/shift-drop/apply"] = (200, #"{"ok":true,"result":"placed"}"#); await d.confirm()
        XCTAssertEqual(d.shiftState?.state, "waiting")
        t.answers["/api/peak/shift-drop/status/0123456789ab"] = (200, #"{"ok":true,"state":"running","message":"Dagu run is running"}"#)
        await d.pollShift(); XCTAssertEqual(d.shiftState?.state, "running"); XCTAssertEqual(d.shiftState?.step, 4)
        t.answers["/api/peak/shift-drop/status/0123456789ab"] = (200, #"{"ok":true,"state":"succeeded"}"#)
        await d.pollShift(); XCTAssertTrue(d.shiftState!.isFinal)
        let n = t.gets.count; await d.pollShift(); XCTAssertEqual(t.gets.count, n)   // final: no more reads
    }
}

@MainActor final class DefaultPickTests: XCTestCase {
    func testHaikuSoloIsTheDefaultAndAutoIsOneTapAway() async {
        XCTAssertEqual(ModelsDoc().pick, .haiku)
        XCTAssertEqual(ThreePOEvent.parseModels(["models": [Any]()]).pick, .haiku)          // no pick from the engine → Haiku
        let t = FakeTransport()
        t.answers["/api/3po/models"] = (200, #"{"pick":"haiku","models":[{"alias":"haiku","label":"Haiku 5.5","available":true},{"alias":"opus","label":"Opus 5.5","available":true}]}"#)
        let s = ThreePOStore(transport: t)
        await s.loadModels(); XCTAssertEqual(s.pick, .haiku)
        await s.choose(.auto); XCTAssertEqual(s.pick, .auto)
    }

    func testAutoShowsConsultingOpusOnSendSoloDoesNot() async {
        var tr = ThreePOTranscript()
        tr.begin("hi"); XCTAssertFalse(tr.consultingOpus)                         // Haiku solo (default): no pulse
        tr.models.pick = .auto
        tr.begin("why?"); XCTAssertTrue(tr.consultingOpus)                        // Auto: gold pulse the moment it's sent
        tr.apply(.start(route: "claude", modelAlias: "haiku", mode: "advisor", cached: false)); XCTAssertTrue(tr.consultingOpus)
        tr.begin("open flow"); tr.apply(.start(route: "local", modelAlias: "", mode: "solo", cached: false))
        XCTAssertFalse(tr.consultingOpus)                                          // a zero-token local intent: pulse stops
    }
}

final class PolishTokenTests: XCTestCase {
    func testPlaceholderAndDisabledAreGoldAndWhiteAtFullOpacity() {
        XCTAssertEqual(PeakTokens.placeholderHex, Brand.goldHex)
        XCTAssertEqual(PeakTokens.disabledStrokeHex, Brand.goldHex)
        XCTAssertEqual(PeakTokens.disabledLabelHex, Brand.whiteHex)
        XCTAssertEqual(PeakTokens.disabledOpacity, 1.0)
        for h in [PeakTokens.placeholderHex, PeakTokens.disabledLabelHex] { XCTAssertTrue(Brand.allowedTextHex.contains(h)) }
    }

    func testMarkPausesOnCollapsedIdlePillsAndWakesOnHoverExpandOrStateChange() {
        func live(_ e: Bool, _ h: Bool, _ a: Bool) -> Bool {
            MarkPolicy.live(visible: true, globallyVisible: true, reduceMotion: false, expanded: e, hovering: h, awake: a)
        }
        XCTAssertFalse(live(false, false, false))          // collapsed + idle: still frame
        XCTAssertTrue(live(false, true, false))            // hover
        XCTAssertTrue(live(true, false, false))            // expanded
        XCTAssertTrue(live(false, false, true))            // just changed state
        XCTAssertFalse(MarkPolicy.live(visible: false, globallyVisible: true, reduceMotion: false, expanded: true, hovering: true, awake: true))
        XCTAssertFalse(MarkPolicy.live(visible: true, globallyVisible: true, reduceMotion: true, expanded: true, hovering: true, awake: true))
        XCTAssertGreaterThan(PeakTokens.markWakeSeconds, 0)
    }
}

final class ClamshellDisplayTests: XCTestCase {
    func studio(_ i: Int, x: CGFloat) -> ScreenDescriptor {
        ScreenDescriptor(uuid: "STUDIO-\(i)", name: "Studio Display (\(i))", frame: CGRect(x: x, y: 0, width: 2880, height: 1620),
                         safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
    }

    func testLidClosedEveryExternalDisplayGetsAVirtualNotch() {
        // New design (in-notch): a plain external display no longer gets a pill hanging below the
        // menu bar — it gets a virtual notch, top-center, mode .notch with virtualNotch set.
        let screens = [studio(3, x: 0), studio(1, x: 2880), studio(2, x: -2880)]       // no built-in screen at all
        let modes = DisplayPlan.modes(screens)
        XCTAssertEqual(modes.count, 3)
        XCTAssertTrue(modes.values.allSatisfy { $0 == .notch })
        for s in screens {
            let l = PeakGeometry().layout(for: s)
            XCTAssertTrue(l.virtualNotch)
            XCTAssertNotNil(l.notchRect)
            XCTAssertEqual(l.collapsed.midX, s.frame.midX, accuracy: 0.5)              // centered virtual notch on each display
            XCTAssertTrue(s.frame.contains(l.canvas.insetBy(dx: 1, dy: 1)))
        }
    }

    func testANotchIsUsedOnlyWhenThatScreenReportsOne() {
        // The odd fallback (safe-area top but no auxiliary areas) is the ONLY pill left; a plain
        // external display reports no notch and gets the virtual one.
        let odd = ScreenDescriptor(uuid: "X", name: "x", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                   auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        let builtIn = ScreenDescriptor(uuid: "B", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                       auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 660, height: 32),
                                       auxiliaryTopRight: CGRect(x: 852, y: 950, width: 660, height: 32))
        XCTAssertEqual(DisplayPlan.modes([odd]).values.filter { $0 == .notch }.count, 0)
        XCTAssertEqual(PeakGeometry().layout(for: odd).mode, .pill)
        let m = DisplayPlan.modes([builtIn, studio(1, x: 1512)])
        XCTAssertEqual(m["B"], .notch); XCTAssertEqual(m["STUDIO-1"], .notch)
        XCTAssertFalse(PeakGeometry().layout(for: builtIn).virtualNotch)
        XCTAssertTrue(PeakGeometry().layout(for: studio(1, x: 1512)).virtualNotch)
    }
}

final class SwitcherTileStyleTests: XCTestCase {
    func testNotInstalledIsGoldOutlineWhiteLabelGoldNoteAtFullOpacity() {
        let s = SwitcherTileStyle.of(installed: false)
        XCTAssertEqual(s.outlineHex, Brand.goldHex)
        XCTAssertEqual(s.labelHex, Brand.whiteHex)
        XCTAssertEqual(s.note, "Not installed")
        XCTAssertEqual(s.noteHex, Brand.goldHex)
        XCTAssertEqual(s.opacity, 1.0)
        XCTAssertEqual(s.saturation, 1.0)                 // never desaturated to gray
        XCTAssertFalse(s.tappable)
        for h in [s.labelHex, s.noteHex] { XCTAssertTrue(Brand.allowedTextHex.contains(h)) }
        let i = SwitcherTileStyle.of(installed: true)
        XCTAssertNil(i.outlineHex); XCTAssertNil(i.note); XCTAssertEqual(i.opacity, 1.0); XCTAssertTrue(i.tappable)
    }
}

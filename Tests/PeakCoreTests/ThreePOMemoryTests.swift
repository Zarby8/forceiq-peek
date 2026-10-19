import Foundation
import XCTest
@testable import PeakCore

let memoryJSON = #"""
{"ok":true,"owner":"chris","facts":[
 {"id":"m1","text":"Sample Skater's games are on Saturdays","client":"Sample Skater","clients":["Sample Skater"],"ts":"2026-10-19T02:30:00-04:00","forgotten":false},
 {"id":"m2","text":"the NAS is slow on Monday mornings","client":null,"clients":[],"ts":"2026-10-18T09:00:00-04:00","forgotten":false},
 {"id":"m3","text":"Alpha Example likes early ice","client":"Alpha Example","clients":["Alpha Example"],"ts":"2026-10-17T09:00:00-04:00","forgotten":false},
 {"id":"m4","text":"Sample Skater prefers late ice","client":"Sample Skater","clients":["Sample Skater"],"ts":"2026-10-12T09:00:00-04:00","forgotten":true,"forgotten_at":"2026-10-18T10:00:00-04:00"}]}
"""#

func skillJSON(status: String = "described", viewOnly: Bool = false, run: Bool = true, kind: String = "read", action: String? = nil,
               needs: [String] = [], candidates: [String] = []) -> [String: Any] {
    var o: [String: Any] = ["id": "sk0000000001", "slug": "whats-next-today", "name": "What's next today", "description": "A quick read of today.",
                            "kind": kind, "inputs": [] as [Any], "touches": ["Reads only"], "outputs": ["Next meeting"], "client": NSNull(),
                            "client_rule": "optional", "candidates": candidates, "needs": needs, "prompt": "What's next for me today?",
                            "status": status, "message": "Nothing has run.", "view_only": viewOnly, "executed": false]
    if let action { o["action"] = action }
    if run { o["run"] = ["skill": "whats-next-today", "run": true, "inputs": [:] as [String: Any]] }
    return o
}

final class MemoryDocTests: XCTestCase {
    func testParsesAndGroupsByClientThenGeneral() {
        let d = MemoryDoc.parse(Data(memoryJSON.utf8))!
        XCTAssertEqual(d.owner, "chris")
        XCTAssertEqual(d.active.map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(d.forgotten.map(\.id), ["m4"])
        let s = d.sections(showForgotten: false)
        XCTAssertEqual(s.map(\.title), ["Alpha Example", "Sample Skater", "General"])
        XCTAssertEqual(s.map(\.kind), [.client, .client, .general])
        XCTAssertEqual(d.sections(showForgotten: true).last?.title, "Forgotten")
        XCTAssertEqual(d.sections(showForgotten: true).last?.facts.map(\.id), ["m4"])
        XCTAssertEqual(d.facts[0].savedLabel, "Oct 19")
    }

    func testEveryClientFactCarriesItsClient() {
        let d = MemoryDoc.parse(Data(memoryJSON.utf8))!
        for sec in d.sections(showForgotten: true) where sec.kind == .client {
            XCTAssertTrue(sec.facts.allSatisfy { $0.client == sec.title })
        }
    }

    func testRejectsAnEngineError() {
        XCTAssertNil(MemoryDoc.parse(Data(#"{"ok":false,"message":"no owner"}"#.utf8)))
        XCTAssertNil(MemoryDoc.parse(Data("nope".utf8)))
    }

    func testMemoryViewIsBrightOnBlack() {
        XCTAssertEqual(MemoryStyle.backgroundHex, 0x000000)
        XCTAssertEqual(MemoryStyle.textHex, 0xFFFFFF)
        XCTAssertEqual(MemoryStyle.clientHex, 0xF4C430)
        XCTAssertEqual(MemoryStyle.generalHex, 0x4FFF4F)
        XCTAssertEqual(MemoryStyle.opacity, 1.0)
        XCTAssertEqual(PeakTokens.disabledOpacity, 1.0)                 // no half-faded buttons
        for h in MemoryStyle.all { XCTAssertTrue(Brand.allowedTextHex.contains(h), String(h, radix: 16)) }
        for k in [MemorySection.Kind.client, .general, .forgotten] { XCTAssertTrue(Brand.allowedTextHex.contains(MemoryStyle.titleHex(k))) }
        // never a gray: every channel equal and between black and white would be gray
        for h in MemoryStyle.all { let c = Brand.rgb(h); XCTAssertFalse(c.r == c.g && c.g == c.b && c.r > 0 && c.r < 1, "gray \(h)") }
    }

    func testMemoryEventsDecodeAndReduce() {
        let saved = ThreePOEvent.decode(event: "memory", data: #"{"type":"memory","op":"remember","status":"saved","fact":{"id":"m9","text":"x y","client":"Sample Skater","clients":["Sample Skater"],"ts":"2026-10-19T02:00:00-04:00"}}"#)
        guard case .memory(let e) = saved else { return XCTFail("memory") }
        XCTAssertEqual(e.fact?.client, "Sample Skater"); XCTAssertFalse(e.needsPick)
        let pick = ThreePOEvent.decode(event: "memory", data: #"{"type":"memory","op":"remember","status":"pick","candidates":["Ana Twin","Bo Twin"],"text":"Twin's games are Saturdays"}"#)
        guard case .memory(let p) = pick else { return XCTFail("pick") }
        XCTAssertTrue(p.needsPick); XCTAssertEqual(p.candidates, ["Ana Twin", "Bo Twin"])
        XCTAssertEqual(ThreePOEvent.decode(event: "memory_recall", data: #"{"type":"memory_recall","count":2,"clients":["Sample Skater"]}"#),
                       .memoryRecall(count: 2, clients: ["Sample Skater"]))
        var t = ThreePOTranscript()
        t.begin("remember x")
        t.apply(pick); t.apply(.memoryRecall(count: 2, clients: []))
        XCTAssertEqual(t.messages.last?.memory?.status, "pick"); XCTAssertEqual(t.messages.last?.recalled, 2)
    }
}

@MainActor final class MemoryStoreTests: XCTestCase {
    func testLoadAndSoftForget() async {
        let f = FakeTransport()
        f.answers["/api/3po/memory"] = (200, memoryJSON)
        let s = ThreePOStore(transport: f)
        XCTAssertEqual(s.memoryLoad, .idle)
        await s.loadMemory()
        XCTAssertEqual(s.memoryLoad, .loaded); XCTAssertEqual(s.memory.active.count, 3)
        await s.forget("m2")
        let post = f.posts.first { $0.0 == "/api/3po/memory" }
        XCTAssertEqual(post?.1["op"] as? String, "forget"); XCTAssertEqual(post?.1["id"] as? String, "m2")
        XCTAssertFalse(f.posts.contains { ($0.1["op"] as? String) == "delete" })
        await s.forget("m4")                                            // already forgotten: no second post
        XCTAssertEqual(f.posts.filter { $0.0 == "/api/3po/memory" }.count, 1)
        await s.forget("nope")
        XCTAssertEqual(f.posts.filter { $0.0 == "/api/3po/memory" }.count, 1)
    }

    func testLoadFailureIsShownNotHidden() async {
        let f = FakeTransport()
        f.answers["/api/3po/memory"] = (500, "{}")
        let s = ThreePOStore(transport: f)
        await s.loadMemory()
        if case .failed(let m) = s.memoryLoad { XCTAssertFalse(m.isEmpty) } else { XCTFail("should fail visibly") }
    }

    func testRememberInChatRefreshesTheMemoryPane() async {
        let f = FakeTransport()
        f.answers["/api/3po/memory"] = (200, memoryJSON)
        f.events = [.memory(MemoryEvent(op: "remember", status: "saved", fact: MemoryFact(id: "m1", text: "x"), facts: [], candidates: [], text: "x")),
                    .done(text: "Noted.", costUSD: 0, peakMTD: nil, warn: nil, firstTokenMs: nil)]
        let s = ThreePOStore(transport: f)
        s.draft = "remember Sample Skater's games are on Saturdays"
        await s.send()
        XCTAssertTrue(f.gets.contains("/api/3po/memory")); XCTAssertEqual(s.memory.facts.count, 4)
    }

    func testPickMemoryClientResendsWithTheRosterClient() async {
        let f = FakeTransport()
        let pick = MemoryEvent(op: "remember", status: "pick", fact: nil, facts: [], candidates: ["Ana Twin", "Bo Twin"], text: "Twin's games are Saturdays")
        f.events = [.memory(pick), .done(text: "Which one?", costUSD: 0, peakMTD: nil, warn: nil, firstTokenMs: nil)]
        let s = ThreePOStore(transport: f)
        s.draft = "remember Twin's games are Saturdays"
        await s.send()
        let mid = s.transcript.messages.last!.id
        await s.pickMemoryClient("Somebody Else", for: mid)             // not a candidate: ignored
        XCTAssertEqual(f.posts.filter { $0.0 == "/api/3po/stream" }.count, 1)
        await s.pickMemoryClient("Bo Twin", for: mid)
        let last = f.posts.last!.1
        XCTAssertEqual(last["client"] as? String, "Bo Twin"); XCTAssertEqual(last["text"] as? String, "remember Twin's games are Saturdays")
    }

    func testPaneSwitch() {
        let s = ThreePOStore(transport: FakeTransport())
        XCTAssertEqual(s.pane, .chat); s.pane = .memory; XCTAssertEqual(s.pane, .memory)
    }
}

final class SkillPolicyTests: XCTestCase {
    func testDescribedCardIsRunnableOnlyWithTheEnginesRunBody() {
        let c = SkillPolicy.card(from: skillJSON())!
        XCTAssertTrue(c.canRun); XCTAssertEqual(c.kindLabel, "Read-only")
        XCTAssertFalse(SkillPolicy.card(from: skillJSON(run: false))!.canRun)
        XCTAssertFalse(SkillPolicy.card(from: skillJSON(viewOnly: true))!.canRun)
        XCTAssertFalse(SkillPolicy.card(from: skillJSON(status: "needs-input", run: false, needs: ["client"], candidates: ["Sample Skater"]))!.canRun)
        XCTAssertFalse(SkillPolicy.card(from: skillJSON(status: "refused", viewOnly: true, run: false))!.canRun)
    }

    func testDangerousActionSkillIsViewOnlyWhateverTheEngineSays() {
        for a in ["send_email", "delete_clip", "invoice_create", "book_session", "db_update", "deploy_app"] {
            let c = SkillPolicy.card(from: skillJSON(kind: "action", action: a))!
            XCTAssertTrue(c.viewOnly, a); XCTAssertFalse(c.canRun, a)
            XCTAssertNil(SkillPolicy.runBody(c, session: "s", pick: .haiku), a)
        }
        XCTAssertTrue(SkillPolicy.card(from: skillJSON(kind: "action", action: "rerender"))!.canRun)
        XCTAssertFalse(SkillPolicy.card(from: skillJSON(kind: "shell"))!.canRun)
    }

    func testRunBodyIsTheOnlyRunTrue() {
        let c = SkillPolicy.card(from: skillJSON())!
        let o = try! JSONSerialization.jsonObject(with: SkillPolicy.runBody(c, session: "s", pick: .haiku)!) as! [String: Any]
        XCTAssertEqual(o["run"] as? Bool, true); XCTAssertEqual(o["skill"] as? String, "whats-next-today")
        var p = skillJSON(status: "needs-input", run: false, needs: ["client"], candidates: ["Sample Skater", "Alpha Example"])
        p["client_rule"] = "required"
        let pc = SkillPolicy.card(from: p)!
        XCTAssertTrue(pc.needsClientPick)
        let pb = try! JSONSerialization.jsonObject(with: SkillPolicy.pickBody(pc, client: "Sample Skater", session: "s", pick: .haiku)!) as! [String: Any]
        XCTAssertNil(pb["run"]); XCTAssertEqual((pb["inputs"] as? [String: Any])?["client"] as? String, "Sample Skater")
        XCTAssertNil(SkillPolicy.pickBody(pc, client: "Not Listed", session: "s", pick: .haiku))
    }
}

@MainActor final class SkillStoreTests: XCTestCase {
    func testDescriptionFirstThenExplicitRun() async {
        let f = FakeTransport()
        let card = SkillPolicy.card(from: skillJSON())!
        f.events = [.skill(card), .done(text: "What's next today: Nothing has run.", costUSD: 0, peakMTD: nil, warn: nil, firstTokenMs: nil)]
        let s = ThreePOStore(transport: f)
        s.draft = "what's next today"
        await s.send()
        XCTAssertEqual(s.skillPhases[card.id], .described)
        XCTAssertNil(f.posts[0].1["run"])                               // the chat line never runs anything
        XCTAssertEqual(s.transcript.messages.last?.skills.map(\.id), [card.id])
        f.events = [.skillRun(slug: card.slug), .delta("Next meeting: none booked."), .done(text: "", costUSD: 0, peakMTD: nil, warn: nil, firstTokenMs: nil)]
        await s.runSkill(card.id)
        let run = f.posts.last!.1
        XCTAssertEqual(run["run"] as? Bool, true); XCTAssertEqual(run["skill"] as? String, card.slug)
        XCTAssertEqual(s.skillPhases[card.id], .done)
        let n = f.posts.count
        await s.runSkill(card.id)                                       // done: a second tap does nothing
        XCTAssertEqual(f.posts.count, n)
    }

    func testViewOnlySkillNeverRuns() async {
        let f = FakeTransport()
        let card = SkillPolicy.card(from: skillJSON(status: "refused", viewOnly: true, run: false, kind: "action", action: "mail_send"))!
        f.events = [.skill(card), .done(text: "", costUSD: 0, peakMTD: nil, warn: nil, firstTokenMs: nil)]
        let s = ThreePOStore(transport: f)
        s.draft = "/skill sneaky"
        await s.send()
        await s.runSkill(card.id)
        XCTAssertEqual(f.posts.count, 1); XCTAssertFalse(f.posts.contains { ($0.1["run"] as? Bool) == true })
        XCTAssertEqual(s.skillPhases[card.id], .described)
    }

    func testAskAndCopyNeverRun() async {
        let f = FakeTransport()
        let card = SkillPolicy.card(from: skillJSON())!
        f.events = [.skill(card), .done(text: "", costUSD: 0, peakMTD: nil, warn: nil, firstTokenMs: nil)]
        let s = ThreePOStore(transport: f)
        var copied = ""
        s.onCopy = { copied = $0 }
        s.draft = "what's next today"
        await s.send()
        s.copySkill(card.id)
        XCTAssertEqual(copied, "What's next for me today?")
        await s.askSkill(card.id)
        XCTAssertNil(f.posts.last!.1["run"]); XCTAssertNil(f.posts.last!.1["skill"])
        XCTAssertTrue((f.posts.last!.1["text"] as? String ?? "").contains("Don't run it"))
        await s.describeSkill("whats-next-today")
        XCTAssertNil(f.posts.last!.1["run"]); XCTAssertEqual(f.posts.last!.1["skill"] as? String, "whats-next-today")
    }

    func testDemoTransportServesMemory() async {
        let s = ThreePOStore(transport: DemoThreePOTransport())
        await s.loadMemory()
        XCTAssertEqual(s.memoryLoad, .loaded); XCTAssertEqual(s.memory.forgotten.count, 1)
    }
}

import Foundation
import XCTest
@testable import PeakCore

/// forceiq-peak://ask?q=… prefills 3PO's field whether the chat panel is collapsed or already open, and never sends.
/// Installed cdb56232 on the M5: with the chat open, peak.log said `url ask` but the field stayed empty. The prefill lived
/// in ThreePOView.onAppear, which does not re-run while the chat is already showing (and skipped a non-empty draft).
@MainActor final class AskLinkPrefillTests: XCTestCase {
    func make(threePO: Bool = true) -> (PeakController, ThreePOStore, FakeTransport, MemLog) {
        var p = fixtureProfile("profile-coach-a"); p.modules["3po"] = threePO
        let log = MemLog()
        let c = PeakController(prefs: PeakPrefs(stateRoot: tmpRoot()), profile: p, hotkey: FakeHotkey(), logger: log)
        let t = FakeTransport()
        let s = ThreePOStore(transport: t, session: "peak-test", logger: log)
        c.wireAsk(to: s)
        return (c, s, t, log)
    }

    func ask(_ c: PeakController, _ q: String?) {
        let raw = q.map { "forceiq-peak://ask?q=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") } ?? "forceiq-peak://ask"
        c.handle(PeakURLRouter.parse(raw, allowedBundleIDs: [])!)
    }

    func assertNothingSent(_ s: ThreePOStore, _ t: FakeTransport, file: StaticString = #filePath, line: UInt = #line) async {
        await Task.yield(); await Task.yield()
        XCTAssertTrue(t.posts.isEmpty, "an ask link must never send", file: file, line: line)
        XCTAssertTrue(s.transcript.messages.isEmpty, file: file, line: line)
        XCTAssertFalse(s.transcript.streaming, file: file, line: line)
    }

    func testAskLinkWhileCollapsedPrefillsAndNeverSends() async {
        let (c, s, t, log) = make()
        XCTAssertFalse(c.expanded)
        ask(c, "next meeting for Sample")
        XCTAssertTrue(c.expanded); XCTAssertEqual(c.tab, .threePO)
        XCTAssertEqual(s.draft, "next meeting for Sample")
        XCTAssertTrue(s.canSend)                                    // ready for Chris's explicit tap, nothing more
        await assertNothingSent(s, t)
        XCTAssertTrue(log.lines.contains("url ask")); XCTAssertTrue(log.lines.contains("3po prefill"))
        XCTAssertFalse(log.lines.joined(separator: "\n").contains("Sample"))   // names only in the log
    }

    func testAskLinkWhileChatOpenPrefillsAndNeverSends() async {
        let (c, s, t, _) = make()
        c.expand(); c.tab = .threePO                                // the chat panel is already open
        let seq = c.askSeq
        ask(c, "why is the title slide wrong?")
        XCTAssertEqual(s.draft, "why is the title slide wrong?")    // was "" on cdb56232: onAppear never re-ran
        XCTAssertEqual(c.askSeq, seq + 1)
        await assertNothingSent(s, t)
        ask(c, "a second link while still open")                    // a non-empty draft is replaced too (was skipped)
        XCTAssertEqual(s.draft, "a second link while still open")
        await assertNothingSent(s, t)
    }

    func testSameLinkTwiceWhileOpenStillLands() async {
        let (c, s, t, _) = make()
        ask(c, "same question")
        s.draft = ""                                                // Chris cleared the field
        let seq = c.askSeq
        ask(c, "same question")                                     // identical askText: the seq still bumps for the view
        XCTAssertEqual(s.draft, "same question"); XCTAssertEqual(c.askSeq, seq + 1)
        await assertNothingSent(s, t)
    }

    func testAskLinkWhileMemoryPaneOpenShowsChat() async {
        let (c, s, t, _) = make()
        c.expand(); c.tab = .threePO; s.pane = .memory
        ask(c, "show me the chat")
        XCTAssertEqual(s.pane, .chat); XCTAssertEqual(s.draft, "show me the chat")
        await assertNothingSent(s, t)
    }

    func testEmptyAskKeepsTheDraft() async {
        let (c, s, t, _) = make()
        c.expand(); c.tab = .threePO; s.draft = "half typed"
        ask(c, nil)
        XCTAssertEqual(s.draft, "half typed"); XCTAssertEqual(c.askText, "")
        await assertNothingSent(s, t)
    }

    func testWithoutThe3POModuleTheStoreIsUntouched() {
        let (c, s, t, _) = make(threePO: false)
        ask(c, "hello")
        XCTAssertEqual(c.askText, "hello"); XCTAssertEqual(s.draft, ""); XCTAssertTrue(t.posts.isEmpty)
    }

    /// Peek's half of the stale-health rule: Peek assembles no machine context for 3PO. A chat turn carries the typed
    /// text, the session and the model pick only, so no snapshot (health, NAS, status, reading) can ride along from here.
    func testThreePOTurnCarriesNoMachineSnapshot() async {
        let (_, s, t, _) = make()
        s.draft = "what should I work on first?"
        await s.send()
        XCTAssertEqual(t.posts.count, 1)
        let body = t.posts[0].1
        XCTAssertEqual(Set(body.keys), ["text", "session", "model"])
        XCTAssertEqual(body["text"] as? String, "what should I work on first?")
    }
}

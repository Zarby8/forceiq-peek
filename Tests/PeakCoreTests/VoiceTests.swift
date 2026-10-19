import Foundation
import XCTest
@testable import PeakCore

/// The name guard (CTC name boost never overwrites a common word; "'s" restored) on the bake-off's own decodes:
/// `original` is the un-boosted Parakeet TDT v3 final, `boosted` the CTC 110M rescore (spotter rescue off), M5 2026-10-19.
final class VoiceNameGuardTests: XCTestCase {
    let roster = ["Halliday", "Jelenic", "Karapuz", "Benassaya", "Torres", "Cooper"]
    /// A slice of macOS /usr/share/dict/web2 (lowercased) with the words these cases touch.
    let dict: Set<String> = ["holiday", "cooper", "compare", "show", "attendance", "for", "open", "the", "latest", "flow", "package",
                             "pool", "shifts", "from", "saturday", "sink", "retry", "mark", "session", "as", "complete", "close",
                             "and", "save", "notes", "taurus", "on", "sleep", "scores", "video", "upload", "plan", "next"]
    var common: CommonWords { CommonWords(dictionary: dict, roster: roster) }
    func fin(_ o: String, _ b: String) -> String { VoiceNameGuard.finalize(original: o, boosted: b, common: common) }

    // ── the two bake-off false insertions ──
    func testOctoberNeverBecomesCooper() {
        XCTAssertEqual(fin("Show Gelenics attendance for October.", "Show Jelenic attendance for Cooper"),
                       "Show Jelenic attendance for October.")
        XCTAssertEqual(VoiceNameGuard.verdict(original: "October.", boosted: "Cooper", common: common), .rejectedCommon)
    }
    func testCompareNeverBecomesCooper() {
        XCTAssertEqual(fin("Compare gelinic and taurus on sleep scores.", "Cooper Jelenic and taurus on sleep scores."),
                       "Compare Jelenic and taurus on sleep scores.")
        XCTAssertEqual(VoiceNameGuard.verdict(original: "Compare", boosted: "Cooper", common: common), .rejectedCommon)
    }
    /// Even with no word list loaded (no /usr/share/dict), the built-in list still protects these.
    func testHardListProtectsWithoutADictionary() {
        let bare = CommonWords(dictionary: [], roster: roster)
        XCTAssertEqual(VoiceNameGuard.finalize(original: "Show it for October.", boosted: "Show it for Cooper", common: bare), "Show it for October.")
        XCTAssertEqual(VoiceNameGuard.finalize(original: "Compare them", boosted: "Cooper them", common: bare), "Compare them")
    }
    /// A dictionary word only becomes a name when it's a near-homophone (same first letter, similarity ≥ 0.7).
    func testDictionaryWordsNeedANearHomophone() {
        XCTAssertEqual(VoiceNameGuard.verdict(original: "Holiday.", boosted: "Halliday", common: common), .accepted)
        XCTAssertEqual(VoiceNameGuard.verdict(original: "sleep", boosted: "Torres", common: common), .rejectedDictionary)
        XCTAssertEqual(VoiceNameGuard.verdict(original: "taurus", boosted: "Torres", common: common), .rejectedDictionary)
    }

    // ── possessives on real roster names ──
    func testPossessiveRestoredOnHalliday() {
        XCTAssertEqual(fin("Open Halliday's latest flow package and press the code button.", "Open Halliday latest flow package and press the code button."),
                       "Open Halliday's latest flow package and press the code button.")
        XCTAssertEqual(fin("Retry the upload for Halliday's video.", "Retry the upload for Halliday video."), "Retry the upload for Halliday's video.")
        XCTAssertEqual(fin("Hey, what's next on Halliday's plan?", "Hey, what's next on Halliday plan?"), "Hey, what's next on Halliday's plan?")
    }
    func testPossessiveRestoredWhenTheBoostAlsoFixesTheSpelling() {
        XCTAssertEqual(fin("Mark Bonassea's session as complete.", "Mark Benassaya session as complete."), "Mark Benassaya's session as complete.")
        XCTAssertEqual(fin("Uh, pull up Jellinic's last three workouts.", "Uh, pull up Jelenic last three workouts."), "Uh, pull up Jelenic's last three workouts.")
        XCTAssertEqual(fin("Open Cooper Kerapuza's latest flow package.", "Open Cooper Karapuz latest flow package."), "Open Cooper Karapuz's latest flow package.")
        XCTAssertEqual(fin("Show Karapuz's progress on the squat.", "Show Karapuz progress on the squat."), "Show Karapuz's progress on the squat.")
    }

    // ── a correct boost goes through (and keeps the decoder's punctuation) ──
    func testCorrectBoostOnRealNames() {
        XCTAssertEqual(fin("Close the session and save notes for Holiday.", "Close the session and save notes for Halliday"),
                       "Close the session and save notes for Halliday.")
        XCTAssertEqual(fin("Start a meeting with Jalenig.", "Start a meeting with Jelenic"), "Start a meeting with Jelenic.")
        XCTAssertEqual(fin("Pool shifts for Cooper Carapas from Saturday.", "Pool shifts for Cooper Karapuz from Saturday."),
                       "Pool shifts for Cooper Karapuz from Saturday.")
        XCTAssertEqual(fin("Retry the title fix for Binasaya.", "Retry the title fix for Benassaya"), "Retry the title fix for Benassaya.")
        XCTAssertEqual(fin("Move the Naseya to the 6am group.", "Move the Benassaya to the 6am group."), "Move the Benassaya to the 6am group.")
    }

    /// Every bake-off utterance the boost touched (25 of 40): names right, no common word lost, possessives back.
    func testBakeOffReplay() {
        let cases: [(String, String, String)] = [
            ("Open Halliday's latest flow package and press the code button.", "Open Halliday latest flow package and press the code button.", "Open Halliday's latest flow package and press the code button."),
            ("Start a meeting with Jalenig.", "Start a meeting with Jelenic", "Start a meeting with Jelenic."),
            ("Pool shifts for Cooper Carapas from Saturday.", "Pool shifts for Cooper Karapuz from Saturday.", "Pool shifts for Cooper Karapuz from Saturday."),
            ("Retry the title fix for Binasaya.", "Retry the title fix for Benassaya", "Retry the title fix for Benassaya."),
            ("Start a check-in with Karapas at 4.30.", "Start a check-in with Karapuz at 4.30.", "Start a check-in with Karapuz at 4.30."),
            ("Okay so, pull the latest notes for Jelinek.", "Okay so, pull the latest notes for Jelenic", "Okay so, pull the latest notes for Jelenic."),
            ("Mark Bonassea's session as complete.", "Mark Benassaya session as complete.", "Mark Benassaya's session as complete."),
            ("Hey, what's next on Halliday's plan?", "Hey, what's next on Halliday plan?", "Hey, what's next on Halliday's plan?"),
            ("Um, show me Cooper Carapuza's recovery score.", "Um, show me Cooper Karapuz recovery score.", "Um, show me Cooper Karapuz's recovery score."),
            ("Open the code tab for Banasaya and press run.", "Open the code tab for Benassaya and press run.", "Open the code tab for Benassaya and press run."),
            ("Pull shifts for Jalanic from Monday to Friday.", "Pull shifts for Jelenic from Monday to Friday.", "Pull shifts for Jelenic from Monday to Friday."),
            ("Retry the sink for carapaz.", "Retry the sink for Karapuz", "Retry the sink for Karapuz."),
            ("So, like, open Halliday's latest package.", "So, like, open Halliday latest package.", "So, like, open Halliday's latest package."),
            ("Cancel tomorrow's session with Binasaya.", "Cancel tomorrow's session with Benassaya", "Cancel tomorrow's session with Benassaya."),
            ("Open the roster and filter by Kerapuz.", "Open the roster and filter by Karapuz", "Open the roster and filter by Karapuz."),
            ("Uh, pull up Jellinic's last three workouts.", "Uh, pull up Jelenic last three workouts.", "Uh, pull up Jelenic's last three workouts."),
            ("Move the Naseya to the 6am group.", "Move the Benassaya to the 6am group.", "Move the Benassaya to the 6am group."),
            ("Open Cooper Kerapuza's latest flow package.", "Open Cooper Karapuz latest flow package.", "Open Cooper Karapuz's latest flow package."),
            ("Show Gelenics attendance for October.", "Show Jelenic attendance for Cooper", "Show Jelenic attendance for October."),
            ("Pool shifts for Binaseya from Sunday.", "Pool shifts for Benassaya from Sunday.", "Pool shifts for Benassaya from Sunday."),
            ("Open the flow package for Carapuzz and press the code button.", "Open the flow package for Karapuz and press the code button.", "Open the flow package for Karapuz and press the code button."),
            ("Compare gelinic and taurus on sleep scores.", "Cooper Jelenic and taurus on sleep scores.", "Compare Jelenic and taurus on sleep scores."),
            ("Retry the upload for Halliday's video.", "Retry the upload for Halliday video.", "Retry the upload for Halliday's video."),
            ("Start a meeting with Vinasaya, um, after lunch.", "Start a meeting with Benassaya um, after lunch.", "Start a meeting with Benassaya, um, after lunch."),
            ("Show Karapuz's progress on the squat.", "Show Karapuz progress on the squat.", "Show Karapuz's progress on the squat."),
            ("Pause the timer for Jelenig.", "Pause the timer for Jelenic", "Pause the timer for Jelenic."),
            ("Close the session and save notes for Holiday.", "Close the session and save notes for Halliday", "Close the session and save notes for Halliday."),
        ]
        var wrong: [String] = []
        for (o, b, want) in cases where fin(o, b) != want { wrong.append("\(fin(o, b))  ≠  \(want)") }
        XCTAssertEqual(wrong, [], wrong.joined(separator: "\n"))
    }

    func testNoBoostOrAWordCountChangeKeepsTheDecode() {
        XCTAssertEqual(VoiceNameGuard.finalize(original: "Open the package.", boosted: nil, common: common), "Open the package.")
        XCTAssertEqual(fin("Open the package for Holiday.", "Open the Halliday package"), "Open the package for Holiday.")
    }
}

final class VoiceLiveWordsTests: XCTestCase {
    func testOnlyAgreedWordsAreShownAndNeverShrink() {
        XCTAssertEqual(LiveWords.agreedPrefix("Open holidays later.", "Open Halliday's latest"), "Open")
        XCTAssertEqual(LiveWords.agreedPrefix("Open Halliday's latest", "Open Halliday's latest flow"), "Open Halliday's latest")
        XCTAssertEqual(LiveWords.advance(shown: "Open Halliday's", agreed: "Open"), "Open Halliday's")       // never shrinks
        XCTAssertEqual(LiveWords.advance(shown: "Open", agreed: "Open Halliday's latest"), "Open Halliday's latest")
        XCTAssertEqual(LiveWords.advance(shown: "Open the", agreed: "Open a flow"), "Open the")              // no rewrite of shown words
    }
    func testALoneFillerWaitsForASecondWord() {
        XCTAssertEqual(LiveWords.display("Okay."), "")
        XCTAssertEqual(LiveWords.display("Okay so,"), "Okay so,")
        XCTAssertEqual(LiveWords.display("Open"), "Open")
    }
    func testNamesUnderlinedIncludingPossessiveAndSurname() {
        let roster = ["Tobias Marchetti", "Avery Kowalczyk", "Halliday"]
        let n = LiveWords.matchNames("Open Marchetti's latest FLOW package for halliday", roster: roster)
        XCTAssertEqual(Set(n), ["Marchetti", "Halliday"])
        let line = VoiceLine(confirmed: "Open Marchetti's package", isFinal: false, names: ["Marchetti"])
        XCTAssertEqual(line.segments.map(\.text), ["Open ", "Marchetti", "'s package"])
        XCTAssertEqual(line.segments.map(\.name), [false, true, false])
        XCTAssertTrue(line.segments.allSatisfy { !$0.final })
        XCTAssertTrue(VoiceLine(confirmed: "Open it", isFinal: true).segments.allSatisfy(\.final))
        // Pending words are never dimmed: the only pending cue is a gold caret, gone once the final pass lands.
        XCTAssertTrue(line.pending); XCTAssertFalse(VoiceLine(confirmed: "Open it", isFinal: true).pending); XCTAssertFalse(VoiceLine(confirmed: "").pending)
        XCTAssertEqual(VoiceLine.pendingCaretHex, Brand.goldHex); XCTAssertEqual(VoiceLine.pendingCaretHex, 0xF4C430); XCTAssertTrue(Brand.allowedTextHex.contains(VoiceLine.pendingCaretHex))
        XCTAssertEqual(VoiceLine(confirmed: "the cooperative", names: ["Cooper"]).segments.map(\.name), [false])   // not inside a word
    }
}

final class VoiceGateAndModelsTests: XCTestCase {
    func testOffByDefaultAndOptIn() {
        var p = DemoData.profile()
        XCTAssertFalse(VoiceGate.enabled(p, setting: nil))                // profile modules.voice absent → off
        XCTAssertTrue(VoiceGate.enabled(p, setting: true))
        p.modules["voice"] = true
        XCTAssertFalse(VoiceGate.enabled(p, setting: false))              // the coach's own setting wins
        XCTAssertFalse(VoiceGate.enabled(.none, setting: true))           // no profile, no voice
    }
    func testModelsArePinnedAndLiveUnderThePeakRoot() {
        let root = URL(fileURLWithPath: "/Users/demo/ForceIQ/peak")
        XCTAssertEqual(VoiceModels.dir(VoiceModels.tdt, peakRoot: root).path, "/Users/demo/ForceIQ/peak/models/parakeet-tdt-0.6b-v3")
        XCTAssertEqual(VoiceModels.dir(VoiceModels.ctc, peakRoot: root).path, "/Users/demo/ForceIQ/peak/models/parakeet-ctc-110m-coreml")
        for m in VoiceModels.all {
            XCTAssertEqual(m.revision.count, 40); XCTAssertNotEqual(m.revision, "main")
            XCTAssertFalse(m.repo.lowercased().contains("eou") || m.repo.lowercased().contains("nemotron") || m.repo.lowercased().contains("unified"))
        }
        XCTAssertFalse(VoiceModels.root(root).path.hasPrefix("/tmp"))
    }
    func testDeepLinkTogglesOnly() {
        func p(_ s: String) -> PeakURLAction? { PeakURLRouter.parse(s, allowedBundleIDs: []) }
        XCTAssertEqual(p("forceiq-peak://voice"), .voice)
        XCTAssertEqual(p("forceiq-peak://voice?do=toggle"), .voice)
        XCTAssertNil(p("forceiq-peak://voice?do=start"))
        XCTAssertNil(p("forceiq-peak://voice?text=hello"))
        XCTAssertEqual(PeakURLAction.voice.name, "voice")
    }
    func testProgressLineIsWhiteTextOnlyAndPercent() {
        XCTAssertEqual(VoicePhase.downloading(fraction: 0.425, what: "Parakeet TDT 0.6B v3").line, "Downloading Parakeet TDT 0.6B v3: 43 %")
        XCTAssertNil(VoicePhase.ready.line); XCTAssertNil(VoicePhase.listening.line)
        XCTAssertTrue(VoicePhase.ready.canToggle); XCTAssertTrue(VoicePhase.listening.canToggle); XCTAssertFalse(VoicePhase.loading.canToggle)
    }
}

@MainActor final class ClientCommandTests: XCTestCase {
    let roster = ["Tobias Marchetti", "Avery Kowalczyk", "Avery Lindqvist", "Halliday", "Cooper Karapuz"]
    let tz = TimeZone(identifier: "America/Detroit")!
    let now = Date(timeIntervalSince1970: 1_792_000_000)        // fixed clock
    func ctx(meeting: MeetingRow? = nil) -> ClientCommandContext {
        ClientCommandContext(roster: roster, meeting: meeting, desktopActions: false, flowApp: "FLOW", now: now, timeZone: tz)
    }

    func testParsesBothCommandsAsSpoken() {
        let a = ClientCommands.parse("Open Tobias Marchetti's FLOW package and hit the code button.")
        XCTAssertEqual(a?.kind, .flowPackage); XCTAssertEqual(a?.spokenClient, "tobias marchetti"); XCTAssertEqual(a?.codeButton, true)
        let b = ClientCommands.parse("Open the flow package for Karapuz and press the code button.")
        XCTAssertEqual(b?.kind, .flowPackage); XCTAssertEqual(b?.spokenClient, "karapuz")
        let c = ClientCommands.parse("Start a meeting with Halliday.")
        XCTAssertEqual(c?.kind, .startMeeting); XCTAssertEqual(c?.spokenClient, "halliday")
        let d = ClientCommands.parse("Okay so, start a meeting with Avery, um, after lunch.")
        XCTAssertEqual(d?.spokenClient, "avery"); XCTAssertEqual(d?.when, "um, after lunch")
        XCTAssertNil(ClientCommands.parse("Why is the title slide wrong?"))
        XCTAssertNil(ClientCommands.parse("Book a meeting with Halliday"))          // booking is never a Peek command
    }

    func testResolvesOneClientOrAmbiguous() {
        XCTAssertEqual(ClientCommands.resolve("tobias marchetti", roster: roster), ["Tobias Marchetti"])
        XCTAssertEqual(ClientCommands.resolve("marchetti", roster: roster), ["Tobias Marchetti"])
        XCTAssertEqual(Set(ClientCommands.resolve("avery", roster: roster)), ["Avery Kowalczyk", "Avery Lindqvist"])
        XCTAssertEqual(ClientCommands.resolve("avery lindqvist", roster: roster), ["Avery Lindqvist"])
        XCTAssertEqual(ClientCommands.resolve("karapuz", roster: roster), ["Cooper Karapuz"])
        XCTAssertEqual(ClientCommands.resolve("haliday", roster: roster), ["Halliday"])
        XCTAssertEqual(ClientCommands.resolve("zebedee", roster: roster), [])
    }

    func testMeetingCardNamesClientMeetingAndTimeAndOnlyOpensCommand() {
        let m = MeetingRow(client: "Tobias Marchetti", scheduledAt: now.addingTimeInterval(42 * 60), durationMinutes: 60, joinURL: "https://meet.example/x",
                           openURL: CommandLink.room(sessionID: "s_123"))
        let r = ClientCommands.route("Start a meeting with Marchetti", ctx(meeting: m), id: "c1")!
        XCTAssertEqual(r.card.origin, .command); XCTAssertEqual(r.card.client, "Tobias Marchetti")
        XCTAssertTrue(r.card.inputs.contains("Client: Tobias Marchetti"))
        XCTAssertTrue(r.card.inputs.contains("Meeting: next booking in Command, 60 min"))
        XCTAssertTrue(r.card.inputs.contains { $0.hasPrefix("Time: ") && $0.contains("in 42 min") })
        XCTAssertEqual(r.card.link, CommandLink.room(sessionID: "s_123"))       // the room page, never the join URL
        XCTAssertFalse(r.card.link!.contains("workflow"))
        XCTAssertNil(r.card.previewBody); XCTAssertNil(r.card.confirmBody)     // nothing goes to /api/act
        // no booking for this client → the schedule, and the card says so
        let r2 = ClientCommands.route("Start a meeting with Halliday", ctx(meeting: m), id: "c2")!
        XCTAssertEqual(r2.card.link, CommandLink.schedule)
        XCTAssertTrue(r2.card.inputs.contains("Meeting: none booked in Command"))
        XCTAssertTrue(r2.card.inputs.contains("Time: not booked"))
    }

    func testFlowCardKeepsTheCodeButtonClickOff() {
        let r = ClientCommands.route("Open Tobias Marchetti's FLOW package and hit the code button", ctx(), id: "c3")!
        XCTAssertEqual(r.card.action, "flow_package_code"); XCTAssertEqual(r.card.appName, "FLOW"); XCTAssertNil(r.card.link)
        XCTAssertTrue(r.card.touches.contains("Desktop actions (off"))
        XCTAssertTrue(r.card.inputs.contains("Client: Tobias Marchetti"))
        XCTAssertTrue(r.card.inputs.contains { $0.hasPrefix("Meeting: ") }); XCTAssertTrue(r.card.inputs.contains { $0.hasPrefix("Time: ") })
    }

    func testANameSplitIntoOtherWordsIsOfferedAsAPick() {
        // Live smoke, Samantha: "Open Tobias Marchetti's FLOW package…" decoded as "Open to buy a smartis flow package…"
        let roster = DemoData.voiceRoster
        XCTAssertTrue(ClientCommands.resolve("to buy a smartis", roster: roster).isEmpty)          // never auto-chosen
        XCTAssertEqual(ClientCommands.near("to buy a smartis", roster: roster), ["Tobias Marchetti"])   // only offered
        guard let r = ClientCommands.route("Open to buy a smartis flow package and hit the code button.", ClientCommandContext(roster: roster), id: "x")
        else { return XCTFail("not a command") }
        XCTAssertEqual(r.card.origin, .pick); XCTAssertEqual(r.card.picks, ["Tobias Marchetti"])
    }

    func testAmbiguousClientGetsAPickCard() {
        let r = ClientCommands.route("Start a meeting with Avery", ctx(), id: "c4")!
        XCTAssertEqual(r.card.origin, .pick)
        XCTAssertEqual(Set(r.card.picks), ["Avery Kowalczyk", "Avery Lindqvist"])
    }

    /// Through the store, exactly as a typed message: a local card, zero network, nothing runs until Run.
    func testStoreRoutesTheTranscriptLocallyAndRunsOnlyOnTap() async {
        let t = FakeTransport()
        let s = ThreePOStore(transport: t)
        var opened: [ProposalCard] = []
        s.commandContext = { self.ctx() }
        s.onCommandRun = { c in opened.append(c); return "opened" }
        await s.sendDictation("Start a meeting with Avery.")
        XCTAssertTrue(t.posts.isEmpty)                                         // no stream, no /api/act
        guard let pick = s.transcript.messages.last?.proposals.first else { return XCTFail("no card") }
        XCTAssertEqual(pick.origin, .pick)
        XCTAssertEqual(s.transcript.messages.first?.text, "Start a meeting with Avery.")
        s.pickClient(pick.id, "Avery Lindqvist")
        guard let card = s.transcript.messages.last?.proposals.first else { return XCTFail("no confirm card") }
        XCTAssertEqual(card.client, "Avery Lindqvist"); XCTAssertEqual(s.phases[card.id], .described)
        XCTAssertTrue(opened.isEmpty)                                          // nothing ran yet
        await s.run(card.id)
        XCTAssertEqual(opened.map(\.id), [card.id]); XCTAssertEqual(s.phases[card.id], .done("opened"))
        await s.run(card.id)                                                   // a second tap does nothing
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(t.posts.isEmpty)
        // anything else still goes to 3PO
        s.draft = "Why is the title slide wrong?"; await s.send()
        XCTAssertEqual(t.posts.first?.0, "/api/3po/stream")
    }

    /// Dictation is the typed path: anything that isn't a client command reaches the engine with the very same body a
    /// typed send makes, so the engine's skill matching and memory ("remember …", recall) apply to spoken words too.
    func testDictationUsesTheTypedPathForSkillsAndMemory() async {
        let typed = FakeTransport(), spoken = FakeTransport()
        let a = ThreePOStore(transport: typed), b = ThreePOStore(transport: spoken)
        let ctx = ClientCommandContext(roster: DemoData.voiceRoster)
        a.commandContext = { ctx }; b.commandContext = { ctx }
        for text in ["What's next today?", "Remember Sample Skater's games are on Saturdays.", "How much have I spent this month?"] {
            a.draft = text; await a.send()
            await b.sendDictation(text)
        }
        XCTAssertEqual(spoken.posts.count, 3)
        XCTAssertEqual(spoken.posts.map(\.0), typed.posts.map(\.0))
        XCTAssertEqual(spoken.posts.map { $0.1["text"] as? String }, typed.posts.map { $0.1["text"] as? String })
        XCTAssertEqual(spoken.posts.map { $0.1.keys.sorted() }, typed.posts.map { $0.1.keys.sorted() })
        XCTAssertEqual(b.transcript.messages.filter { $0.role == .user }.map(\.text), a.transcript.messages.filter { $0.role == .user }.map(\.text))
    }
}

/// Voice motion and timers run only while recording (the idle-CPU rule; see AmbientMotionGuardTests).
final class VoiceMotionGuardTests: XCTestCase {
    func voiceSource() throws -> [String] {
        codeLines(try XCTUnwrap(appSourceFiles().first { $0.name == "Voice.swift" }, "Voice.swift not found").text)
    }

    func testMicPulseIsMountedOnlyWhileListening() throws {
        let lines = try voiceSource()
        var found = 0
        for (i, l) in lines.enumerated() where l.contains("phaseAnimator") || l.contains("keyframeAnimator") {
            found += 1
            let ctx = lines[max(0, i - 2)...i].joined(separator: " ")
            XCTAssertTrue(ctx.contains("if on "), "Voice.swift:\(i + 1): a repeating voice animation outside `if on` (listening)")
        }
        XCTAssertEqual(found, 1, "one mic pulse expected")
    }

    func testNoAlwaysOnClocks() throws {
        let code = try voiceSource().joined(separator: "\n")
        for bad in ["repeatForever", "Timer.scheduledTimer", "Timer.publish", "TimelineView", "displayLink(target:", "CADisplayLink"] {
            XCTAssertFalse(code.contains(bad), "Voice.swift uses \(bad); partial decodes are paced by the audio itself")
        }
        // the only timer: the test feed's real-time pacer, cancelled at its end and on stop
        XCTAssertEqual(code.components(separatedBy: "makeTimerSource").count - 1, 1)
        XCTAssertTrue(code.contains("timer?.cancel(); timer = nil"))
        // the mic tap goes away on stop
        XCTAssertTrue(code.contains("removeTap(onBus: 0)"))
    }
}

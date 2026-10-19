import Foundation
import XCTest
@testable import PeakCore

/// "What's my day": composition, STALE labelling, plain "unavailable", the typed / dictated command, speak-only-with-
/// Voice-on and interrupt-by-toggle. FAKE client names only.
let briefET = TimeZone(identifier: "America/Detroit")!
let briefNow = EngineParse.date("2026-10-19T12:00:00Z")!            // 8:00 AM ET
func at(_ iso: String) -> Date { EngineParse.date(iso)! }

@MainActor final class FakeSpeaker: BriefSpeaking {
    var spoken: [String] = []
    var stops = 0
    var pending: (@MainActor () -> Void)?
    func speak(_ text: String, done: @escaping @MainActor () -> Void) { spoken.append(text); pending = done }
    func stop() { stops += 1; let d = pending; pending = nil; d?() }
    func finishNaturally() { let d = pending; pending = nil; d?() }
}

func briefSnapshot(takenAt: Date = briefNow) -> EngineSnapshot {
    var s = EngineSnapshot()
    s.takenAt = takenAt; s.liveAt = takenAt; s.approvalsAt = takenAt
    s.today = [SessionRow(client: "Test Client Alpha", scheduledAt: at("2026-10-19T13:30:00Z"), durationMinutes: 60),
               SessionRow(client: "Test Client Bravo", scheduledAt: at("2026-10-19T18:00:00Z"), durationMinutes: 45)]
    s.approvals = [
        ApprovalRow(id: "aaaaaaaaaaaa", kind: "failed_job", kindLabel: "Failed job", title: "Title slide failed for Test Client Charlie", why: "",
                    client: "Test Client Charlie", gate: "confirm", touches: [], outputs: [], actLabel: "recover", test: false),
        ApprovalRow(id: "bbbbbbbbbbbb", kind: "crest", kindLabel: "Crest approval", title: "Approve crest", why: "",
                    client: "Test Client Alpha", gate: "click", touches: [], outputs: [], actLabel: "", test: false),
        ApprovalRow(id: "cccccccccccc", kind: "proposal", kindLabel: "Claude proposal", title: "Confirm jersey", why: "",
                    client: "Test Client Bravo", gate: "routine", touches: [], outputs: [], actLabel: "client_confirm", test: false),
        ApprovalRow(id: "dddddddddddd", kind: "proposal", kindLabel: "Dry-run test", title: "Self-test", why: "",
                    client: "Test Client Delta", gate: "routine", touches: [], outputs: [], actLabel: "", test: true),
    ]
    s.fixesNeeded = [BriefItem(kind: "Needs a fix", client: "Test Client Charlie", title: "Title_slide failed for Test Client Charlie")]
    return s
}

final class DayBriefCompositionTests: XCTestCase {
    func testBriefNamesEveryClientInAFewSentences() {
        var cache = DayBriefCache()
        let text = DayBriefComposer.compose(cache.ingest(briefSnapshot(), now: briefNow), now: briefNow, tz: briefET)
        XCTAssertEqual(text, "2 Command sessions today: Test Client Alpha at 9:30 AM ET and Test Client Bravo at 2:00 PM ET. "
                           + "1 BLOCKED: Failed job for Test Client Charlie. "
                           + "2 decisions waiting on you: Crest approval for Test Client Alpha and Claude proposal for Test Client Bravo.")
        XCTAssertFalse(text.contains("Delta"), "dry-run test items never reach the brief")
        XCTAssertFalse(text.contains("STALE"))
        XCTAssertEqual(text.components(separatedBy: ". ").count, 3, "three sentences")
    }

    func testEmptyDayIsSaidPlainly() {
        var s = briefSnapshot(); s.today = []; s.approvals = []; s.fixesNeeded = []
        var cache = DayBriefCache()
        XCTAssertEqual(DayBriefComposer.compose(cache.ingest(s, now: briefNow), now: briefNow, tz: briefET),
                       "No Command sessions on today's schedule. Nothing is BLOCKED. No decisions waiting on you.")
    }

    func testLongListsStayShort() {
        var s = briefSnapshot()
        s.today = (0..<6).map { SessionRow(client: "Test Client \($0)", scheduledAt: at("2026-10-19T14:00:00Z").addingTimeInterval(Double($0) * 3600), durationMinutes: 60) }
        var cache = DayBriefCache()
        let text = DayBriefComposer.compose(cache.ingest(s, now: briefNow), now: briefNow, tz: briefET)
        XCTAssertTrue(text.hasPrefix("6 Command sessions today: Test Client 0 at 10:00 AM ET, Test Client 1 at 11:00 AM ET, Test Client 2 at 12:00 PM ET and 3 more."), text)
    }

    func testBlockedIsDedupedAndSplitFromDecisions() {
        let s = briefSnapshot()
        XCTAssertEqual(DayBriefSplit.blocked(s).map(\.phrase), ["Failed job for Test Client Charlie"])          // alert + approval: once
        XCTAssertEqual(DayBriefSplit.decisions(s).map(\.client), ["Test Client Alpha", "Test Client Bravo"])
        var f = s; f.fixes = [FixRow(title: "Remount NAS", client: "", state: "failed", message: "")]
        XCTAssertTrue(DayBriefSplit.blocked(f).map(\.phrase).contains("Failed fix: Remount NAS"))               // no client: its title
    }

    func testEveryClientItemNamesItsClient() {
        var cache = DayBriefCache()
        let src = cache.ingest(briefSnapshot(), now: briefNow)
        guard case .read(let b, _) = src.blocked, case .read(let d, _) = src.decisions, case .read(let t, _) = src.sessions else { return XCTFail() }
        for i in b + d where !i.client.isEmpty { XCTAssertTrue(i.phrase.contains(i.client)) }
        XCTAssertTrue(t.allSatisfy { !$0.client.isEmpty })
    }
}

final class DayBriefStaleTests: XCTestCase {
    func testAgeAndLabelMatchTheEngineClock() {
        XCTAssertEqual(BriefClock.staleAfter, 300)
        XCTAssertEqual(BriefClock.age(45), "45 s")
        XCTAssertEqual(BriefClock.age(12 * 60), "12 min")
        XCTAssertEqual(BriefClock.age(4 * 3600 + 12 * 60), "4 h 12 min")
        XCTAssertEqual(BriefClock.staleLabel(at("2026-10-19T11:48:00Z"), now: briefNow, tz: briefET), "STALE (read 7:48 AM ET, 12 min ago)")
    }

    func testOlderThan300sIsLabelledStaleWithItsAge() {
        var cache = DayBriefCache()
        let s = briefSnapshot(takenAt: briefNow.addingTimeInterval(-12 * 60))
        let text = DayBriefComposer.compose(cache.ingest(s, now: briefNow), now: briefNow, tz: briefET)
        XCTAssertTrue(text.hasPrefix("2 Command sessions today, STALE (read 7:48 AM ET, 12 min ago): Test Client Alpha"), text)
        XCTAssertTrue(text.contains("1 BLOCKED, STALE (read 7:48 AM ET, 12 min ago): "), text)
        XCTAssertTrue(text.contains("2 decisions waiting on you, STALE (read 7:48 AM ET, 12 min ago): "), text)
    }

    func testThresholdIsStrictlyOver300s() {
        for (age, stale) in [(299.0, false), (300.0, false), (301.0, true)] {
            var cache = DayBriefCache()
            let text = DayBriefComposer.compose(cache.ingest(briefSnapshot(takenAt: briefNow.addingTimeInterval(-age)), now: briefNow), now: briefNow, tz: briefET)
            XCTAssertEqual(text.contains("STALE"), stale, "age \(age)")
        }
    }

    func testOnlyTheStaleSourceIsLabelled() {
        var s = briefSnapshot(); s.liveAt = briefNow.addingTimeInterval(-20 * 60)      // the live status doc is 20 min old
        var cache = DayBriefCache()
        let text = DayBriefComposer.compose(cache.ingest(s, now: briefNow), now: briefNow, tz: briefET)
        XCTAssertTrue(text.contains("1 BLOCKED, STALE (read 7:40 AM ET, 20 min ago)"), text)
        XCTAssertTrue(text.hasPrefix("2 Command sessions today: "), text)
        XCTAssertTrue(text.contains("2 decisions waiting on you: "), text)
    }

    func testAFailedReadFallsBackToTheLastGoodOneLabelledStale() {
        var cache = DayBriefCache()
        _ = cache.ingest(briefSnapshot(takenAt: briefNow.addingTimeInterval(-10 * 60)), now: briefNow.addingTimeInterval(-10 * 60))
        var bad = EngineSnapshot(); bad.takenAt = briefNow; bad.meetingError = "GOAT didn't answer for the next meeting."; bad.errors = ["live", "approvals"]
        let text = DayBriefComposer.compose(cache.ingest(bad, now: briefNow), now: briefNow, tz: briefET)
        XCTAssertTrue(text.hasPrefix("2 Command sessions today, STALE (read 7:50 AM ET, 10 min ago)"), text)
        XCTAssertTrue(text.contains("decisions waiting on you, STALE (read 7:50 AM ET, 10 min ago)"), text)
    }
}

final class DayBriefUnavailableTests: XCTestCase {
    func testUnavailableSourcesAreSaidPlainlyNeverInvented() {
        var cache = DayBriefCache()
        var s = EngineSnapshot(); s.takenAt = briefNow
        s.commandSignIn = CommandSignInNotice()
        s.errors = ["live", "approvals"]
        let text = DayBriefComposer.compose(cache.ingest(s, now: briefNow), now: briefNow, tz: briefET)
        XCTAssertEqual(text, "Sessions: Command sign-in expired, so I can't read today's sessions. "
                           + "BLOCKED: GOAT's approvals or live status didn't answer, so I can't say what's BLOCKED. "
                           + "Decisions: GOAT's approvals didn't answer, so I can't list the decisions waiting on you.")
        XCTAssertNil(text.range(of: #"\d+ (Command session|BLOCKED|decision)"#, options: .regularExpression), "no counts are made up")
    }

    func testCommandDownAndOldEngineAreDistinct() {
        var cache = DayBriefCache()
        var s = briefSnapshot(); s.today = nil; s.meetingError = "GOAT didn't answer for the next meeting."
        XCTAssertTrue(DayBriefComposer.compose(cache.ingest(s, now: briefNow), now: briefNow, tz: briefET)
            .hasPrefix("Sessions: Command didn't answer, so I can't read today's sessions."))
        var c2 = DayBriefCache()
        var o = briefSnapshot(); o.today = nil
        XCTAssertTrue(DayBriefComposer.compose(c2.ingest(o, now: briefNow), now: briefNow, tz: briefET)
            .hasPrefix("Sessions: this Mac's GOAT doesn't send today's sessions yet."))
    }

    func testParsersAreTolerantAndDropUnnamedRows() throws {
        let doc = try JSONSerialization.jsonObject(with: Data(#"{"ok":true,"today":[{"client":"Test Client Bravo","scheduled_at":"2026-10-19T18:00:00+00:00","duration_minutes":45},{"client":"  ","scheduled_at":"2026-10-19T15:00:00Z"},{"client":"Test Client Alpha","scheduled_at":"2026-10-19T13:30:00+00:00"},{"client":"X","scheduled_at":"nope"}]}"#.utf8)) as! [String: Any]
        XCTAssertEqual(EngineParse.today(doc)?.map(\.client), ["Test Client Alpha", "Test Client Bravo"])
        XCTAssertNil(EngineParse.today(["ok": false, "today": []]))
        XCTAssertNil(EngineParse.today(["ok": true]))                                 // an older engine: unavailable, not "none"
        let naive = EngineParse.docAt(["at": "2026-10-19T07:36:53"])
        XCTAssertNotNil(naive)
        XCTAssertEqual(EngineParse.docAt(["at": "2026-10-19T11:36:53+00:00"]), at("2026-10-19T11:36:53Z"))
        XCTAssertEqual(EngineParse.fixesNeeded(["fixes_needed": [["title": "t", "clients": ["Test Client Alpha"]]]]).first?.client, "Test Client Alpha")
    }
}

final class DayBriefCommandTests: XCTestCase {
    func testTypedAndSpokenFormsMatch() {
        for t in ["/day", "/DAY", "what's my day", "What’s my day?", "whats my day", "what is my day looking like?",
                  "Hey 3PO, what's my day", "what does my day look like today", "  what's   my day.  ", "brief me"] {
            XCTAssertTrue(DayBriefCommand.matches(t), t)
        }
        for t in ["/days", "what's my day's first meeting with Test Client Alpha", "start a meeting with Test Client Alpha",
                  "remember my day is busy", "day", ""] {
            XCTAssertFalse(DayBriefCommand.matches(t), t)
        }
    }
}

@MainActor final class DayBriefSpeechTests: XCTestCase {
    func testTypedShowsTextAndSpeaksOnlyWithVoiceOn() async {
        let t = FakeTransport(), sp = FakeSpeaker()
        var voiceOn = false
        let c = DayBriefController(speaker: sp, voiceOn: { voiceOn })
        let s = ThreePOStore(transport: t)
        s.dayBrief = { "2 Command sessions today: Test Client Alpha at 9:30 AM ET and Test Client Bravo at 2:00 PM ET." }
        s.onDayBrief = { c.deliver($0) }
        s.draft = "/day"; await s.send()
        XCTAssertEqual(s.transcript.messages.last?.text.hasPrefix("2 Command sessions today"), true)
        XCTAssertEqual(s.transcript.messages.last?.local, true)
        XCTAssertTrue(t.posts.isEmpty, "zero tokens: the brief never goes to the engine's 3PO stream")
        XCTAssertTrue(sp.spoken.isEmpty, "Voice off (the default): text only")
        voiceOn = true
        s.draft = "what's my day"; await s.send()
        XCTAssertEqual(sp.spoken.count, 1)
        XCTAssertTrue(c.speaking)
        sp.finishNaturally()
        XCTAssertFalse(c.speaking)
    }

    func testDictatedBriefGoesThroughTheSamePath() async {
        let sp = FakeSpeaker()
        let c = DayBriefController(speaker: sp, voiceOn: { true })
        let s = ThreePOStore(transport: FakeTransport())
        s.dayBrief = { "No Command sessions on today's schedule." }
        s.onDayBrief = { c.deliver($0) }
        await s.sendDictation("What's my day?")
        XCTAssertEqual(sp.spoken, ["No Command sessions on today's schedule."])
    }

    func testTheToggleInterruptsMidSpeechAndIsConsumed() {
        let sp = FakeSpeaker(), log = MemLog()
        let c = DayBriefController(speaker: sp, voiceOn: { true }, logger: log)
        XCTAssertFalse(c.interruptIfSpeaking(), "not speaking: the toggle does its usual start / stop")
        c.deliver("2 Command sessions today: Test Client Alpha at 9:30 AM ET.")
        XCTAssertTrue(c.speaking)
        XCTAssertTrue(c.interruptIfSpeaking(), "mid-speech: the press stops the speech")
        XCTAssertFalse(c.speaking)
        XCTAssertEqual(sp.stops, 1)
        XCTAssertFalse(c.interruptIfSpeaking(), "the next press goes back to the mic")
        XCTAssertTrue(log.lines.contains("brief interrupted=toggle"))
        XCTAssertFalse(log.lines.joined().contains("Test Client"), "logs never carry the brief's words")
    }

    func testALateFinishFromAnInterruptedUtteranceDoesNotFlipANewOne() {
        let sp = FakeSpeaker()
        let c = DayBriefController(speaker: sp, voiceOn: { true })
        c.deliver("one")
        let stale = sp.pending
        _ = c.interruptIfSpeaking()
        c.deliver("two")
        stale?()                                 // the first utterance's cancel callback lands late
        XCTAssertTrue(c.speaking)
    }

    func testVoiceOffSilencesAndNeverSpeaks() {
        let sp = FakeSpeaker()
        var on = true
        let c = DayBriefController(speaker: sp, voiceOn: { on })
        c.deliver("x"); on = false; c.silence()
        XCTAssertFalse(c.speaking); XCTAssertEqual(sp.stops, 1)
        XCTAssertFalse(c.deliver("y")); XCTAssertEqual(sp.spoken, ["x"])
    }
}

/// Source guards for the app side (ForceIQPeak isn't a test dependency).
final class DayBriefGuardTests: XCTestCase {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    func src(_ f: String) throws -> String { try String(contentsOf: Self.sources.appendingPathComponent(f), encoding: .utf8) }

    func testTheVoiceToggleChecksTheBriefFirst() throws {
        let v = try src("ForceIQPeak/Voice.swift")
        let toggle = try XCTUnwrap(v.range(of: "func toggle() {"))
        let rest = String(v[toggle.upperBound...])
        let i = try XCTUnwrap(rest.range(of: "if interrupt?() == true")), g = try XCTUnwrap(rest.range(of: "guard enabled else"))
        XCTAssertLessThan(i.lowerBound, g.lowerBound, "the toggle interrupts a speaking brief before anything else")
        let app = try src("ForceIQPeak/AppDelegate.swift")
        XCTAssertTrue(app.contains("voice.interrupt = { [weak self] in self?.brief.interruptIfSpeaking() ?? false }"))
        XCTAssertTrue(app.contains("voice.onDisabled = { [weak self] in self?.brief.silence() }"))
        XCTAssertTrue(app.contains("voiceOn: { [weak self] in self?.voice.enabled ?? false }"), "spoken only while Voice is on")
    }

    func testSpeechIsLocalAVSpeechSynthesizerOnly() throws {
        let s = try src("ForceIQPeak/DayBriefViews.swift")
        XCTAssertTrue(s.contains("AVSpeechSynthesizer()"))
        for bad in ["URLSession", "http", "URLRequest", "AVAudioFile", "write(to", "AVAudioRecorder", "Cloud", "upload("] {
            XCTAssertFalse(s.contains(bad), "the brief's speech stays on this Mac: \(bad)")
        }
        let core = try src("PeakCore/DayBrief.swift")
        XCTAssertFalse(core.contains("URLSession") || core.contains("transport."), "composition is pure")
    }

    func testBriefAndLightTextIsPureWhiteAndNoLiveActivity() throws {
        let s = try src("ForceIQPeak/DayBriefViews.swift")
        XCTAssertTrue(s.contains("Text(s.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white)"))
        XCTAssertFalse(s.contains("ProgressView") || s.contains("ActivityKit") || s.contains("Activity<"))
        for line in s.components(separatedBy: "\n") where line.contains("Text(") { XCTAssertFalse(line.contains("opacity")) }
        XCTAssertFalse(Brand.allowedTextHex.contains(Brand.redHex), "red is for shapes only")
    }
}

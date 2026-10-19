import CryptoKit
import Foundation
import RealityKit
import XCTest
@testable import PeakCore

// 3PO avatar: BOB Motion ForceIQ-Peak-3PO-v1. State mapping from the chat's transcript, the transition planner, the
// director, the rig timeline and curves, the tier fallback (rig → loops → static), and the bundle vs the pack MANIFEST.
let threePODir = peakDir.appendingPathComponent("Resources/threepo")

final class ThreePOAvatarStateTests: XCTestCase {
    func sig(_ f: (inout AvatarSignals) -> Void) -> AvatarSignals { var s = AvatarSignals(); f(&s); return s }

    func testIdleWhileWaiting() {
        XCTAssertEqual(AvatarStateMap.target(AvatarSignals()), .idle)
        XCTAssertEqual(AvatarStateMap.target(sig { $0.cards = 3; $0.replyHasText = true }), .idle)   // a finished turn
    }

    func testListeningOnlyWithTheVoiceFlag() {
        XCTAssertEqual(AvatarStateMap.target(sig { $0.micOn = true }), .idle)                       // voice off (default)
        XCTAssertEqual(AvatarStateMap.target(sig { $0.micOn = true; $0.voiceEnabled = true }), .listening)
        XCTAssertEqual(AvatarStateMap.target(sig { $0.micOn = true; $0.voiceEnabled = true; $0.streaming = true; $0.replyHasText = true }), .listening)
    }

    func testThinkingFromSendToFirstTokenIncludingConsultingOpus() {
        XCTAssertEqual(AvatarStateMap.target(sig { $0.streaming = true; $0.thinking = true }), .thinking)
        XCTAssertEqual(AvatarStateMap.target(sig { $0.streaming = true }), .thinking)                // no token yet
        XCTAssertEqual(AvatarStateMap.target(sig { $0.streaming = true; $0.replyHasText = true; $0.consultingOpus = true }), .thinking)
        XCTAssertEqual(AvatarStateMap.target(sig { $0.streaming = true; $0.replyHasText = true; $0.thinking = true }), .thinking)   // a tool call
    }

    func testTalkingWhileTokensStream() {
        XCTAssertEqual(AvatarStateMap.target(sig { $0.streaming = true; $0.replyHasText = true }), .talking)
    }

    func testMappingFollowsTheTranscriptReducer() {
        var t = ThreePOTranscript()
        t.models.pick = .auto
        XCTAssertEqual(AvatarStateMap.target(.from(t)), .idle)
        t.begin("why?")                                            // Auto: the gold 'consulting Opus' starts on send
        XCTAssertTrue(t.consultingOpus)
        XCTAssertEqual(AvatarStateMap.target(.from(t)), .thinking)
        t.apply(.start(route: "claude", modelAlias: "haiku", mode: "advisor", cached: true))
        t.apply(.advisor(consulting: true)); XCTAssertEqual(AvatarStateMap.target(.from(t)), .thinking)
        t.apply(.advisor(consulting: false)); XCTAssertEqual(AvatarStateMap.target(.from(t)), .thinking)   // still no token
        t.apply(.delta("The ")); XCTAssertEqual(AvatarStateMap.target(.from(t)), .talking)
        XCTAssertEqual(AvatarSignals.from(t).replyChars, 4)
        t.apply(.toolCall("status")); XCTAssertEqual(AvatarStateMap.target(.from(t)), .thinking)
        t.apply(.delta("title")); XCTAssertEqual(AvatarStateMap.target(.from(t)), .talking)
        let c = ProposalPolicy.card(from: ["id": "c1", "action": "rerender", "view_only": true])!
        t.apply(.proposal(c)); XCTAssertEqual(AvatarSignals.from(t).cards, 1)
        t.apply(.done(text: "", costUSD: 0, peakMTD: nil, warn: nil, firstTokenMs: nil))
        XCTAssertEqual(AvatarStateMap.target(.from(t)), .idle)
    }

    func testErrorAndDroppedStreamGoIdle() {
        var t = ThreePOTranscript(); t.begin("x")
        t.apply(.error(code: "rate_limited", message: "")); XCTAssertEqual(AvatarStateMap.target(.from(t)), .idle)
        var u = ThreePOTranscript(); u.begin("y"); u.endOfStream(); XCTAssertEqual(AvatarStateMap.target(.from(u)), .idle)
    }

    func testRefusalCardCountsAsACard() {
        var t = ThreePOTranscript(); t.begin("delete the clip")
        t.apply(.start(route: "refused", modelAlias: "", mode: "", cached: false))
        t.apply(.proposal(ProposalPolicy.card(from: ["id": "r1", "action": "delete_clip", "view_only": true])!))
        XCTAssertEqual(AvatarSignals.from(t).cards, 1)
    }

    func testPolicyPausesUnlessExpandedVisibleAndMotionAllowed() {
        XCTAssertTrue(AvatarPolicy.live(visible: true, globallyVisible: true, expanded: true, reduceMotion: false))
        XCTAssertFalse(AvatarPolicy.live(visible: true, globallyVisible: true, expanded: false, reduceMotion: false))   // collapsed
        XCTAssertFalse(AvatarPolicy.live(visible: false, globallyVisible: true, expanded: true, reduceMotion: false))
        XCTAssertFalse(AvatarPolicy.live(visible: true, globallyVisible: false, expanded: true, reduceMotion: false))
        XCTAssertFalse(AvatarPolicy.live(visible: true, globallyVisible: true, expanded: true, reduceMotion: true))
    }
}

final class ThreePOAvatarPlanTests: XCTestCase {
    func testRoutesGoThroughIdle() {
        XCTAssertEqual(AvatarPlanner.route(.idle, .idle), [])
        XCTAssertEqual(AvatarPlanner.route(.idle, .talking), [.transition(.idle, .talking)])
        XCTAssertEqual(AvatarPlanner.route(.listening, .idle), [.transition(.listening, .idle)])
        XCTAssertEqual(AvatarPlanner.route(.thinking, .talking), [.transition(.thinking, .idle), .transition(.idle, .talking)])
    }

    func testPlanAfterTheClipOnScreen() {
        XCTAssertEqual(AvatarPlanner.plan(after: .loop(.idle), to: .thinking), AvatarPlan(clips: [.transition(.idle, .thinking)], loop: .thinking))
        XCTAssertEqual(AvatarPlanner.plan(after: .transition(.idle, .thinking), to: .talking),
                       AvatarPlan(clips: [.transition(.thinking, .idle), .transition(.idle, .talking)], loop: .talking))
        XCTAssertEqual(AvatarPlanner.plan(after: .loop(.talking), to: .talking), AvatarPlan(clips: [], loop: .talking))
    }

    func testAlertIsOneFlashThenSettles() {
        XCTAssertEqual(AvatarPlanner.plan(after: .loop(.talking), to: .alert, then: .idle),
                       AvatarPlan(clips: [.transition(.talking, .idle), .transition(.idle, .alert), .once(.alert), .transition(.alert, .idle)], loop: .idle))
        XCTAssertEqual(AvatarPlanner.plan(after: .loop(.idle), to: .alert, then: .talking).clips.last, .transition(.idle, .talking))
        // replanned mid idle_to_alert: the flash still plays
        XCTAssertEqual(AvatarPlanner.plan(after: .transition(.idle, .alert), to: .idle).clips, [.once(.alert), .transition(.alert, .idle)])
        XCTAssertEqual(AvatarPlanner.plan(after: .once(.alert), to: .idle).clips, [.transition(.alert, .idle)])
    }

    func testClipNamesMatchThePack() {
        XCTAssertEqual(AvatarClip.loop(.idle).name, "idle")
        XCTAssertEqual(AvatarClip.transition(.idle, .listening).name, "idle_to_listening")
        XCTAssertEqual(AvatarClip.transition(.alert, .idle).endState, .idle)
    }

    func testDirectorReplansOnlyOnChange() {
        var d = ThreePOAvatarDirector()
        XCTAssertNil(d.update(AvatarSignals(), current: .loop(.idle)))
        let p = d.update(AvatarSignals(streaming: true), current: .loop(.idle))
        XCTAssertEqual(p, AvatarPlan(clips: [.transition(.idle, .thinking)], loop: .thinking))
        XCTAssertNil(d.update(AvatarSignals(streaming: true, thinking: true), current: .loop(.idle)))   // same state
        XCTAssertEqual(d.update(AvatarSignals(streaming: true, replyHasText: true), current: .loop(.thinking))?.loop, .talking)
    }

    func testDirectorFlashesOnANewCardAndKeepsItThroughReplans() {
        var d = ThreePOAvatarDirector()
        _ = d.update(AvatarSignals(streaming: true, replyHasText: true), current: .loop(.idle))
        let p = d.update(AvatarSignals(streaming: true, replyHasText: true, cards: 1), current: .loop(.talking))!
        XCTAssertTrue(p.clips.contains(.once(.alert))); XCTAssertEqual(p.loop, .talking); XCTAssertTrue(d.flashPending)
        // done lands before the flash is on screen: the replan keeps it
        let q = d.update(AvatarSignals(cards: 1), current: .loop(.talking))!
        XCTAssertTrue(q.clips.contains(.once(.alert))); XCTAssertEqual(q.loop, .idle)
        XCTAssertNil(d.update(AvatarSignals(cards: 1), current: .once(.alert)))
        XCTAssertFalse(d.flashPending)
        XCTAssertNil(d.update(AvatarSignals(cards: 1), current: .loop(.idle)))                 // same card: no second flash
    }

    func testNoFlashOverListeningOrForAClearedTranscript() {
        var d = ThreePOAvatarDirector()
        let l = d.update(AvatarSignals(cards: 1, voiceEnabled: true, micOn: true), current: .loop(.idle))
        XCTAssertEqual(l?.loop, .listening); XCTAssertFalse(l!.clips.contains(.once(.alert)))
        var e = ThreePOAvatarDirector()
        _ = e.update(AvatarSignals(cards: 2), current: .loop(.idle))
        _ = e.update(AvatarSignals(cards: 2), current: .once(.alert))
        XCTAssertNil(e.update(AvatarSignals(cards: 0), current: .loop(.idle)))
        XCTAssertEqual(e.update(AvatarSignals(cards: 1), current: .loop(.idle))?.clips.contains(.once(.alert)), true)
    }
}

final class ThreePOAvatarRigTests: XCTestCase {
    func testTimelineSwitchesOnlyAtTheLoopBoundary() {
        var t = AvatarTimeline(now: 0)
        t.apply(AvatarPlan(clips: [.transition(.idle, .thinking)], loop: .thinking))
        XCTAssertEqual(t.advance(to: 1.0), []); XCTAssertEqual(t.current, .loop(.idle))      // idle's 2.5 s pass finishes
        XCTAssertEqual(t.advance(to: 2.6), [.transition(.idle, .thinking)])
        XCTAssertEqual(t.advance(to: 2.5 + 1.0 / 3 + 0.01), [.loop(.thinking)])
        XCTAssertEqual(t.advance(to: 10), [])                                                  // keeps looping
        XCTAssertEqual(t.current, .loop(.thinking))
        XCTAssertLessThan(t.local(10), 2.0)
    }

    func testCurvesLoopSeamlesslyAndTransitionsJoinTheLoops() {
        for s in AvatarState.allCases where s != .alert {
            let T = ThreePOCurves.loopSeconds[s]!
            let a = ThreePOCurves.state(s, 0), b = ThreePOCurves.state(s, T)
            XCTAssertEqual(a.headYaw, b.headYaw, accuracy: 1e-6, s.rawValue); XCTAssertEqual(a.headPitch, b.headPitch, accuracy: 1e-6, s.rawValue)
            XCTAssertEqual(a.eyeGlow, b.eyeGlow, accuracy: 1e-6, s.rawValue)
            let into = ThreePOCurves.transition(.idle, s, u: 1), out = ThreePOCurves.transition(s, .idle, u: 0)
            XCTAssertEqual(into.headTilt, a.headTilt, accuracy: 1e-6); XCTAssertEqual(out.headTilt, a.headTilt, accuracy: 1e-6)
        }
        let settled = ThreePOCurves.state(.alert, 1.99)
        XCTAssertEqual(settled.goldFlash, 0, accuracy: 1e-3); XCTAssertEqual(settled.headPitch, 0, accuracy: 1e-2)   // holds neutral
        XCTAssertGreaterThan(ThreePOCurves.state(.alert, 0.05).goldFlash, 0.5)
        XCTAssertEqual(ThreePOCurves.state(.idle, 0).talkAmp, 0)                                // talk light off at rest
        XCTAssertEqual(ThreePOCurves.seconds(.transition(.idle, .alert)), 20.0 / 60, accuracy: 1e-9)
    }

    func testTalkLightFollowsTheStreamRate() {
        var m = TalkMeter()
        _ = m.tick(now: 0)
        var now = 0.0, chars = 0
        for _ in 0..<20 { now += 0.06; chars += 4; m.observe(chars: chars, now: now); _ = m.tick(now: now) }
        let fast = m.level
        XCTAssertGreaterThan(fast, 0.8)
        for _ in 0..<12 { now += 1.0 / 60; _ = m.tick(now: now) }                                 // a 0.2 s gap: still talking
        XCTAssertGreaterThan(m.level, 0.8)
        for _ in 0..<33 { now += 1.0 / 60; _ = m.tick(now: now) }                                 // 0.75 s with no tokens: quiet
        XCTAssertLessThan(m.level, 0.05)
        let quiet = ThreePOCurves.state(.talking, 0.5, talkDrive: 0), loud = ThreePOCurves.state(.talking, 0.5, talkDrive: 1)
        XCTAssertLessThan(quiet.talkAmp, loud.talkAmp)
        XCTAssertEqual(loud.talkAmp, ThreePOCurves.state(.talking, 0.5).talkAmp, accuracy: 1e-9)
    }

    func testTierFallsBackRigThenLoopsThenTheStaticMark() {
        func t(_ rig: Bool?, enabled: Bool = true, loops: Bool = true, still: Bool = true, rm: Bool = false, live: Bool = true) -> AvatarTier {
            AvatarTier.choose(rig: rig, rigEnabled: enabled, loops: loops, stillAvailable: still, reduceMotion: rm, live: live)
        }
        XCTAssertEqual(t(true), .rig)
        XCTAssertEqual(t(false), .loops)                    // the rig failed the load check or is missing
        XCTAssertEqual(t(nil), .loops)                      // still loading
        XCTAssertEqual(t(true, enabled: false), .loops)     // FORCEIQ_PEAK_3PO_RIG=0
        XCTAssertEqual(t(false, loops: false, still: false), .mark)
        XCTAssertEqual(t(nil, loops: false, still: false), .mark)
        XCTAssertEqual(t(true, rm: true), .still)           // Reduce Motion: one still frame
        XCTAssertEqual(t(true, still: false, rm: true), .mark)
        XCTAssertEqual(t(true, live: false), .still)        // hidden: nothing renders
    }

    @MainActor func testRigLoadsWithEveryNodeAndTalkLightAtZero() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("rig needs macOS 15") }
        switch await ThreePORigCheck.load(threePODir.appendingPathComponent("rig/3po.usdz")) {
        case .success(let (e, fixed)):
            XCTAssertEqual(fixed, 2)                                              // head/talk_light + talk_light_ring
            XCTAssertEqual(ThreePORigCheck.talkLightIntensities(e), [0, 0])
            for n in ThreePORigCheck.nodes { XCTAssertNotNil(e.findEntity(named: n), n) }
        case .failure(let f): XCTFail("rig did not load: \(f.reason)")
        }
    }

    @MainActor func testRigFallbackOnMissingOrBrokenAsset() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("rig needs macOS 15") }
        let none = await ThreePORigCheck.load(tmpRoot().appendingPathComponent("3po.usdz"))
        if case .failure(let f) = none { XCTAssertEqual(f, .missing) } else { XCTFail("missing file loaded") }
        let nilURL = await ThreePORigCheck.load(nil)
        if case .failure(let f) = nilURL { XCTAssertEqual(f, .missing) } else { XCTFail("nil url loaded") }
        let bad = tmpRoot().appendingPathComponent("3po.usdz")
        try Data("not a usdz".utf8).write(to: bad)
        let broken = await ThreePORigCheck.load(bad)
        guard case .failure(let f) = broken, case .loadError = f else { return XCTFail("a broken usdz must fail the load check") }
        let tier = AvatarTier.choose(rig: false, rigEnabled: true, loops: true, stillAvailable: true, reduceMotion: false, live: true)
        XCTAssertEqual(tier, .loops)
    }
}

final class ThreePOAvatarBundleTests: XCTestCase {
    var manifest: Data { try! Data(contentsOf: threePODir.appendingPathComponent("MANIFEST.json")) }

    func testManifestIsTheShippedPack() {
        XCTAssertEqual(md5Hex(manifest), "bf67596170da1025137b8fda5485369d")
        let p = ThreePOPack.load(manifest: manifest, root: nil)!
        XCTAssertEqual(p.fps, 60)
        XCTAssertEqual(p.frames["idle"], 150)
        for s in ["listening", "thinking", "talking", "alert"] { XCTAssertEqual(p.frames[s], 120, s); XCTAssertEqual(p.frames["idle_to_\(s)"], 20); XCTAssertEqual(p.frames["\(s)_to_idle"], 20) }
        XCTAssertEqual(p.frames.count, 13)
        XCTAssertTrue(p.isComplete)
        XCTAssertEqual(p.md5.count, 395)
        XCTAssertEqual(p.sizes, [64, 96, 128, 192, 512, 768])                          // in the pack
    }

    func testBundleCarriesOnlyWhatPeakUsesAndEveryMD5Matches() throws {
        let p = ThreePOPack.load(manifest: manifest, root: threePODir)!
        XCTAssertEqual(p.format, .hevcAlpha)
        XCTAssertEqual(p.sizes, [64])                                                   // 32 pt @2x
        XCTAssertEqual(p.pixelSize(points: 32, scale: 2), 64)
        XCTAssertEqual(ThreePOPack.load(manifest: manifest, root: threePODir, format: .h264Black)!.sizes, [])
        var shipped: [String] = []
        let en = FileManager.default.enumerator(at: threePODir, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let u as URL in en where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            shipped.append(String(u.path.dropFirst(threePODir.path.count + 1)))
        }
        let expected = Set(["MANIFEST.json", "rig/3po.usdz", ThreePOPack.stillPath(px: 64)]
                           + p.frames.keys.map { ThreePOPack.path(clip: $0, px: 64, format: .hevcAlpha) })
        XCTAssertEqual(Set(shipped), expected)
        XCTAssertEqual(shipped.count, 16)
        for rel in expected where rel != "MANIFEST.json" {
            XCTAssertEqual(md5Hex(try Data(contentsOf: threePODir.appendingPathComponent(rel))), p.md5[rel], rel)
        }
    }
}

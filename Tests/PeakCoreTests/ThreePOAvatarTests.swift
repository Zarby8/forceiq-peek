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
        XCTAssertEqual(md5Hex(manifest), "cbab0d470436659e8157d57195d34e01")                // v1.1 (adds fps120/)
        let o = try! JSONSerialization.jsonObject(with: manifest) as! [String: Any]
        XCTAssertEqual(o["version"] as? String, "v1.1")
        XCTAssertEqual(o["v1_manifest_md5"] as? String, "bf67596170da1025137b8fda5485369d")  // the v1 pack, unchanged
        let p = ThreePOPack.load(manifest: manifest, root: nil)!
        XCTAssertEqual(p.fps, 60)
        XCTAssertEqual(p.frames["idle"], 150)
        for s in ["listening", "thinking", "talking", "alert"] { XCTAssertEqual(p.frames[s], 120, s); XCTAssertEqual(p.frames["idle_to_\(s)"], 20); XCTAssertEqual(p.frames["\(s)_to_idle"], 20) }
        XCTAssertEqual(p.frames.count, 13)
        XCTAssertTrue(p.isComplete)
        XCTAssertEqual(p.md5.count, 633)                                                // v1's 395 + the add-on's 238
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
                           + p.frames.keys.map { ThreePOPack.path(clip: $0, px: 64, format: .hevcAlpha) }
                           + p.frames.keys.map { ThreePOPack.path(clip: $0, px: 64, format: .hevcAlpha, rate: .fps120) })
        XCTAssertEqual(Set(shipped), expected)
        XCTAssertEqual(shipped.count, 29)                                               // + the 13 fps120 clips
        for rel in expected where rel != "MANIFEST.json" {
            XCTAssertEqual(md5Hex(try Data(contentsOf: threePODir.appendingPathComponent(rel))), p.md5[rel], rel)
        }
    }
}

/// The no-hitch bar: every state change starts on screen within 100 ms (rig and loops), and fast flips coalesce
/// (latest wins, one blend / one frozen frame at a time, no queue build-up).
final class ThreePOAvatarSwitchTests: XCTestCase {
    /// Every clip the player can be on, at the start, middle and end of it.
    private var onScreen: [(AvatarClip, Double)] {
        var out: [(AvatarClip, Double)] = []
        var clips: [AvatarClip] = AvatarState.allCases.map { .loop($0) } + [.once(.alert)]
        for s in AvatarState.allCases where s != .idle { clips += [.transition(.idle, s), .transition(s, .idle)] }
        for c in clips { let T = ThreePOCurves.seconds(c); out += [(c, 0.01), (c, T / 2), (c, T - 0.02)] }
        return out
    }

    func testEveryStateChangeCutsAtOnceExceptTheFlashSettling() {
        for (c, _) in onScreen {
            for target in AvatarState.allCases where target != c.endState {
                let p = AvatarPlanner.plan(after: c, to: target)
                let flash: Bool = { switch c { case .once(.alert), .transition(.idle, .alert): return true; default: return false } }()
                let expect: AvatarSwitchMode = flash && p.loop == .idle ? .boundary : .cut
                XCTAssertEqual(AvatarSwitch.mode(current: c, plan: p), expect, "\(c.name) → \(target)")
            }
        }
        // a send, the mic or a new card during the flash still cuts it
        XCTAssertEqual(AvatarSwitch.mode(current: .once(.alert), plan: AvatarPlanner.plan(after: .once(.alert), to: .thinking)), .cut)
        XCTAssertEqual(AvatarSwitch.mode(current: .transition(.idle, .alert), plan: AvatarPlanner.plan(after: .transition(.idle, .alert), to: .listening)), .cut)
    }

    func testRigChangeStartsWithin100msFromAnyClipAndPhase() {
        for (c, phase) in onScreen {
            for target in AvatarState.allCases where target != c.endState {
                let p = AvatarPlanner.plan(after: c, to: target)
                guard AvatarSwitch.mode(current: c, plan: p) == .cut else { continue }
                var t = timeline(on: c, at: phase)
                let now = 100.0
                let before = t.params(now)
                let started = t.cut(p, now: now)
                XCTAssertEqual(started, p.clips.first ?? .loop(p.loop), "\(c.name) → \(target)")
                XCTAssertEqual(t.start, now)                                                          // the plan's clock starts now
                XCTAssertLessThan(ThreePOCurves.distance(t.params(now), before), 1e-9)               // no jump on the cut frame
                // by one display frame the pose is already moving toward the plan; by 100 ms it's 95 %+ of the way
                let k1 = ThreePOCurves.easeOut((1.0 / 60) / AvatarSwitch.fade)
                XCTAssertGreaterThan(k1, 0.2)
                let at100 = t.params(now + AvatarSwitch.maxStart)
                let pure = ThreePOCurves.params(started, AvatarSwitch.maxStart)
                let gap = ThreePOCurves.distance(before, pure)
                XCTAssertLessThanOrEqual(ThreePOCurves.distance(at100, pure), 0.06 * gap + 1e-9, "\(c.name) → \(target)")
                var u = t; u.advance(to: now + AvatarSwitch.fade + 0.001)
                XCTAssertNil(u.fadeFrom)                                                              // one short blend, then the plan's own curves
            }
        }
    }

    func testRigFastFlipsCoalesceLatestWins() {
        var d = ThreePOAvatarDirector(), t = AvatarTimeline(now: 0)
        _ = t.advance(to: 1.234)
        let sends: [(Double, AvatarSignals)] = [
            (1.300, AvatarSignals(streaming: true, thinking: true)),                     // send
            (1.360, AvatarSignals(streaming: true, replyHasText: true)),                 // first token 60 ms later
            (1.420, AvatarSignals(streaming: true, thinking: true, replyHasText: true)), // a tool, 60 ms after that
            (1.480, AvatarSignals(streaming: true, replyHasText: true)),                 // talking again
        ]
        var last = t.params(1.234)
        var cuts = 0
        for (now, s) in sends {
            let shown = t.params(now)
            XCTAssertLessThan(ThreePOCurves.distance(shown, last), 0.6)                 // continuous between flips
            guard let p = d.update(s, current: t.current) else { continue }
            XCTAssertEqual(AvatarSwitch.mode(current: t.current, plan: p), .cut)
            t.cut(p, now: now); cuts += 1
            XCTAssertLessThan(ThreePOCurves.distance(t.params(now), shown), 1e-9)       // each cut starts from what's on screen
            XCTAssertLessThanOrEqual(t.queue.count, 1)                                 // nothing stacks up
            last = t.params(now)
        }
        XCTAssertEqual(cuts, 4)
        XCTAssertEqual(d.settled, .talking)                                             // latest wins
        XCTAssertEqual(t.settle, .talking)
        for f in stride(from: 1.48, to: 2.4, by: 1.0 / 60) {                           // and it lands there without a hitch
            for c in t.advance(to: f) { _ = c }
            let p = t.params(f); XCTAssertLessThan(ThreePOCurves.distance(p, last), 0.5, "t=\(f)"); last = p
        }
        _ = t.advance(to: 3)
        XCTAssertEqual(t.current, .loop(.talking))
    }

    func testCrossfadeFreezesOnceAndFadesFromTheFirstNewFrame() {
        var x = AvatarCrossfade()
        XCTAssertEqual(x.opacity(0), 0)
        XCTAssertEqual(x.cut(now: 10), .frame)
        XCTAssertEqual(x.opacity(10.01), 1)                         // the frame on screen holds while the new clip loads
        let wait = x.ready(now: 10.012)
        XCTAssertEqual(wait!, 0.012, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(wait!, AvatarSwitch.maxStart)
        XCTAssertLessThan(x.opacity(10.012 + 1.0 / 60), 0.8)        // the first frame after it shows already moves
        XCTAssertLessThan(x.opacity(10.012 + 0.1), 0.06)
        XCTAssertTrue(x.tick(now: 10.1))
        XCTAssertFalse(x.tick(now: 10.012 + AvatarSwitch.fade + 0.001))
        XCTAssertEqual(x.phase, .none); XCTAssertEqual(x.opacity(11), 0)
    }

    func testCrossfadeFastFlipsCoalesceLatestWins() {
        var x = AvatarCrossfade()
        XCTAssertEqual(x.cut(now: 0), .frame)
        XCTAssertEqual(x.cut(now: 0.005), .keep)                    // before the new clip shows: retarget under the same frame
        XCTAssertEqual(x.phase, .armed(since: 0))                   // the hold is still bounded from the first cut
        x.ready(now: 0.02)
        guard case .composite(let a) = x.cut(now: 0.06) else { return XCTFail("mid-fade: flatten what's on screen") }
        XCTAssertEqual(a, 1 - ThreePOCurves.easeOut(0.04 / AvatarSwitch.fade), accuracy: 1e-9)
        XCTAssertEqual(x.phase, .armed(since: 0.06))                // one overlay, held at full (it IS the screen)
        XCTAssertEqual(x.opacity(0.07), 1)
        x.ready(now: 0.075)
        XCTAssertTrue(x.tick(now: 0.1))
        XCTAssertFalse(x.tick(now: 0.075 + AvatarSwitch.fade + 0.001))
        // a slow clip never pins the frozen frame
        var y = AvatarCrossfade(); _ = y.cut(now: 0)
        XCTAssertTrue(y.tick(now: AvatarCrossfade.readyDeadline + 0.001))
        XCTAssertEqual(y.phase, .fading(start: AvatarCrossfade.readyDeadline + 0.001))
        XCTAssertNil(y.ready(now: 0.3))
    }

    private func timeline(on c: AvatarClip, at phase: Double) -> AvatarTimeline {
        AvatarTimeline(current: c, start: 100 - phase, settle: c.loopState)
    }
}

private extension AvatarClip {
    var isLoop: Bool { if case .loop = self { return true }; return false }
    var loopState: AvatarState { endState == .alert ? .idle : endState }
}

/// The rig parks only in a settled, steady idle with a full captured pass, and the playback stays in phase.
final class ThreePORigParkTests: XCTestCase {
    func testParksOnlyWhenSteadyIdleCapturedAndSettled() {
        XCTAssertEqual(AvatarIdleCache.bins, 50)                                   // 2.5 s idle at 20 fps
        XCTAssertTrue(AvatarIdleCache.shouldPark(steadyIdle: true, complete: true, settledFor: AvatarIdleCache.settle))
        XCTAssertFalse(AvatarIdleCache.shouldPark(steadyIdle: true, complete: true, settledFor: AvatarIdleCache.settle - 0.01))
        XCTAssertFalse(AvatarIdleCache.shouldPark(steadyIdle: true, complete: false, settledFor: 10))
        XCTAssertFalse(AvatarIdleCache.shouldPark(steadyIdle: false, complete: true, settledFor: 10))
    }

    func testBinsFollowTheRigClockAcrossPasses() {
        XCTAssertEqual(AvatarIdleCache.bin(local: 0), 0)
        XCTAssertEqual(AvatarIdleCache.bin(local: 0.049), 0)
        XCTAssertEqual(AvatarIdleCache.bin(local: 0.05), 1)
        XCTAssertEqual(AvatarIdleCache.bin(local: 2.499), 49)
        XCTAssertEqual(AvatarIdleCache.bin(local: 2.5 + 0.06), 1)                  // a long parked stretch stays in phase
        XCTAssertEqual(AvatarIdleCache.bin(local: 250.0 + 1.23), AvatarIdleCache.bin(local: 1.23))
    }

    func testSteadyIdleIsTheOnlyParkableTimeline() {
        var t = AvatarTimeline(now: 0)
        let steady = { (t: AvatarTimeline) in t.current == .loop(.idle) && t.fadeFrom == nil && t.queue.isEmpty }
        XCTAssertTrue(steady(t))
        t.cut(AvatarPlan(clips: [.transition(.idle, .thinking)], loop: .thinking), now: 1)
        XCTAssertFalse(steady(t))
        t.cut(AvatarPlan(clips: [.transition(.thinking, .idle)], loop: .idle), now: 2)
        _ = t.advance(to: 2.2); XCTAssertFalse(steady(t))                         // blending / transition in flight
        _ = t.advance(to: 2.5); XCTAssertTrue(steady(t))
    }
}

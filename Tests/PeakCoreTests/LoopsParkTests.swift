import Foundation
import XCTest
@testable import PeakCore

// The loops tier (FORCEIQ_PEAK_3PO_RIG=0, or the rig failed) parks a steady idle the way the rig does: a playing
// AVPlayer cost ~3.5-4.4 % CPU with the chat open and idle (CoreMedia's queue, decoder round trips and image queue every
// frame). The runtime check is peak/scripts/cpu_idle_check.sh --tier loops (same 2.0 % / 0.5 % limits as the rig).

final class AvatarLoopParkTests: XCTestCase {
    private func park(_ c: AvatarClip = .loop(.idle), loop: AvatarState = .idle, overlay: Bool = false, live: Bool = true,
                      ready: Bool = true, settled: Double = 0.5) -> Bool {
        AvatarLoopPark.shouldPark(current: c, loopState: loop, overlayUp: overlay, live: live, framesReady: ready, settledFor: settled)
    }

    func testParksOnlyASteadyLiveIdleLoopAfterTheRigsSettle() {
        XCTAssertTrue(park())
        XCTAssertEqual(AvatarIdleCache.settle, 0.5)
        XCTAssertFalse(park(settled: 0.49))
        XCTAssertFalse(park(overlay: true))                                  // a crossfade is up
        XCTAssertFalse(park(live: false))                                    // hidden / collapsed: the player is paused anyway
        XCTAssertFalse(park(ready: false))                                   // frames not decoded yet
        XCTAssertFalse(park(loop: .talking))                                 // idle now, but settling into another state
        for s in AvatarState.allCases where s != .idle { XCTAssertFalse(park(.loop(s), loop: s), s.rawValue) }
        XCTAssertFalse(park(.once(.alert)))
        XCTAssertFalse(park(.transition(.talking, .idle)))
        XCTAssertFalse(park(.transition(.idle, .thinking), loop: .thinking))
    }

    func testParkedFrameIsThePlayersFrameAndStaysInPhase() {
        let n = 150, fps = 60.0                                               // the pack's idle: 150 frames at 60 fps
        XCTAssertEqual(AvatarLoopPark.frame(local: 0, frames: n, fps: fps), 0)
        XCTAssertEqual(AvatarLoopPark.frame(local: 1.0 / 60, frames: n, fps: fps), 1)
        XCTAssertEqual(AvatarLoopPark.frame(local: 0.0166, frames: n, fps: fps), 0)
        XCTAssertEqual(AvatarLoopPark.frame(local: 2.4999, frames: n, fps: fps), 149)
        XCTAssertEqual(AvatarLoopPark.frame(local: 2.5, frames: n, fps: fps), 0)
        XCTAssertEqual(AvatarLoopPark.frame(local: 2.5 + 0.5, frames: n, fps: fps), 30)
        XCTAssertEqual(AvatarLoopPark.frame(local: 3600 + 1.25, frames: n, fps: fps), 75)   // an hour parked stays in phase
        XCTAssertEqual(AvatarLoopPark.frame(local: -0.5, frames: n, fps: fps), 120)
        for k in 0..<n { XCTAssertEqual(AvatarLoopPark.frame(local: Double(k) / fps, frames: n, fps: fps), k) }
        XCTAssertEqual(AvatarLoopPark.frame(local: 1, frames: 0, fps: fps), 0)
    }

    func testOnlyAFullDecodeParks() {
        XCTAssertTrue(AvatarLoopPark.complete(decoded: 150, manifest: 150))
        XCTAssertFalse(AvatarLoopPark.complete(decoded: 149, manifest: 150))
        XCTAssertFalse(AvatarLoopPark.complete(decoded: 0, manifest: 0))
        XCTAssertFalse(AvatarLoopPark.complete(decoded: 150, manifest: nil))
    }
}

/// Source guard: the loops player parks, pauses while parked, never runs the park and the player at once, and the
/// CPU check covers the loops tier with the same limits.
final class LoopsParkGuardTests: XCTestCase {
    private var player: String { try! String(contentsOf: peakDir.appendingPathComponent("Sources/ForceIQPeak/ThreePOAvatar.swift"), encoding: .utf8) }
    private var script: String { try! String(contentsOf: peakDir.appendingPathComponent("scripts/cpu_idle_check.sh"), encoding: .utf8) }

    private func body(_ s: String, from a: String, to b: String) throws -> String {
        let r0 = try XCTUnwrap(s.range(of: a), a), r1 = try XCTUnwrap(s.range(of: b, range: r0.upperBound..<s.endIndex), b)
        return String(s[r0.lowerBound..<r1.lowerBound])
    }

    func testPlayerParksTheIdleLoop() throws {
        let p = player
        XCTAssertTrue(p.contains("AvatarLoopPark.shouldPark("), "the loops player must park a steady idle")
        let park = try body(p, from: "private func tryPark()", to: "private func parkedFrame(")
        XCTAssertTrue(park.contains("CAKeyframeAnimation(keyPath: \"contents\")"), "the parked loop is a Core Animation animation")
        XCTAssertTrue(park.contains("player.pause()"), "parked: the player pauses (no CoreMedia work per frame)")
        XCTAssertTrue(park.contains("playerLayer.isHidden = true"), "parked and playing layers never both show")
        XCTAssertTrue(park.contains("AvatarIdleCache.settle") || p.contains("AvatarIdleCache.settle + "), "the rig's settle")
        let unpark = try body(p, from: "private func unpark(resume: Bool)", to: "private func loadIdleFrames()")
        XCTAssertTrue(unpark.contains("playerLayer.isHidden = false") && unpark.contains("parkLayer.removeAllAnimations()"))
    }

    func testEveryChangeUnparksFirst() throws {
        let p = player
        let cut = try body(p, from: "private func cut(_ plan: AvatarPlan)", to: "private func queue(_ plan: AvatarPlan)")
        XCTAssertTrue(cut.contains("unpark(resume: false)"))
        XCTAssertLessThan(try XCTUnwrap(cut.range(of: "snap = frameOnScreen()")).lowerBound, try XCTUnwrap(cut.range(of: "unpark(resume: false)")).lowerBound,
                          "the parked frame becomes the cut's frozen frame before the player comes back")
        let q = try body(p, from: "private func queue(_ plan: AvatarPlan)", to: "private func insert(")
        XCTAssertTrue(q.contains("unpark(resume: true)"))
        XCTAssertTrue(p.contains("if parked, let f = parkedFrame("), "frameOnScreen reads the parked frame while parked")
        XCTAssertTrue(p.contains("player.rate == 0 && !parked"), "update() must not restart a parked player")
    }

    func testCPUCheckCoversTheLoopsTierAtTheSameLimits() {
        let s = script
        XCTAssertTrue(s.contains("--tier) TIER="))
        XCTAssertTrue(s.contains("[ \"$TIER\" = loops ] && RIG_ENV=0"))
        XCTAssertTrue(s.contains("FORCEIQ_PEAK_3PO_RIG=\"$RIG_ENV\""))
        XCTAssertTrue(s.contains("for t in rig loops; do for m in expanded collapsed; do"))
        XCTAssertTrue(s.contains("MAX=0.5 || MAX=2.0"), "limits: collapsed 0.5 %, expanded 2.0 % for every tier")
        XCTAssertTrue(s.contains("3po loops parked"))
    }
}

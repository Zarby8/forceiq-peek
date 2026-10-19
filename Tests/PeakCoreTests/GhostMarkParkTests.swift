import Foundation
import XCTest
@testable import PeakCore

// The Ghost mark (BOB pack, AVPlayerLooper) was ~1.1 % of Peak's ~1.15 % idle CPU with the chat open: the same build
// with the mark's video swapped for the placeholder measured 0.06 %. It now parks its steady loop like the 3PO droid
// (AvatarLoopPark). The runtime check is peak/scripts/cpu_idle_check.sh (waits for "ghost mark parked"; 2.0 % / 0.5 %).

final class GhostMarkParkTests: XCTestCase {
    private func pb(_ mode: GhostPlayback.Mode, frames: Int = 60, fps: Double = 24, intro: ClosedRange<Int>? = nil,
                    loop: ClosedRange<Int>? = nil, once: ClosedRange<Int>? = nil) -> GhostPlayback {
        GhostPlayback(asset: "x", fps: fps, frames: frames, mode: mode, intro: intro, loop: loop, once: once, holdFrame: nil, thenIdle: false)
    }

    func testParksOnlyASteadyPlayingLoopAfterTheSettle() {
        let idle = pb(.loop, loop: 0...59)
        XCTAssertTrue(GhostMarkPark.shouldPark(idle, inLoop: true, playing: true, framesReady: true, settledFor: 0.5))
        XCTAssertFalse(GhostMarkPark.shouldPark(idle, inLoop: true, playing: true, framesReady: true, settledFor: 0.49))
        XCTAssertFalse(GhostMarkPark.shouldPark(idle, inLoop: true, playing: false, framesReady: true, settledFor: 1))
        XCTAssertFalse(GhostMarkPark.shouldPark(idle, inLoop: true, playing: true, framesReady: false, settledFor: 1))
        let working = pb(.introThenLoop, frames: 72, intro: 0...15, loop: 16...71)
        XCTAssertFalse(GhostMarkPark.shouldPark(working, inLoop: false, playing: true, framesReady: true, settledFor: 1)) // intro
        XCTAssertTrue(GhostMarkPark.shouldPark(working, inLoop: true, playing: true, framesReady: true, settledFor: 1))
        for m in [GhostPlayback.Mode.oneShot, .oneShotHold] {
            XCTAssertNil(GhostMarkPark.loopRange(pb(m, once: 0...51)))
            XCTAssertFalse(GhostMarkPark.shouldPark(pb(m, once: 0...51), inLoop: true, playing: true, framesReady: true, settledFor: 9))
        }
    }

    func testLoopRangeAndFullDecode() {
        XCTAssertEqual(GhostMarkPark.loopRange(pb(.loop)), 0...59)                  // no loop range: the whole clip
        XCTAssertEqual(GhostMarkPark.loopRange(pb(.introThenLoop, frames: 68, intro: 0...19, loop: 20...67)), 20...67)
        XCTAssertNil(GhostMarkPark.loopRange(pb(.loop, frames: 10, loop: 0...10)))  // past the clip: never park
        XCTAssertTrue(GhostMarkPark.complete(decoded: 60, pb(.loop)))
        XCTAssertFalse(GhostMarkPark.complete(decoded: 59, pb(.loop)))
        XCTAssertTrue(GhostMarkPark.complete(decoded: 48, pb(.introThenLoop, frames: 68, intro: 0...19, loop: 20...67)))
        XCTAssertFalse(GhostMarkPark.complete(decoded: 52, pb(.oneShot, once: 0...51)))
    }

    func testParkedFrameMatchesThePlayersItemTime() {
        let idle = pb(.loop, loop: 0...59)
        for k in 0..<60 { XCTAssertEqual(GhostMarkPark.frame(itemTime: Double(k) / 24, idle), k) }
        XCTAssertEqual(GhostMarkPark.frame(itemTime: 2.5, idle), 0)
        XCTAssertEqual(GhostMarkPark.frame(itemTime: 3600 + 1.0, idle), 24)          // an hour parked stays in phase
        let working = pb(.introThenLoop, frames: 72, intro: 0...15, loop: 16...71)
        XCTAssertEqual(GhostMarkPark.frame(itemTime: 16.0 / 24, working), 0)          // the loop's first frame
        XCTAssertEqual(GhostMarkPark.frame(itemTime: 71.0 / 24, working), 55)
        XCTAssertEqual(GhostMarkPark.frame(itemTime: 72.0 / 24, working), 0)
    }

    /// The shipped pack: every looping state has a loop range that parks; one-shots don't.
    func testShippedPackLoopsAllPark() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/bob")
        let pack = try XCTUnwrap(GhostPack.load(manifest: Data(contentsOf: root.appendingPathComponent("MANIFEST.json")), root: root))
        let idle = try XCTUnwrap(pack.playback["idle"])
        XCTAssertEqual(GhostMarkPark.loopRange(idle)?.count, 60)
        for (name, p) in pack.playback {
            switch p.mode {
            case .loop, .introThenLoop: XCTAssertNotNil(GhostMarkPark.loopRange(p), name)
            case .oneShot, .oneShotHold: XCTAssertNil(GhostMarkPark.loopRange(p), name)
            }
        }
    }
}

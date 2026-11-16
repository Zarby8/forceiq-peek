import Foundation
import PeakCore
import XCTest

/// The GHOST character pack (ForceIQ-Peek-GHOST-v1, Resources/ghost): Chris's approved ghost-on-a-ring
/// avatar as a selectable mark (FORCEIQ_PEAK_MARK=ghost). Same discipline as the BOB pack tests:
/// the manifest drives everything, every shipped file's MD5 matches, only the used sizes ship.
final class GhostAvatarPackTests: XCTestCase {
    let ghost = peakDir.appendingPathComponent("Resources/ghost")
    var manifest: [String: Any] { try! JSONSerialization.jsonObject(with: Data(contentsOf: ghost.appendingPathComponent("MANIFEST.json"))) as! [String: Any] }
    var pack: GhostPack { GhostPack.load(manifest: try! Data(contentsOf: ghost.appendingPathComponent("MANIFEST.json")), root: ghost)! }

    func testTheGhostPackLoadsWithItsOwnPrefix() {
        XCTAssertTrue(pack.pack.contains("GHOST"), pack.pack)
        XCTAssertEqual(pack.filePrefix, "peak-ghost-")
        XCTAssertEqual(pack.sizes, [64, 128])
        XCTAssertEqual(pack.file(for: .idle, px: 64, format: .h264Black), "h264-black/peak-ghost-idle-64.mp4")
        XCTAssertEqual(pack.file(for: .attention, px: 128, format: .h264Black), "h264-black/peak-ghost-waiting-128.mp4")
    }

    /// The six approved poses mapped onto Peek's mark states. typing has no pose of its own in the
    /// grid, so it rides the working loop; sleeping is the crescent pose (bottom-right cell), reached
    /// from the card model's inactivity overlay (GhostState.sleeping).
    func testStateMappingMatchesTheApprovedPoses() {
        XCTAssertEqual(pack.stateMap["idle"], "idle")          // fierce idle
        XCTAssertEqual(pack.stateMap["working"], "working")    // green dots trailing
        XCTAssertEqual(pack.stateMap["attention"], "waiting")  // looking up, gold rays
        XCTAssertEqual(pack.stateMap["typing"], "working")     // streaming a reply: the working loop
        XCTAssertEqual(pack.stateMap["receipt"], "done")       // happy, sparkles
        XCTAssertEqual(pack.stateMap["error"], "failed")       // startled
        XCTAssertEqual(pack.stateMap["sleeping"], "sleeping")  // gold crescent
    }

    func testPlaybackComesFromTheManifest() {
        for s in [GhostState.idle, .working, .attention, .typing, .sleeping] {
            let pb = pack.playback(for: s)!
            XCTAssertEqual(pb.mode, .loop, s.rawValue)
            XCTAssertEqual(pb.frames, 118, s.rawValue)         // 60 forward + 58 ping-pong return
            XCTAssertEqual(pb.loop, 0...117, s.rawValue)
            XCTAssertEqual(pb.fps, 24, s.rawValue)
        }
        let done = pack.playback(for: .receipt)!
        XCTAssertEqual(done.mode, .oneShot); XCTAssertTrue(done.thenIdle); XCTAssertEqual(done.frames, 60)
        let failed = pack.playback(for: .error)!
        XCTAssertEqual(failed.mode, .oneShotHold); XCTAssertEqual(failed.holdFrame, 59); XCTAssertEqual(failed.frames, 60)
    }

    func testBundledFilesMatchManifestMD5AndOnlyUsedSizesShip() throws {
        let shipped = try FileManager.default.contentsOfDirectory(atPath: ghost.appendingPathComponent("h264-black").path).sorted()
        XCTAssertEqual(shipped.count, 12)                      // six pose assets × two sizes
        for s in GhostState.allCases {
            for px in pack.sizes {
                let rel = pack.file(for: s, px: px, format: .h264Black)!
                let data = try Data(contentsOf: ghost.appendingPathComponent(rel))
                XCTAssertEqual(md5Hex(data), pack.md5[rel], rel)
            }
        }
        // The sleeping pose is one of the mapped states above; check its files explicitly too.
        for px in pack.sizes {
            let rel = "h264-black/peak-ghost-sleeping-\(px).mp4"
            let data = try Data(contentsOf: ghost.appendingPathComponent(rel))
            XCTAssertEqual(md5Hex(data), pack.md5[rel], rel)
        }
    }

    /// A manifest without file_prefix keeps the BOB default, so the shipped BOB pack is untouched.
    func testMissingPrefixDefaultsToBob() throws {
        var m = manifest
        m.removeValue(forKey: "file_prefix")
        let p = GhostPack.load(manifest: try JSONSerialization.data(withJSONObject: m), root: nil)!
        XCTAssertEqual(p.filePrefix, "peak-bob-")
        XCTAssertEqual(p.file(for: .idle, px: 64, format: .h264Black), "h264-black/peak-bob-idle-64.mp4")
    }
}

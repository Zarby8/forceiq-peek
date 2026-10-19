import AVFoundation
import Foundation
import XCTest
@testable import PeakCore

// 3PO at 120 fps (BOB Motion ForceIQ-Peek-3PO v1.1 add-on): the rate follows the screen Peek is on (120 only at
// ≥ 120 Hz, 60 is the default and the fallback), the add-on's manifest and the bundled fps120 clips, and the rig's
// parked idle at each rate. The Mac running these has whatever screens it has; the 120 path is driven by injected
// maximumFramesPerSecond values.

final class AvatarFrameRateChoiceTests: XCTestCase {
    func testOnlyA120HzScreenGets120() {
        XCTAssertEqual(AvatarFrameRate.choose(screenMaxFPS: 120, has120: true), .fps120)   // ProMotion, lid open
        XCTAssertEqual(AvatarFrameRate.choose(screenMaxFPS: 144, has120: true), .fps120)
        for hz in [0, 24, 30, 48, 50, 59, 60, 90, 100, 119] {
            XCTAssertEqual(AvatarFrameRate.choose(screenMaxFPS: hz, has120: true), .fps60, "\(hz) Hz")
        }
        XCTAssertEqual(AvatarFrameRate.choose(screenMaxFPS: nil, has120: true), .fps60)    // no screen yet
    }

    func testSixtyIsTheFallbackWithoutA120Set() {
        XCTAssertEqual(AvatarFrameRate.choose(screenMaxFPS: 120, has120: false), .fps60)
        XCTAssertEqual(AvatarFrameRate.choose(screenMaxFPS: 60, has120: false), .fps60)
    }

    func testOverridePinsSixtyAndNeverRaisesAbovetheScreen() {
        XCTAssertEqual(AvatarFrameRate.choose(screenMaxFPS: 120, has120: true, override: "60"), .fps60)
        XCTAssertEqual(AvatarFrameRate.choose(screenMaxFPS: 120, has120: true, override: " 60 "), .fps60)
        XCTAssertEqual(AvatarFrameRate.choose(screenMaxFPS: 60, has120: true, override: "120"), .fps60)
        XCTAssertEqual(AvatarFrameRate.choose(screenMaxFPS: 120, has120: true, override: "120"), .fps120)
        XCTAssertEqual(AvatarFrameRate.choose(screenMaxFPS: 120, has120: true, override: ""), .fps120)
    }

    /// Peek moving between the built-in ProMotion panel and the 60 Hz Studio Displays (or the lid closing).
    func testMovingBetweenScreensFollowsEachScreen() {
        let path: [Int?] = [120, 60, 120, nil, 60, 120]
        XCTAssertEqual(path.map { AvatarFrameRate.choose(screenMaxFPS: $0, has120: true) },
                       [.fps120, .fps60, .fps120, .fps60, .fps60, .fps120])
        XCTAssertEqual(path.map { AvatarFrameRate.choose(screenMaxFPS: $0, has120: false) }, Array(repeating: .fps60, count: path.count))
    }

    func testRateValues() {
        XCTAssertEqual(AvatarFrameRate.fps60.fps, 60)
        XCTAssertEqual(AvatarFrameRate.fps120.fps, 120)
    }
}

final class ThreePO120PackTests: XCTestCase {
    var manifest: Data { try! Data(contentsOf: threePODir.appendingPathComponent("MANIFEST.json")) }

    func testAddOnTimingIsTheSixtyPackDoubled() {
        let p60 = ThreePOPack.load(manifest: manifest, root: nil)!
        let p = ThreePOPack.load(manifest: manifest, root: nil, rate: .fps120)!
        XCTAssertEqual(p.rate, .fps120)
        XCTAssertEqual(p.fps, 120)
        XCTAssertEqual(p.version, "v1.1")
        XCTAssertEqual(p.frames["idle"], 300)
        for s in ["listening", "thinking", "talking", "alert"] {
            XCTAssertEqual(p.frames[s], 240, s)
            XCTAssertEqual(p.frames["idle_to_\(s)"], 40, s)
            XCTAssertEqual(p.frames["\(s)_to_idle"], 40, s)
        }
        XCTAssertEqual(p.frames.count, 13)
        XCTAssertEqual(Set(p.frames.keys), Set(p60.frames.keys))
        XCTAssertEqual(p.loops, p60.loops)
        XCTAssertEqual(p.loops, Set(AvatarState.allCases.map(\.rawValue)))
        XCTAssertTrue(p.isComplete)
        for (k, f) in p60.frames { XCTAssertEqual(p.frames[k], 2 * f, k) }
        // Same durations: a clip swapped at a boundary keeps the queue's timing, and the curves (seconds) are shared.
        var clips: [AvatarClip] = AvatarState.allCases.map { .loop($0) }
        for s in AvatarState.allCases where s != .idle { clips += [.transition(.idle, s), .transition(s, .idle)] }
        for c in clips {
            XCTAssertEqual(p.seconds(c), p60.seconds(c), accuracy: 1e-9, c.name)
            XCTAssertEqual(p.seconds(c), ThreePOCurves.seconds(c), accuracy: 0.001, c.name)
        }
        XCTAssertEqual(p.sizes, [64, 96, 128, 192, 512, 768])                          // in the add-on
    }

    func testBundleCarriesOnlyThe64pxHevcAlpha120Set() throws {
        let p = ThreePOPack.load(manifest: manifest, root: threePODir, rate: .fps120)!
        XCTAssertEqual(p.format, .hevcAlpha)
        XCTAssertEqual(p.sizes, [64])
        XCTAssertEqual(p.path(.loop(.idle), px: 64), "fps120/hevc_alpha/64/3po_idle_64_hevc_alpha.mov")
        XCTAssertEqual(p.path(.transition(.idle, .talking), px: 64), "fps120/hevc_alpha/64/3po_idle_to_talking_64_hevc_alpha.mov")
        XCTAssertEqual(ThreePOPack.load(manifest: manifest, root: threePODir, format: .h264Black, rate: .fps120)!.sizes, [])
        let dir = threePODir.appendingPathComponent("fps120")
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])!
        var shipped: [String] = [], bytes = 0
        for case let u as URL in en where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let rel = "fps120/" + String(u.path.dropFirst(dir.path.count + 1))
            shipped.append(rel)
            let d = try Data(contentsOf: u)
            bytes += d.count
            XCTAssertEqual(md5Hex(d), p.md5[rel], rel)
        }
        XCTAssertEqual(Set(shipped), Set(p.frames.keys.map { p.path(clip: $0) }))
        XCTAssertEqual(shipped.count, 13)
        XCTAssertLessThan(bytes, 512 * 1024)                                             // the 120 set stays small
    }

    /// The clips themselves (not just the manifest): 120 fps, and the manifest's frame count and duration.
    func testBundledClipsAre120fpsWithTheManifestFrameCounts() async throws {
        let p = ThreePOPack.load(manifest: manifest, root: threePODir, rate: .fps120)!
        for (name, frames) in p.frames {
            let u = threePODir.appendingPathComponent(p.path(clip: name))
            let a = AVURLAsset(url: u)
            let track = try await a.loadTracks(withMediaType: .video).first
            let t = try XCTUnwrap(track, name)
            let fps = try await t.load(.nominalFrameRate)
            let dur = try await a.load(.duration).seconds
            XCTAssertEqual(Double(fps), 120, accuracy: 0.5, name)
            XCTAssertEqual(Int((dur * 120).rounded()), frames, name)
            let size = try await t.load(.naturalSize)
            XCTAssertEqual(Int(size.width), 64, name); XCTAssertEqual(Int(size.height), 64, name)
        }
    }

    func testNo120BlockMeansNo120Pack() throws {
        var o = try JSONSerialization.jsonObject(with: manifest) as! [String: Any]
        o.removeValue(forKey: "fps120")
        let v1 = try JSONSerialization.data(withJSONObject: o)
        XCTAssertNil(ThreePOPack.load(manifest: v1, root: threePODir, rate: .fps120))
        XCTAssertNotNil(ThreePOPack.load(manifest: v1, root: threePODir))               // 60 still loads
        // A 120 block whose files are not on disk: no sizes, so the app's pack120 is nil and 60 plays.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("threepo-empty-\(UUID().uuidString)")
        XCTAssertEqual(ThreePOPack.load(manifest: manifest, root: empty, rate: .fps120)!.sizes, [])
    }

    func testSixtyPackIsUnchangedByTheAddOn() {
        let p = ThreePOPack.load(manifest: manifest, root: threePODir)!
        XCTAssertEqual(p.rate, .fps60)
        XCTAssertEqual(p.fps, 60)
        XCTAssertEqual(p.path(.loop(.idle), px: 64), "hevc_alpha/64/3po_idle_64_hevc_alpha.mov")
        XCTAssertEqual(p.sizes, [64])
    }
}

/// The rig's parked idle at each rate: 20 fps × 2.5 s on 60 Hz screens, 120 fps × 2.5 s on ProMotion; same 0.5 s park.
final class ThreePORigPark120Tests: XCTestCase {
    func testBinsPerRate() {
        XCTAssertEqual(AvatarIdleCache.bins(.fps60), AvatarIdleCache.bins)
        XCTAssertEqual(AvatarIdleCache.bins(.fps60), 50)
        XCTAssertEqual(AvatarIdleCache.bins(.fps120), 300)
        XCTAssertEqual(AvatarIdleCache.hz(.fps60), 20)
        XCTAssertEqual(AvatarIdleCache.hz(.fps120), 120)
        XCTAssertEqual(AvatarIdleCache.maxPasses(.fps60), AvatarIdleCache.maxPasses)
        XCTAssertGreaterThan(AvatarIdleCache.maxPasses(.fps120), AvatarIdleCache.maxPasses)
    }

    func testBinsFollowTheRigClockAt120() {
        XCTAssertEqual(AvatarIdleCache.bin(local: 0, rate: .fps120), 0)
        XCTAssertEqual(AvatarIdleCache.bin(local: 0.008, rate: .fps120), 0)
        XCTAssertEqual(AvatarIdleCache.bin(local: 1.0 / 120 + 1e-6, rate: .fps120), 1)
        XCTAssertEqual(AvatarIdleCache.bin(local: 2.499, rate: .fps120), 299)
        XCTAssertEqual(AvatarIdleCache.bin(local: 2.5 + 0.01, rate: .fps120), 1)
        XCTAssertEqual(AvatarIdleCache.bin(local: 250.0 + 1.23, rate: .fps120), AvatarIdleCache.bin(local: 1.23, rate: .fps120))
        // Even 120 fps bins land where the 60 Hz path's 20 fps bins do (same clock, finer steps).
        for k in 0..<50 { XCTAssertEqual(AvatarIdleCache.bin(local: Double(k) / 20 + 1e-6, rate: .fps120), 6 * k) }
        for t in stride(from: 0.0, to: 2.5, by: 0.037) { XCTAssertEqual(AvatarIdleCache.bin(local: t, rate: .fps60), AvatarIdleCache.bin(local: t)) }
    }

    func testParkRuleIsTheSameAtBothRates() {
        XCTAssertEqual(AvatarIdleCache.settle, 0.5)
        XCTAssertTrue(AvatarIdleCache.shouldPark(steadyIdle: true, complete: true, settledFor: 0.5))
        XCTAssertFalse(AvatarIdleCache.shouldPark(steadyIdle: true, complete: true, settledFor: 0.49))
    }
}

private extension ThreePOPack {
    func path(clip: String) -> String { Self.path(clip: clip, px: 64, format: format, rate: rate) }
}

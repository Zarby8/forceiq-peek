import Foundation
import XCTest
@testable import PeakCore

// Idle CPU guard. Peek is "beautiful with motion", but ambient motion must never re-render SwiftUI at display refresh
// while the panel sits idle (the native glow's TimelineView(.animation) did: ~8-13 % CPU with the chat open, idle).
// These scan the app's sources for every way to run a forever animation and pin each to an allowed, bounded form.
// The runtime check is peak/scripts/cpu_idle_check.sh (expanded idle ≤ 2 %, exits 1 above).
let appSources = peakDir.appendingPathComponent("Sources/ForceIQPeak")

func appSourceFiles() -> [(name: String, text: String)] {
    let fm = FileManager.default
    let names = (try? fm.contentsOfDirectory(atPath: appSources.path)) ?? []
    return names.filter { $0.hasSuffix(".swift") }.sorted().compactMap { n in
        (try? String(contentsOf: appSources.appendingPathComponent(n), encoding: .utf8)).map { (n, $0) }
    }
}

/// Code only (line comments dropped), so docs can name the old pattern.
func codeLines(_ text: String) -> [String] {
    text.components(separatedBy: "\n").map { l in
        guard let r = l.range(of: "//") else { return l }
        return String(l[..<r.lowerBound])
    }
}

final class AmbientMotionGuardTests: XCTestCase {
    func testSourcesFound() {
        let files = appSourceFiles()
        XCTAssertTrue(files.contains { $0.name == "GhostMark.swift" } && files.count > 5, "app sources not found at \(appSources.path)")
    }

    func testNoRepeatForever() {
        for f in appSourceFiles() {
            for (i, l) in codeLines(f.text).enumerated() where l.contains("repeatForever") {
                XCTFail("\(f.name):\(i + 1): .repeatForever re-renders SwiftUI forever; use a CA layer animation (see CAGlowView)")
            }
        }
    }

    /// TimelineView(.animation) ticks at display refresh (60-120 Hz) and re-renders its window: only with a frame-rate
    /// cap (minimumInterval) and a pause, and never for the Ghost glow (that is CAGlowView, render-server driven).
    func testAnimationTimelinesAreCappedAndPausable() {
        for f in appSourceFiles() {
            for (i, l) in codeLines(f.text).enumerated() where l.contains("TimelineView(.animation") {
                XCTAssertTrue(l.contains("minimumInterval:"), "\(f.name):\(i + 1): TimelineView(.animation) without minimumInterval")
                XCTAssertTrue(l.contains("paused:"), "\(f.name):\(i + 1): TimelineView(.animation) without paused:")
            }
        }
    }

    func testNativeGlowIsCoreAnimation() throws {
        let g = try XCTUnwrap(appSourceFiles().first { $0.name == "GhostMark.swift" }).text
        let start = try XCTUnwrap(g.range(of: "struct NativeGlowRenderer"))
        let end = try XCTUnwrap(g.range(of: "struct CAGlowView", range: start.upperBound..<g.endIndex))
        let body = codeLines(String(g[start.lowerBound..<end.lowerBound])).joined(separator: "\n")
        XCTAssertFalse(body.contains("TimelineView"), "the native glow must not use a SwiftUI timeline")
        XCTAssertTrue(body.contains("CAGlowView("))
        XCTAssertTrue(g.contains("repeatCount = .infinity"), "the breath runs as a CA animation")
    }

    func testPeriodicTimelinesAreAtMostOncePerSecond() {
        let rx = try! NSRegularExpression(pattern: #"TimelineView\(\.periodic\([^)]*by:\s*([0-9.]+)"#)
        for f in appSourceFiles() {
            for (i, l) in codeLines(f.text).enumerated() where l.contains("TimelineView(.periodic") {
                let ns = l as NSString
                guard let m = rx.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)),
                      let by = Double(ns.substring(with: m.range(at: 1))) else { XCTFail("\(f.name):\(i + 1): unreadable periodic timeline"); continue }
                XCTAssertGreaterThanOrEqual(by, 1, "\(f.name):\(i + 1): periodic timeline faster than 1 Hz")
            }
        }
    }

    /// Display links: only the tour's hitch monitor and the 3PO crossfade clock, each invalidated by its owner.
    func testDisplayLinksAreAllowlistedAndStopped() {
        let allowed: Set<String> = ["HitchMonitor.swift", "ThreePOAvatar.swift"]
        for f in appSourceFiles() {
            let code = codeLines(f.text).joined(separator: "\n")
            guard code.contains("displayLink(target:") else { continue }
            XCTAssertTrue(allowed.contains(f.name), "\(f.name): new display link; ambient motion belongs in a CA animation")
            XCTAssertTrue(code.contains(".invalidate()"), "\(f.name): display link that is never invalidated")
        }
    }

    /// Repeating keyframe animators run forever while mounted: only ThinkingDots, and only mounted while busy.
    func testRepeatingKeyframesOnlyInThinkingDots() throws {
        for f in appSourceFiles() {
            let lines = codeLines(f.text)
            for (i, l) in lines.enumerated() where l.contains("repeating: true") {
                XCTAssertEqual(f.name, "ThreePOViews.swift", "\(f.name):\(i + 1): repeating keyframes outside ThinkingDots")
                let before = lines[..<i].joined(separator: "\n")
                let owner = before.range(of: "struct ", options: .backwards).map { String(before[$0.upperBound...].prefix(12)) } ?? ""
                XCTAssertTrue(owner.hasPrefix("ThinkingDots"), "\(f.name):\(i + 1): repeating keyframes in \(owner)")
            }
            for (i, l) in lines.enumerated() where l.contains("ThinkingDots()") && !l.contains("struct ") {
                let ctx = lines[max(0, i - 2)...i].joined(separator: " ")
                // an `if busy` or a busy `case .loading/.previewing…` of a switch
                XCTAssertTrue(ctx.contains("if ") || ctx.range(of: #"case \.(loading|previewing|confirming|thinking|running)"#, options: .regularExpression) != nil,
                              "\(f.name):\(i + 1): ThinkingDots mounted without a busy condition")
            }
        }
    }
}

final class GlowBreathTests: XCTestCase {
    func testMatchesTheApprovedSwiftUIFormula() {
        let b = GlowBreath(strength: 0.45)
        for t in stride(from: 0.0, to: 8.0, by: 0.37) {
            let p = (sin(t * 1.6) + 1) / 2
            let v = b.at(phase: GlowBreath.phase(at: t))
            XCTAssertEqual(v.inner, 0.55 + 0.45 * p, accuracy: 1e-9)
            XCTAssertEqual(v.outer, 0.45 * (0.35 + 0.4 * p), accuracy: 1e-9)
            XCTAssertEqual(v.blur, 4 + 3 * p, accuracy: 1e-9)
        }
        XCTAssertEqual(GlowBreath.halfPeriod, Double.pi / 1.6, accuracy: 1e-12)
        XCTAssertEqual(b.innerWidth, 1.5); XCTAssertEqual(b.outerWidth, 4)
    }

    func testStrengthByState() {
        XCTAssertEqual(GlowBreath.strength(.working), 0.7)
        XCTAssertEqual(GlowBreath.strength(.idle), 0.45)
        XCTAssertEqual(GlowBreath(strength: 0.7).outerOpacity, (0.7 * 0.35)...(0.7 * 0.75))
    }

    func testShaderGlowTickIsCapped() { XCTAssertLessThanOrEqual(PeakTokens.ambientShaderFPS, 20) }
}

final class PeakRootOverrideTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/coach")
    func testUnsetOrEmptyMeansNoOverride() {
        XCTAssertNil(PeakRoot.override(env: [:], home: home))
        XCTAssertNil(PeakRoot.override(env: ["GOAT_PEAK_ROOT": "  "], home: home))
    }
    func testOverrideWinsOverTheProfileRoot() {
        var p = CoachProfile.none; p.stateRoot = "~/ForceIQ/peak"
        XCTAssertEqual(p.stateRootURL(home: home, env: ["GOAT_PEAK_ROOT": "~/ForceIQ/peak-tmp/x"]).path, "/Users/coach/ForceIQ/peak-tmp/x")
        XCTAssertEqual(p.stateRootURL(home: home, env: ["GOAT_PEAK_ROOT": "/Volumes/s/root"]).path, "/Volumes/s/root")
        XCTAssertEqual(p.stateRootURL(home: home, env: [:]).path, "/Users/coach/ForceIQ/peak")
    }
    func testQuietDemoFeedIsIdle() {
        XCTAssertEqual(GhostState.from(DemoData.snapshot(quiet: true)), .idle)
        XCTAssertEqual(GhostState.from(DemoData.snapshot()), .attention)     // why #17's demo run never ran the glow
    }
}

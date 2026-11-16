import Foundation
import XCTest
@testable import PeakCore

/// Peek's eyes mark: the pose per state (pure), brand colors only, gold pupils only when something needs the coach, and the
/// receipt one-shot (fires after its duration even when the mark is asleep, never after a newer state).
@MainActor final class EyesPoseTests: XCTestCase {
    func samples(_ s: GhostState, to end: Double = 12) -> [EyesPose] { stride(from: 0.0, through: end, by: 0.05).map { EyesPose.at(s, t: $0) } }

    func testEveryPoseStaysInRangeInEveryState() {
        for s in GhostState.allCases {
            for p in samples(s) + [EyesPose.rest(s)] {
                XCTAssertTrue((-1.0...1.0).contains(p.lookX) && (-1.0...1.0).contains(p.lookY), "\(s) looks off the eye")
                XCTAssertTrue(p.open >= 0.09 && p.open <= 1.0, "\(s) lid \(p.open)")
                XCTAssertTrue(p.scale >= 1.0 && p.scale <= 1.2, "\(s) scale \(p.scale)")
                XCTAssertTrue(p.pupil > 0.4 && p.pupil <= 1.0, "\(s) pupil \(p.pupil)")
            }
        }
    }

    func testPupilsAreOnlyEverBrandGreenOrGold() {
        for s in GhostState.allCases { for p in samples(s) + [EyesPose.rest(s)] { XCTAssertTrue([Brand.greenHex, Brand.goldHex].contains(p.pupilHex)) } }
    }

    func testPupilsAreGoldExactlyWhenSomethingNeedsYou() {
        for s in GhostState.allCases {
            let gold = s == .attention || s == .error
            for p in samples(s) + [EyesPose.rest(s)] { XCTAssertEqual(p.pupilHex, gold ? Brand.goldHex : Brand.greenHex, "\(s)") }
        }
    }

    func testIdleGlancesBothWaysAndBlinksOncePerLoop() {
        let xs = samples(.idle).map(\.lookX)
        XCTAssertGreaterThan(xs.max() ?? 0, 0.5); XCTAssertLessThan(xs.min() ?? 0, -0.5)
        var blinks = 0, wasOpen = true
        for p in samples(.idle) { let isOpen = p.open >= 0.5; if wasOpen && !isOpen { blinks += 1 }; wasOpen = isOpen }
        XCTAssertEqual(blinks, 2, "a 6 s loop, sampled over 12 s")
        XCTAssertEqual(EyesPose.at(.idle, t: 0.3).lookX, EyesPose.at(.idle, t: 6.3).lookX, accuracy: 1e-9, "the loop repeats")
    }

    func testWorkingScansAndTypingReadsDown() {
        let w = samples(.working, to: 4).map(\.lookX)
        XCTAssertGreaterThan(w.max() ?? 0, 0.8); XCTAssertLessThan(w.min() ?? 0, -0.8)
        XCTAssertTrue(samples(.typing).allSatisfy { $0.lookY > 0.5 })
    }

    func testAttentionIsWideAndGoldAndErrorShakesThenHolds() {
        XCTAssertTrue(samples(.attention).allSatisfy { $0.scale >= 1.05 })
        let shake = samples(.error, to: 0.75).map { abs($0.lookX) }
        XCTAssertGreaterThan(shake.max() ?? 0, 0.2)
        XCTAssertTrue(samples(.error, to: 12).suffix(100).allSatisfy { $0.lookX == 0 }, "settles after the shake")
        XCTAssertTrue(samples(.error).allSatisfy { $0.ring && $0.pupil < 0.6 }, "startled pupils with a gold ring")
    }

    func testReceiptBlinksThenShowsAGreenRing() {
        XCTAssertLessThan(EyesPose.at(.receipt, t: 0.12).open, 0.3)
        XCTAssertFalse(EyesPose.at(.receipt, t: 0.1).ring)
        XCTAssertTrue(EyesPose.at(.receipt, t: 0.6).ring)
        XCTAssertEqual(EyesPose.at(.receipt, t: 0.6).pupilHex, Brand.greenHex)
        XCTAssertEqual(EyesPose.at(.receipt, t: EyesPose.receiptSeconds).scale, 1.0, accuracy: 0.001, "it settles back")
    }

    func testSleepingIsLidsShutWithASlowBreath() {
        XCTAssertEqual(EyesPose.rest(.sleeping).open, 0.1, accuracy: 1e-9, "the still frame is asleep")
        XCTAssertTrue(samples(.sleeping).allSatisfy { $0.open == 0.1 && !$0.ring && !$0.halo }, "shut for the whole loop")
        let scales = samples(.sleeping, to: 8).map(\.scale)
        XCTAssertGreaterThan(scales.max() ?? 0, 1.025); XCTAssertLessThan(scales.min() ?? 1, 1.015, "one slow breath, in range")
    }

    func testOnlyAttentionWearsTheGoldRing() {
        for s in GhostState.allCases { for p in samples(s) + [EyesPose.rest(s)] { XCTAssertEqual(p.halo, s == .attention, "\(s)") } }
    }

    func testTheStillFrameIsFixedPerState() {
        for s in GhostState.allCases { XCTAssertEqual(EyesPose.rest(s), EyesPose.rest(s)) }
        XCTAssertEqual(EyesPose.rest(.idle).open, 1.0)
        XCTAssertNotEqual(EyesPose.rest(.idle), EyesPose.rest(.attention))
    }

    // ── the one-shot ──
    func testTheReceiptOneShotFiresOnceAfterItsDuration() async {
        let shot = EyesOneShot(); var fired = 0
        shot.schedule(for: .receipt, seconds: 0.05) { fired += 1 }
        XCTAssertEqual(fired, 0, "not before its time")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fired, 1)
    }

    func testANewStateCancelsThePendingOneShot() async {
        let shot = EyesOneShot(); var fired = 0
        shot.schedule(for: .receipt, seconds: 0.15) { fired += 1 }
        shot.schedule(for: .idle) { fired += 100 }
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(fired, 0, "the receipt was replaced before it finished; idle never schedules")
    }

    func testOnlyTheReceiptSchedulesAOneShotAndRescheduleFiresOnce() async {
        let shot = EyesOneShot(); var fired = 0
        for s in GhostState.allCases where s != .receipt { shot.schedule(for: s, seconds: 0.01) { fired += 1 } }
        shot.schedule(for: .receipt, seconds: 0.05) { fired += 1 }
        shot.schedule(for: .receipt, seconds: 0.05) { fired += 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fired, 1)
    }

    func testCancelStopsTheOneShot() async {
        let shot = EyesOneShot(); var fired = 0
        shot.schedule(for: .receipt, seconds: 0.05) { fired += 1 }
        shot.cancel()
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(fired, 0)
    }
}

import Foundation

// Peek's mark: a pair of eyes (👀), drawn as vectors. The pupils carry the state: green = all is well, gold = something needs
// you. Pure: the pose of the eyes for a state at a time, so it is tested without a screen. Brand colors only (green, gold; the
// whites are pure white on black).

public struct EyesPose: Equatable, Sendable {
    /// Where the pupils look: -1 (left / up) ... 1 (right / down).
    public var lookX: Double
    public var lookY: Double
    /// 1 = open, ~0.1 = mid-blink.
    public var open: Double
    /// Eye size and pupil size multipliers.
    public var scale: Double
    public var pupil: Double
    public var pupilHex: UInt32
    /// An outline in the pupil color around each eye (receipt, error).
    public var ring: Bool
    /// A gold ring around the whole mark (attention only: the glow ring is green and skips that state).
    public var halo: Bool

    public static let receiptSeconds: Double = 1.2

    init(lookX: Double = 0, lookY: Double = 0, open: Double = 1, scale: Double = 1, pupil: Double = 1,
         pupilHex: UInt32 = Brand.greenHex, ring: Bool = false, halo: Bool = false) {
        self.lookX = lookX; self.lookY = lookY; self.open = open; self.scale = scale; self.pupil = pupil
        self.pupilHex = pupilHex; self.ring = ring; self.halo = halo
    }

    /// The still frame held while the mark sleeps (a collapsed idle pill) or while Reduce Motion is on.
    public static func rest(_ s: GhostState) -> EyesPose {
        switch s {
        case .idle: return EyesPose(lookX: 0.6)                                          // glancing off to the side
        case .working: return EyesPose()
        case .typing: return EyesPose(lookX: 0.3, lookY: 0.8)
        case .attention: return EyesPose(scale: 1.08, pupilHex: Brand.goldHex, halo: true)
        case .receipt: return EyesPose(scale: 1.08, ring: true)
        case .error: return EyesPose(scale: 1.1, pupil: 0.55, pupilHex: Brand.goldHex, ring: true)
        case .sleeping: return EyesPose(open: 0.1)                                        // lids shut
        }
    }

    /// The moving pose, `t` seconds after the state began.
    public static func at(_ s: GhostState, t: Double) -> EyesPose {
        let t = max(0, t)
        switch s {
        case .idle:                                                                       // glance right, left, up, then blink
            let u = t.truncatingRemainder(dividingBy: 6)
            return EyesPose(lookX: smooth([(0, 0.6), (1.6, 0.6), (2.1, -0.6), (3.7, -0.6), (4.2, 0), (5.4, 0), (6, 0.6)], u),
                            lookY: smooth([(0, 0), (3.7, 0), (4.2, -0.25), (5.4, -0.25), (6, 0)], u),
                            open: blink(u, at: 5))
        case .working:                                                                    // scanning left and right
            return EyesPose(lookX: 0.9 * sin(2 * .pi * t / 1.0))
        case .typing:                                                                     // reading down a line
            return EyesPose(lookX: 0.7 * sin(2 * .pi * t / 1.8), lookY: 0.85)
        case .attention:                                                                  // wide, gold, looking at you
            let u = t.truncatingRemainder(dividingBy: 3.5)
            return EyesPose(lookY: -0.1, open: blink(u, at: 3.2), scale: 1.08 + 0.03 * sin(2 * .pi * t / 1.4), pupilHex: Brand.goldHex, halo: true)
        case .receipt:                                                                    // one blink and a green ring
            let p = min(t / receiptSeconds, 1)
            return EyesPose(open: blink(t, at: 0.12), scale: 1 + 0.12 * sin(.pi * p), ring: t >= 0.25)
        case .error:                                                                      // startled: shake, then hold wide
            return EyesPose(lookX: t < 0.8 ? 0.35 * sin(2 * .pi * t / 0.22) : 0, scale: 1.1, pupil: 0.55,
                            pupilHex: Brand.goldHex, ring: true)
        case .sleeping:                                                                   // asleep: lids shut, one slow breath
            return EyesPose(open: 0.1, scale: 1.02 + 0.01 * sin(2 * .pi * t / 4))
        }
    }

    /// A quick triangular blink centered on `c` seconds.
    static func blink(_ t: Double, at c: Double, width: Double = 0.2) -> Double {
        1 - 0.9 * max(0, 1 - abs(t - c) / (width / 2))
    }

    /// Smoothstep between (time, value) keyframes.
    static func smooth(_ keys: [(Double, Double)], _ t: Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if t <= first.0 { return first.1 }
        if t >= last.0 { return last.1 }
        for i in 1..<keys.count where t <= keys[i].0 {
            let (t0, v0) = keys[i - 1], (t1, v1) = keys[i]
            let x = (t - t0) / (t1 - t0), e = x * x * (3 - 2 * x)
            return v0 + (v1 - v0) * e
        }
        return last.1
    }
}

/// Tells the controller the receipt one-shot is over after its duration, whether or not the mark is animating (a sleeping
/// pill must not stay on `receipt`). A newer schedule, or a state that isn't the receipt, cancels the pending one.
@MainActor public final class EyesOneShot {
    private var task: Task<Void, Never>?
    public init() {}
    public func schedule(for state: GhostState, seconds: Double = EyesPose.receiptSeconds, done: @escaping @MainActor () -> Void) {
        task?.cancel(); task = nil
        guard state == .receipt else { return }
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { done() }
        }
    }
    public func cancel() { task?.cancel(); task = nil }
}

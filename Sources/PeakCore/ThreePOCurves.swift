import Foundation

// The pack's state curves (BOB Motion ForceIQ-Peak-3PO-v1 source/curves.py and rig/README.md, "exact maths used for
// the renders"), ported so the live rig moves like the rendered loops. Pure, unit-tested.

public struct ThreePOParams: Equatable, Sendable {
    public var headPitch = 0.0, headYaw = 0.0, headTilt = 0.0     // degrees (Blender X = pitch, Y = roll/tilt, Z = yaw)
    public var eyeGlow = 0.42, blink = 0.0
    public var scanAngle = 0.0, scanBoost = 0.15
    public var talkAmp = 0.0, goldFlash = 0.0, micLevel = 0.0
    public init() {}
}

public enum ThreePOCurves {
    public static let fps = 60.0
    public static let transitionFrames = 20
    public static let loopSeconds: [AvatarState: Double] = [.idle: 2.5, .listening: 2, .thinking: 2, .talking: 2, .alert: 2]

    public static func seconds(_ c: AvatarClip) -> Double {
        switch c {
        case .loop(let s), .once(let s): return loopSeconds[s] ?? 2
        case .transition: return Double(transitionFrames) / fps
        }
    }

    static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
    static func smoothstep(_ u: Double) -> Double { let x = clamp01(u); return x * x * (3 - 2 * x) }

    /// One state at `t` seconds into its loop. `talkDrive` (0…1, the stream rate) scales the simulated syllables
    /// while tokens arrive; nil = the rendered loop's own syllables.
    public static func state(_ s: AvatarState, _ t: Double, talkDrive: Double? = nil, mic: Double? = nil) -> ThreePOParams {
        var p = ThreePOParams(); let tau = 2 * Double.pi
        let ph = tau * t / (loopSeconds[s] ?? 2)
        switch s {
        case .idle:
            let x = (t - (1.70 - 0.09)) / 0.18
            p.headYaw = 4 * sin(ph); p.headTilt = 1.6 * cos(ph); p.headPitch = 1 * sin(2 * ph)
            p.blink = (0...1).contains(x) ? pow(sin(.pi * x), 2) : 0
        case .listening:
            let m = mic.map(clamp01) ?? clamp01(0.45 + 0.30 * sin(2 * ph) + 0.20 * sin(5 * ph + 1.3))
            p.micLevel = m; p.headPitch = 7 + 3 * m + 1.2 * sin(ph); p.headYaw = 3
            p.headTilt = -7 + 1.5 * sin(ph + 0.6); p.eyeGlow = 0.60 + 0.40 * m
        case .thinking:
            p.headPitch = -4 + 0.5 * sin(13 * ph + 0.4)
            p.headYaw = -3 + 0.7 * sin(11 * ph) + 0.4 * sin(17 * ph + 1.1)
            p.headTilt = 6 + 0.4 * sin(7 * ph + 2)
            p.eyeGlow = 0.22; p.scanBoost = 0.75; p.scanAngle = 28 * sin(2 * ph)
        case .talking:
            var a = clamp01(pow(0.5 - 0.5 * cos(6 * ph), 1.5) * (0.70 + 0.30 * sin(2 * ph + 0.7)))
            if let d = talkDrive { a *= 0.35 + 0.65 * clamp01(d) }
            p.talkAmp = a; p.eyeGlow = 0.50 + 0.35 * a
            p.headPitch = 1.5 * a + 0.8 * sin(ph); p.headYaw = 2.5 * sin(ph); p.headTilt = 1.0 * sin(ph + 1)
        case .alert:
            let w = t < 1.4 ? 1 : 1 - smoothstep((t - 1.4) / 0.5)
            let sp = exp(-t / 0.30) * sin(tau * t / 0.36) * w
            let e = (1 - exp(-t / 0.02)) * exp(-t / 0.40) * w
            p.headPitch = -14 * sp; p.headYaw = 5 * sp; p.headTilt = 3 * sp
            p.goldFlash = (1 - exp(-t / 0.02)) * exp(-t / 0.18) * w
            p.eyeGlow = 0.42 + 0.58 * e; p.scanBoost = 0.15 + 0.3 * e
        }
        return p
    }

    /// A→B over the pack's 20 frames: every parameter eases from A(0) to B(0), plus the eye/nod accent.
    public static func transition(_ a: AvatarState, _ b: AvatarState, u: Double) -> ThreePOParams {
        let pa = state(a, 0), pb = state(b, 0), k = smoothstep(u), acc = sin(.pi * clamp01(u))
        func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
        var p = ThreePOParams()
        p.headPitch = l(pa.headPitch, pb.headPitch) + 1.5 * acc; p.headYaw = l(pa.headYaw, pb.headYaw); p.headTilt = l(pa.headTilt, pb.headTilt)
        p.eyeGlow = clamp01(l(pa.eyeGlow, pb.eyeGlow) + 0.12 * acc); p.blink = l(pa.blink, pb.blink)
        p.scanAngle = l(pa.scanAngle, pb.scanAngle); p.scanBoost = l(pa.scanBoost, pb.scanBoost)
        p.talkAmp = l(pa.talkAmp, pb.talkAmp); p.goldFlash = l(pa.goldFlash, pb.goldFlash); p.micLevel = l(pa.micLevel, pb.micLevel)
        return p
    }

    public static func params(_ c: AvatarClip, _ t: Double, talkDrive: Double? = nil) -> ThreePOParams {
        switch c {
        case .loop(let s), .once(let s): return state(s, t, talkDrive: s == .talking ? talkDrive : nil)
        case .transition(let a, let b): return transition(a, b, u: t / seconds(c))
        }
    }

    /// Rig material strengths (README "SceneKit/RealityKit intensity = 1 is full colour").
    public static func eyeIntensity(_ p: ThreePOParams) -> Double { clamp01(p.eyeGlow * (1 - 0.85 * p.blink)) }
    public static func scanIntensity(_ p: ThreePOParams) -> Double { 1.8 * clamp01(eyeIntensity(p) + p.scanBoost * (1 - 0.85 * p.blink)) }
    public static func lid(_ p: ThreePOParams) -> Double { 1 - 0.8 * p.blink }
}

/// The same queue the video player keeps, in the time domain (for the live rig): the clip on screen always finishes;
/// then the planned transitions play, then the settled state loops.
public struct AvatarTimeline: Equatable, Sendable {
    public private(set) var current: AvatarClip = .loop(.idle)
    public private(set) var start: Double
    public private(set) var queue: [AvatarClip] = []
    public private(set) var settle: AvatarState = .idle
    public init(now: Double) { start = now }

    public mutating func apply(_ p: AvatarPlan) { queue = p.clips; settle = p.loop }

    /// Moves to `now`. Returns the clips that started on the way (oldest first).
    @discardableResult public mutating func advance(to now: Double) -> [AvatarClip] {
        if now - start > 30 { start = now - fmod(now - start, ThreePOCurves.seconds(current)) }   // woke from a long pause
        var started: [AvatarClip] = []
        while now - start >= ThreePOCurves.seconds(current) {
            start += ThreePOCurves.seconds(current)
            let next: AvatarClip = queue.isEmpty ? .loop(settle) : queue.removeFirst()
            if next != current { started.append(next) }
            current = next
        }
        return started
    }
    public func local(_ now: Double) -> Double { max(0, now - start) }
}

/// Stream rate → 0…1 talk drive (README: one-pole, ~30 ms attack, ~120 ms release). ~40 chars/s reads as full.
public struct TalkMeter: Equatable, Sendable {
    public private(set) var level = 0.0
    var target = 0.0
    var lastChars = 0
    var lastDelta: Double?
    var lastTick: Double?
    public static let fullCharsPerSecond = 40.0
    public init() {}

    public mutating func observe(chars: Int, now: Double) {
        defer { lastChars = chars }
        guard chars > lastChars else { if chars < lastChars { target = 0; lastDelta = nil }; return }
        let dt = max(1.0 / 60, now - (lastDelta ?? (now - 0.1)))
        target = min(1, Double(chars - lastChars) / dt / Self.fullCharsPerSecond)
        lastDelta = now
    }

    public mutating func tick(now: Double) -> Double {
        if let d = lastDelta, now - d > 0.25 { target = 0 }               // the stream paused
        let dt = max(0, now - (lastTick ?? now)); lastTick = now
        let tau = target > level ? 0.03 : 0.12
        level += (target - level) * (1 - exp(-dt / tau))
        return level
    }
}

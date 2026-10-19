import Foundation

// ForceIQ Peak 3PO avatar: BOB Motion's ForceIQ-Peak-3PO-v1 pack (Resources/threepo). Pure logic, unit-tested: which
// state the chat is in (from the transcript Peak already keeps), how the player gets there (the pack's 20-frame
// transitions, non-idle to non-idle through idle), when a change starts (at once, crossfading from the frame on
// screen: AvatarSwitch / AvatarCrossfade), and which files the pack carries.

/// The pack's five states (MANIFEST.json `states`).
public enum AvatarState: String, Sendable, CaseIterable {
    case idle, listening, thinking, talking, alert
}

/// What Peak already knows about the chat, reduced to what the avatar needs.
public struct AvatarSignals: Equatable, Sendable {
    public var streaming = false          // a turn is open (send → done / error / end of stream)
    public var thinking = false           // waiting for the first token, a tool or the advisor
    public var consultingOpus = false     // the gold 'consulting Opus' moment (Auto: from send; else the advisor event)
    public var replyHasText = false       // the live reply already has streamed text
    public var cards = 0                  // approval + refusal cards on the transcript (each new one flashes alert)
    public var voiceEnabled = false       // the voice module (profile flag, off by default)
    public var micOn = false              // the mic is open (only counts with voice enabled)
    public var replyChars = 0             // streamed characters so far (the rig's talk light follows the stream rate)
    public init(streaming: Bool = false, thinking: Bool = false, consultingOpus: Bool = false, replyHasText: Bool = false,
                cards: Int = 0, voiceEnabled: Bool = false, micOn: Bool = false) {
        self.streaming = streaming; self.thinking = thinking; self.consultingOpus = consultingOpus
        self.replyHasText = replyHasText; self.cards = cards; self.voiceEnabled = voiceEnabled; self.micOn = micOn
    }

    /// From the transcript reducer (ThreePOTranscript), the same state the chat view draws from.
    public static func from(_ t: ThreePOTranscript, voiceEnabled: Bool = false, micOn: Bool = false) -> AvatarSignals {
        let reply = t.messages.last(where: { $0.role == .threePO })
        return AvatarSignals(streaming: t.streaming, thinking: t.thinking, consultingOpus: t.consultingOpus,
                             replyHasText: !(reply?.text.isEmpty ?? true),
                             cards: t.messages.reduce(0) { $0 + $1.proposals.count },
                             voiceEnabled: voiceEnabled, micOn: micOn)
            .with(replyChars: reply?.text.count ?? 0)
    }
    func with(replyChars n: Int) -> AvatarSignals { var c = self; c.replyChars = n; return c }
}

public enum AvatarStateMap {
    /// The steady state for these signals (alert is a one-pass flash the director adds on a new card).
    /// listening (mic open, voice on) > thinking (send → first token, tools, the advisor / 'consulting Opus') >
    /// talking (tokens streaming) > idle (waiting).
    public static func target(_ s: AvatarSignals) -> AvatarState {
        if s.voiceEnabled && s.micOn { return .listening }
        if s.streaming && (s.thinking || s.consultingOpus || !s.replyHasText) { return .thinking }
        if s.streaming { return .talking }
        return .idle
    }
}

/// One clip in the player queue.
public enum AvatarClip: Hashable, Sendable {
    case loop(AvatarState)                         // the state's seamless loop, pass after pass
    case once(AvatarState)                         // one pass of a loop (alert: one gold flash, never a repeating one)
    case transition(AvatarState, AvatarState)      // the pack's 20-frame X_to_Y clip

    /// The pose this clip ends on (where the next clip starts).
    public var endState: AvatarState {
        switch self { case .loop(let s), .once(let s): return s; case .transition(_, let b): return b }
    }
    /// The pack's clip name (`idle`, `idle_to_talking`, …).
    public var name: String {
        switch self {
        case .loop(let s), .once(let s): return s.rawValue
        case .transition(let a, let b): return "\(a.rawValue)_to_\(b.rawValue)"
        }
    }
}

/// What to queue after the clip that's playing now: transition/one-pass clips in order, then the loop to settle in.
public struct AvatarPlan: Equatable, Sendable {
    public var clips: [AvatarClip]
    public var loop: AvatarState
    public init(clips: [AvatarClip], loop: AvatarState) { self.clips = clips; self.loop = loop }
}

public enum AvatarPlanner {
    /// Pack rule: transitions only exist to and from idle, so non-idle → non-idle goes through idle.
    public static func route(_ a: AvatarState, _ b: AvatarState) -> [AvatarClip] {
        if a == b { return [] }
        if a == .idle { return [.transition(.idle, b)] }
        if b == .idle { return [.transition(a, .idle)] }
        return [.transition(a, .idle), .transition(.idle, b)]
    }

    /// The queue after `current` finishes (the player switches only at the end of a loop pass or a transition).
    /// alert = idle_to_alert, one alert pass, alert_to_idle, then on to `then`.
    public static func plan(after current: AvatarClip, to target: AvatarState, then: AvatarState = .idle) -> AvatarPlan {
        var clips: [AvatarClip] = []
        var at = current.endState
        if case .transition(_, .alert) = current { clips.append(.once(.alert)) }   // mid idle_to_alert: keep the flash
        if target == .alert {
            if at != .alert { clips += route(at, .idle); clips += [.transition(.idle, .alert), .once(.alert)] }
            at = .alert
            let settle = then == .alert ? .idle : then
            clips += route(at, settle)
            return AvatarPlan(clips: clips, loop: settle)
        }
        clips += route(at, target)
        return AvatarPlan(clips: clips, loop: target)
    }
}

/// Decides when the queue changes. Feed it the chat's signals whenever they change and the clip the player is on
/// whenever that changes; it hands back a plan only when the queue must change (a new steady state, or a new
/// approval/refusal card to flash for). A pending flash survives replans until its alert pass is on screen.
public struct ThreePOAvatarDirector: Equatable, Sendable {
    public private(set) var settled: AvatarState = .idle      // the loop the queued plan ends in
    public private(set) var seenCards = 0
    public private(set) var flashPending = false
    public init() {}

    public mutating func update(_ s: AvatarSignals, current: AvatarClip) -> AvatarPlan? {
        if case .once(.alert) = current { flashPending = false }      // the flash is playing
        let newCard = s.cards > seenCards
        seenCards = s.cards                                         // a cleared transcript never flashes
        let steady = AvatarStateMap.target(s)
        if newCard && steady != .listening { flashPending = true }  // the mic open wins: no flash over listening
        if flashPending {
            guard newCard || steady != settled else { return nil }
            settled = steady
            return AvatarPlanner.plan(after: current, to: .alert, then: steady)
        }
        guard steady != settled else { return nil }
        settled = steady
        return AvatarPlanner.plan(after: current, to: steady)
    }
}

/// When a planned change starts. Every state change starts at once (well inside 100 ms): the clip on screen is cut
/// and the plan crossfades in from the frame on screen (the rig blends its parameters the same way). The one change
/// that waits for its clip to end is the alert flash settling back to idle, so a card's flash always plays whole; a
/// user-driven change (mic, send, first token) still cuts the flash.
public enum AvatarSwitchMode: String, Sendable { case cut, boundary }

public enum AvatarSwitch {
    /// Crossfade from the frame on screen into the plan (seconds; ease-out, so the first frame already moves).
    public static let fade = 0.13
    /// The no-hitch bar: a change must start on screen within this.
    public static let maxStart = 0.1
    public static func mode(current: AvatarClip, plan: AvatarPlan) -> AvatarSwitchMode {
        switch current {
        case .once(.alert), .transition(.idle, .alert): return plan.loop == .idle ? .boundary : .cut
        default: return .cut
        }
    }
}

/// The video tier's crossfade: on a cut the frame on screen is frozen into an overlay at full opacity, the player
/// switches under it, and once the new clip's first frame is up the overlay fades out (AvatarSwitch.fade, ease-out).
/// Latest wins, nothing stacks: a cut before the new frame is up keeps the frozen frame and just retargets the player;
/// a cut mid-fade freezes what is on screen (overlay at its opacity over the live frame) into one new overlay.
public struct AvatarCrossfade: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case none, armed(since: Double), fading(start: Double) }
    public enum Snapshot: Equatable, Sendable { case frame, keep, composite(alpha: Double) }
    public private(set) var phase: Phase = .none
    /// Never hold a frozen frame longer than this if the new clip is slow to show (logged; normal is a few ms).
    public static let readyDeadline = 0.25
    public init() {}

    public mutating func cut(now: Double) -> Snapshot {
        switch phase {
        case .armed: return .keep                                   // the frozen frame is still fully up
        case .fading:
            let a = opacity(now); phase = .armed(since: now)
            return a > 0.001 ? .composite(alpha: a) : .frame
        case .none: phase = .armed(since: now); return .frame
        }
    }
    /// The new clip's first frame is on screen: the overlay starts fading. Returns how long it waited, nil if not armed.
    @discardableResult public mutating func ready(now: Double) -> Double? {
        guard case .armed(let s) = phase else { return nil }
        phase = .fading(start: now)
        return now - s
    }
    /// Per display frame. Returns false once the overlay is gone (the display link can stop).
    public mutating func tick(now: Double) -> Bool {
        switch phase {
        case .none: return false
        case .armed(let s): if now - s >= Self.readyDeadline { phase = .fading(start: now) }; return true
        case .fading(let s): if now - s >= AvatarSwitch.fade { phase = .none; return false }; return true
        }
    }
    public func opacity(_ now: Double) -> Double {
        switch phase {
        case .none: return 0
        case .armed: return 1
        case .fading(let s): return 1 - ThreePOCurves.easeOut((now - s) / AvatarSwitch.fade)
        }
    }
}

/// The frame rate the 3PO avatar renders at on the screen Peak is on. 60 is the default and the fallback; 120 only
/// when that screen reports ≥ 120 Hz (NSScreen.maximumFramesPerSecond: a ProMotion built-in with the lid open) and the
/// bundle carries a complete 120 fps set (BOB Motion v1.1 add-on, fps120/). Re-chosen whenever Peak changes screens.
public enum AvatarFrameRate: Int, Sendable, CaseIterable {
    case fps60 = 60, fps120 = 120
    public var fps: Double { Double(rawValue) }
    /// `screenMaxFPS`: the screen's maximumFramesPerSecond (nil: no screen yet). `has120`: a complete 120 fps set loaded.
    /// `override`: FORCEIQ_PEAK_3PO_FPS; "60" pins 60 (a kill switch). Nothing ever picks 120 on a screen below 120 Hz.
    public static func choose(screenMaxFPS: Int?, has120: Bool, override: String? = nil) -> AvatarFrameRate {
        if override?.trimmingCharacters(in: .whitespaces) == "60" { return .fps60 }
        guard has120, let hz = screenMaxFPS, hz >= 120 else { return .fps60 }
        return .fps120
    }
}

/// The rig's parked idle: RealityKit draws every display frame while its view is in a window, so a steady idle
/// rig plays a captured pass of itself and leaves the window until something changes. 60 Hz screens: 20 fps (50 frames,
/// the slow sway reads the same at 32 pt); 120 Hz screens: the full 120 (300 frames, one per ProMotion refresh).
public enum AvatarIdleCache {
    public static let hz = 20.0
    public static var bins: Int { bins(.fps60) }
    /// Give up capturing after this many idle passes (the rig then simply stays live, throttled).
    public static let maxPasses = 3
    /// Idle this long with nothing changing before the rig parks.
    public static let settle = 0.5
    public static func hz(_ r: AvatarFrameRate) -> Double { r == .fps120 ? 120 : hz }
    public static func bins(_ r: AvatarFrameRate) -> Int { Int(((ThreePOCurves.loopSeconds[.idle] ?? 2.5) * hz(r)).rounded()) }
    /// A 120 Hz pass needs a snapshot on every refresh to fill in one go; give it as many seconds of tries as 60 Hz gets.
    public static func maxPasses(_ r: AvatarFrameRate) -> Int { r == .fps120 ? maxPasses * 4 : maxPasses }
    public static func bin(local t: Double) -> Int { bin(local: t, rate: .fps60) }
    public static func bin(local t: Double, rate r: AvatarFrameRate) -> Int {
        let T = ThreePOCurves.loopSeconds[.idle] ?? 2.5
        let u = t.truncatingRemainder(dividingBy: T)
        return min(bins(r) - 1, max(0, Int(((u < 0 ? u + T : u) * hz(r)).rounded(.down))))
    }
    public static func shouldPark(steadyIdle: Bool, complete: Bool, settledFor: Double) -> Bool {
        steadyIdle && complete && settledFor >= settle
    }
}

/// The loops tier's parked idle: an AVPlayer that keeps playing costs ~3.5 % CPU even for a 64 px clip (CoreMedia's
/// queue, the decoder round trips and the image queue run every frame), so a steady idle loop parks like the rig does:
/// the idle clip's own decoded frames (every frame, at the pack's fps) play as a Core Animation keyframe animation in
/// phase with the player, and the player pauses. Any change unparks at once (the parked frame is the cut's frozen frame).
public enum AvatarLoopPark {
    /// Park only on the idle loop, settling into idle, with no crossfade up, while live, once every frame is decoded
    /// and nothing has changed for AvatarIdleCache.settle (0.5 s, the rig's rule).
    public static func shouldPark(current: AvatarClip, loopState: AvatarState, overlayUp: Bool, live: Bool,
                                  framesReady: Bool, settledFor: Double) -> Bool {
        current == .loop(.idle) && loopState == .idle && !overlayUp && live && framesReady && settledFor >= AvatarIdleCache.settle
    }
    /// The parked frame for `t` seconds into the idle loop (wraps; what the player would show at that time).
    public static func frame(local t: Double, frames n: Int, fps: Double) -> Int {
        guard n > 0, fps > 0 else { return 0 }
        let T = Double(n) / fps
        var u = t.truncatingRemainder(dividingBy: T); if u < 0 { u += T }
        return min(n - 1, max(0, Int((u * fps + 1e-6).rounded(.down))))
    }
    /// A full decode: exactly the manifest's frame count, else no park (the player keeps playing).
    public static func complete(decoded: Int, manifest: Int?) -> Bool { manifest.map { $0 > 0 && decoded == $0 } ?? false }
}

/// Which droid the 3PO slot shows: the live rig (rig/3po.usdz, RealityKit) when it loaded, else the pack's rendered
/// loops when every clip is there, else the static droid mark. Reduce Motion: a still (the pack's neutral frame, or the mark).
public enum AvatarTier: String, Sendable { case rig, loops, still, mark

    /// `rig`: nil = not tried yet / loading, true = loaded with every node the drive needs, false = missing or failed.
    public static func choose(rig: Bool?, rigEnabled: Bool, loops: Bool, stillAvailable: Bool, reduceMotion: Bool, live: Bool) -> AvatarTier {
        if reduceMotion || !live { return stillAvailable ? .still : .mark }
        if rigEnabled && rig == true { return .rig }
        if loops { return .loops }
        return .mark
    }
}

/// When the avatar plays. It lives in the expanded chat only (unmounted when Peak collapses, so a collapsed, idle Peak
/// decodes nothing), pauses while the panel is hidden, and holds one still frame under Reduce Motion.
public enum AvatarPolicy {
    public static func live(visible: Bool, globallyVisible: Bool, expanded: Bool, reduceMotion: Bool) -> Bool {
        visible && globallyVisible && expanded && !reduceMotion
    }
}

public enum AvatarFormat: String, Sendable { case hevcAlpha = "hevc_alpha", h264Black = "h264_black" }

/// BOB Motion's ForceIQ-Peak-3PO MANIFEST.json (v1.1, as shipped): frames/fps per clip and the MD5 of every file.
/// rate .fps60 reads the v1 pack (top-level states/transitions); .fps120 reads the v1.1 add-on (the "fps120" block:
/// same clips and durations, frame counts doubled, files under fps120/). A manifest without that block: no 120 pack.
public struct ThreePOPack: Sendable {
    public let name: String
    public let version: String
    public let fps: Double
    public let frames: [String: Int]                 // clip name → frames (5 loops + 8 transitions)
    public let loops: Set<String>
    public let md5: [String: String]                 // relative path → md5
    /// Sizes whose files for `format` are all present under `root` (what this bundle actually carries).
    public let sizes: [Int]
    public let format: AvatarFormat
    public let rate: AvatarFrameRate

    public static func load(manifest data: Data, root: URL?, format: AvatarFormat = .hevcAlpha, rate: AvatarFrameRate = .fps60) -> ThreePOPack? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let o: [String: Any]
        if rate == .fps120 { guard let b = top["fps120"] as? [String: Any] else { return nil }; o = b } else { o = top }
        guard let states = o["states"] as? [String: [String: Any]], let trans = o["transitions"] as? [String: [String: Any]],
              let topStates = top["states"] as? [String: [String: Any]] else { return nil }
        let fps = (o["fps"] as? Double) ?? Double((o["fps"] as? Int) ?? 0)
        guard fps == rate.fps else { return nil }
        var frames: [String: Int] = [:], loops: Set<String> = []
        for (k, v) in states {
            guard let f = v["frames"] as? Int else { continue }
            frames[k] = f
            if (topStates[k]?["loop"] as? Bool) == true { loops.insert(k) }        // the add-on keeps v1's loop flags
        }
        for (k, v) in trans { if let f = v["frames"] as? Int { frames[k] = f } }
        var md5: [String: String] = [:], px: Set<Int> = []
        for f in (top["files"] as? [[String: Any]]) ?? [] {
            guard let p = f["path"] as? String, let m = f["md5"] as? String else { continue }
            md5[p] = m
            if (f["kind"] as? String) == format.rawValue, p.hasPrefix(prefix(rate)), let x = f["px"] as? Int { px.insert(x) }
        }
        let names = Array(frames.keys)
        var sizes = px.sorted()
        if let root {
            sizes = sizes.filter { x in names.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent(path(clip: $0, px: x, format: format, rate: rate)).path) } }
        }
        return ThreePOPack(name: (top["name"] as? String) ?? "", version: (top["version"] as? String) ?? "", fps: fps, frames: frames,
                           loops: loops, md5: md5, sizes: sizes, format: format, rate: rate)
    }

    private static func prefix(_ r: AvatarFrameRate) -> String { r == .fps120 ? "fps120/" : "" }
    public static func path(clip: String, px: Int, format: AvatarFormat, rate: AvatarFrameRate = .fps60) -> String {
        prefix(rate) + (format == .hevcAlpha ? "hevc_alpha/\(px)/3po_\(clip)_\(px)_hevc_alpha.mov" : "h264_black/\(px)/3po_\(clip)_\(px)_black.mp4")
    }
    public func path(_ c: AvatarClip, px: Int) -> String { Self.path(clip: c.name, px: px, format: format, rate: rate) }
    /// The still Peak shows under Reduce Motion and beside each reply: the neutral talking sprite (talkAmp 0).
    public static func stillPath(px: Int) -> String { "sprites/\(px)/talking/3po_talk_amp_00_\(px).png" }

    /// The bundled size closest to (and at least) points × backing scale.
    public func pixelSize(points: Double, scale: Double) -> Int {
        let want = Int((points * scale).rounded(.up))
        return sizes.first { $0 >= want } ?? sizes.last ?? 64
    }
    /// Every clip the player can queue (5 loops + 8 transitions), all present in the manifest.
    public var isComplete: Bool {
        AvatarState.allCases.allSatisfy { s in loops.contains(s.rawValue)
            && (s == .idle || (frames["idle_to_\(s.rawValue)"] != nil && frames["\(s.rawValue)_to_idle"] != nil)) }
    }
    public func seconds(_ c: AvatarClip) -> Double { Double(frames[c.name] ?? 0) / fps }
}

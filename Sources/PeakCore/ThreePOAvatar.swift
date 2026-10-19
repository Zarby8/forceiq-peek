import Foundation

// ForceIQ Peak 3PO avatar: BOB Motion's ForceIQ-Peak-3PO-v1 pack (Resources/threepo). Pure logic, unit-tested: which
// state the chat is in (from the transcript Peak already keeps), how the player gets there (the pack's 20-frame
// transitions, switching only at a loop boundary, non-idle to non-idle through idle), and which files the pack carries.

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
    case loop(AvatarState)                         // AVPlayerLooper over the state's seamless loop
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

/// BOB Motion's ForceIQ-Peak-3PO-v1 MANIFEST.json, as shipped: frames/fps per clip and the MD5 of every file.
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

    public static func load(manifest data: Data, root: URL?, format: AvatarFormat = .hevcAlpha) -> ThreePOPack? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let states = o["states"] as? [String: [String: Any]], let trans = o["transitions"] as? [String: [String: Any]] else { return nil }
        let fps = (o["fps"] as? Double) ?? Double((o["fps"] as? Int) ?? 0)
        guard fps > 0 else { return nil }
        var frames: [String: Int] = [:], loops: Set<String> = []
        for (k, v) in states { if let f = v["frames"] as? Int { frames[k] = f; if (v["loop"] as? Bool) == true { loops.insert(k) } } }
        for (k, v) in trans { if let f = v["frames"] as? Int { frames[k] = f } }
        var md5: [String: String] = [:], px: Set<Int> = []
        for f in (o["files"] as? [[String: Any]]) ?? [] {
            guard let p = f["path"] as? String, let m = f["md5"] as? String else { continue }
            md5[p] = m
            if (f["kind"] as? String) == format.rawValue, let x = f["px"] as? Int { px.insert(x) }
        }
        let names = Array(frames.keys)
        var sizes = px.sorted()
        if let root {
            sizes = sizes.filter { x in names.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent(path(clip: $0, px: x, format: format)).path) } }
        }
        return ThreePOPack(name: (o["name"] as? String) ?? "", version: (o["version"] as? String) ?? "", fps: fps, frames: frames,
                           loops: loops, md5: md5, sizes: sizes, format: format)
    }

    public static func path(clip: String, px: Int, format: AvatarFormat) -> String {
        format == .hevcAlpha ? "hevc_alpha/\(px)/3po_\(clip)_\(px)_hevc_alpha.mov" : "h264_black/\(px)/3po_\(clip)_\(px)_black.mp4"
    }
    public func path(_ c: AvatarClip, px: Int) -> String { Self.path(clip: c.name, px: px, format: format) }
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

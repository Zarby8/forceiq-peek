import Foundation

/// Peek's Ghost mark states (BOB Motion pack ForceIQ-Peek-BOB-v1, MANIFEST peak_state_map).
public enum GhostState: String, Sendable, CaseIterable {
    case idle, attention, working, typing, receipt, error

    /// From engine data. `error` is for REAL failures only (a fix GOAT reports failed), never a cancel or empty result.
    public static func from(_ s: EngineSnapshot) -> GhostState {
        if s.fixes.contains(where: { $0.state == "failed" }) { return .error }
        if s.fixesRunning > 0 || s.downloadsRunning > 0 { return .working }
        if s.approvals.contains(where: { !$0.test }) || (s.familyEnabled && !s.family.isEmpty) { return .attention }
        return .idle
    }
}

public enum GhostFormat: String, Sendable, Codable { case h264Black = "h264-black", hevcAlpha = "hevc-alpha" }

/// How one asset plays, read from the pack's MANIFEST.json, never hardcoded frame numbers or durations.
public struct GhostPlayback: Equatable, Sendable {
    public enum Mode: String, Sendable { case loop, introThenLoop = "intro_then_loop", oneShot = "one_shot", oneShotHold = "one_shot_hold" }
    public let asset: String
    public let fps: Double
    public let frames: Int
    public let mode: Mode
    public let intro: ClosedRange<Int>?       // played once
    public let loop: ClosedRange<Int>?        // looped
    public let once: ClosedRange<Int>?        // one-shot range
    public let holdFrame: Int?                // one_shot_hold: stays on this frame
    public let thenIdle: Bool                 // one_shot: go back to idle when done

    /// Seconds for [first frame, last frame + 1) at fps.
    public func seconds(_ r: ClosedRange<Int>) -> (start: Double, end: Double) {
        (Double(r.lowerBound) / fps, Double(r.upperBound + 1) / fps)
    }
}

public struct GhostPack: Sendable {
    public let pack: String
    public let filePrefix: String
    public let sizes: [Int]
    public let stateMap: [String: String]               // Peek state → asset
    public let playback: [String: GhostPlayback]        // asset → playback
    public let md5: [String: String]                    // relative file → md5

    /// Loads BOB Motion's MANIFEST.json as shipped (peak_state_map + states + files). Sizes are the px values that
    /// have an h264-black file for every mapped state under `root` (what this bundle actually carries).
    public static func load(manifest data: Data, root: URL?) -> GhostPack? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let map = o["peak_state_map"] as? [String: [String: Any]], let assets = o["states"] as? [String: [String: Any]] else { return nil }
        func range(_ v: Any?) -> ClosedRange<Int>? {
            guard let a = v as? [Int], a.count == 2, a[0] <= a[1] else { return nil }
            return a[0]...a[1]
        }
        var pb: [String: GhostPlayback] = [:]
        for (name, a) in assets {
            guard let l = a["loop"] as? [String: Any], let m = GhostPlayback.Mode(rawValue: (l["mode"] as? String) ?? "") else { continue }
            let fps = (a["fps"] as? Double) ?? Double((a["fps"] as? Int) ?? 0)
            guard fps > 0, let frames = a["frames"] as? Int, frames > 0 else { continue }
            pb[name] = GhostPlayback(asset: name, fps: fps, frames: frames, mode: m, intro: range(l["intro_frames"]),
                                     loop: range(l["loop_frames"]), once: range(l["frames"]),
                                     holdFrame: l["hold_frame"] as? Int, thenIdle: ((l["then"] as? String) ?? "").hasPrefix("idle"))
        }
        let stateMap = map.compactMapValues { $0["asset"] as? String }
        let prefix = (o["file_prefix"] as? String) ?? "peak-bob-"
        let files = (o["files"] as? [String: [String: Any]]) ?? [:]
        var sizes: Set<Int> = []
        for (k, v) in files where k.hasPrefix("h264-black/") { if let px = (v["px"] as? [Int])?.first { sizes.insert(px) } }
        if let root {
            sizes = sizes.filter { px in stateMap.values.allSatisfy {
                FileManager.default.fileExists(atPath: root.appendingPathComponent("h264-black/\(prefix)\($0)-\(px).mp4").path) } }
        }
        return GhostPack(pack: "\((o["pack"] as? String) ?? "") v\((o["version"] as? String) ?? "")", filePrefix: prefix, sizes: sizes.sorted(),
                         stateMap: stateMap, playback: pb, md5: files.compactMapValues { $0["md5"] as? String })
    }

    public func playback(for s: GhostState) -> GhostPlayback? { stateMap[s.rawValue].flatMap { playback[$0] } }

    /// The bundled size whose px is closest to (and at least) points × backing scale.
    public func pixelSize(points: Double, scale: Double) -> Int {
        let want = Int((points * scale).rounded(.up))
        return sizes.first { $0 >= want } ?? sizes.last ?? 64
    }

    /// Relative path inside the pack for a state, size and format.
    public func file(for s: GhostState, px: Int, format: GhostFormat) -> String? {
        guard let a = stateMap[s.rawValue] else { return nil }
        return format == .hevcAlpha ? "hevc-alpha/\(filePrefix)\(a)-\(px).mov" : "h264-black/\(filePrefix)\(a)-\(px).mp4"
    }
}

/// The Ghost mark parks its steady loop the way the 3PO droid does (AvatarLoopPark): a playing AVPlayerLooper cost
/// ~1.1 % CPU with the chat open and idle (CoreMedia's image queue + decoder every frame, a looper item swap every
/// pass), nearly all of Peek's idle cost. Parked, the loop's decoded frames run as a Core Animation keyframe
/// animation (the render server draws it; Peek itself wakes for nothing). Same frames, same phase, same timing.
public enum GhostMarkPark {
    /// The frames that repeat: a loop's loop range (whole clip when unset); intro_then_loop's loop range once the
    /// intro has played. One-shots never park (they end).
    public static func loopRange(_ pb: GhostPlayback) -> ClosedRange<Int>? {
        switch pb.mode {
        case .loop, .introThenLoop:
            let r = pb.loop ?? 0...max(0, pb.frames - 1)
            return r.upperBound < pb.frames ? r : nil
        case .oneShot, .oneShotHold: return nil
        }
    }
    /// Park only a looping mark that is playing (live), inside its loop, with every loop frame decoded, after the
    /// rig's settle (nothing changed for AvatarIdleCache.settle).
    public static func shouldPark(_ pb: GhostPlayback, inLoop: Bool, playing: Bool, framesReady: Bool, settledFor: Double) -> Bool {
        loopRange(pb) != nil && inLoop && playing && framesReady && settledFor >= AvatarIdleCache.settle
    }
    /// A full decode of the loop range, else no park (the player keeps playing).
    public static func complete(decoded: Int, _ pb: GhostPlayback) -> Bool {
        loopRange(pb).map { decoded == $0.count } ?? false
    }
    /// The parked frame (index into the loop's frames) for an item time `t` seconds into the clip.
    public static func frame(itemTime t: Double, _ pb: GhostPlayback) -> Int {
        guard let r = loopRange(pb) else { return 0 }
        return AvatarLoopPark.frame(local: t - Double(r.lowerBound) / pb.fps, frames: r.count, fps: pb.fps)
    }
}

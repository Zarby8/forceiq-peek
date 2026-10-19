import AVFoundation
import AppKit
import PeakCore
import SwiftUI

// ───────────────────────────── seams: the mark renderer and the glow renderer ─────────────────────────────
/// The Ghost mark. Default: BOB Motion's ForceIQ-Peak-BOB-v1 pack (AVPlayerLayer + AVPlayerLooper, circle-masked, on
/// black), driven by the pack's own data (Resources/bob/MANIFEST.json, as shipped). Swap by asset path:
/// FORCEIQ_PEAK_GHOST_DIR=<a pack root with MANIFEST.json + h264-black/ (+ hevc-alpha/)>.
@MainActor protocol GhostMarkRendering {
    func mark(state: GhostState, points: CGFloat, playing: Bool, onOneShotDone: @escaping @MainActor () -> Void) -> AnyView
}

/// The glow AROUND the mark (never on it: the art is locked). Attention needs none (the pack's own bloom).
/// Default: a SwiftUI Metal .colorEffect when the bundle carries default.metallib, else the native SwiftUI ring.
@MainActor protocol GhostGlowRendering {
    func glow(state: GhostState, reduceMotion: Bool, active: Bool) -> AnyView
}

@MainActor enum GhostAssets {
    static let root: URL? = resolveRoot()
    private static func resolveRoot() -> URL? {
        if let d = ProcessInfo.processInfo.environment["FORCEIQ_PEAK_GHOST_DIR"], !d.isEmpty {
            let u = URL(fileURLWithPath: (d as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("MANIFEST.json").path) { return u }
        }
        if let u = Bundle.main.resourceURL?.appendingPathComponent("bob"),
           FileManager.default.fileExists(atPath: u.appendingPathComponent("MANIFEST.json").path) { return u }
        return nil
    }
    static let pack: GhostPack? = root.flatMap { r in
        (try? Data(contentsOf: r.appendingPathComponent("MANIFEST.json"))).flatMap { GhostPack.load(manifest: $0, root: r) }
    }
    /// Format setting (settings.json ghostFormat). hevc-alpha is unproven in AVFoundation: any miss falls back to h264-black.
    static var format: GhostFormat = .h264Black

    private static var urls: [String: URL?] = [:]
    static func url(_ s: GhostState, px: Int) -> URL? {
        let k = "\(s.rawValue)-\(px)-\(format.rawValue)"
        if let hit = urls[k] { return hit }
        let u = resolve(s, px: px); urls[k] = u; return u
    }
    private static func resolve(_ s: GhostState, px: Int) -> URL? {
        guard let root, let pack else { return nil }
        for f in (format == .hevcAlpha ? [GhostFormat.hevcAlpha, .h264Black] : [.h264Black]) {
            if let rel = pack.file(for: s, px: px, format: f) {
                let u = root.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
        }
        return nil
    }
}

@MainActor struct VideoGhostMarkRenderer: GhostMarkRendering {
    func mark(state: GhostState, points: CGFloat, playing: Bool, onOneShotDone: @escaping @MainActor () -> Void) -> AnyView {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let pack = GhostAssets.pack, let pb = pack.playback(for: state),
              let u = GhostAssets.url(state, px: pack.pixelSize(points: Double(points), scale: Double(scale))) else {
            return PlaceholderGhostMarkRenderer().mark(state: state, points: points, playing: playing, onOneShotDone: onOneShotDone)
        }
        return AnyView(GhostVideo(url: u, playback: pb, playing: playing, onOneShotDone: onOneShotDone).clipShape(Circle()))
    }
}

/// PLACEHOLDER Ghost mark (vector). Only shown when the BOB Motion loops are missing from the bundle.
@MainActor struct PlaceholderGhostMarkRenderer: GhostMarkRendering {
    func mark(state: GhostState, points: CGFloat, playing: Bool, onOneShotDone: @escaping @MainActor () -> Void) -> AnyView {
        AnyView(GeometryReader { g in
            let w = g.size.width
            ZStack {
                Circle().fill(Color.black)
                Path { p in                                   // a simple ghost silhouette: dome + wavy hem
                    let r = w * 0.30, cx = w / 2, top = w * 0.20, hem = w * 0.78
                    p.move(to: CGPoint(x: cx - r, y: hem))
                    p.addLine(to: CGPoint(x: cx - r, y: top + r))
                    p.addArc(center: CGPoint(x: cx, y: top + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                    p.addLine(to: CGPoint(x: cx + r, y: hem))
                    for i in 0..<3 {
                        let x0 = cx + r - CGFloat(i) * (2 * r / 3)
                        p.addQuadCurve(to: CGPoint(x: x0 - r / 3, y: hem), control: CGPoint(x: x0 - r / 6, y: hem - w * 0.08))
                    }
                    p.closeSubpath()
                }.fill(Color.white)
                Circle().fill(Color.black).frame(width: w * 0.08).offset(x: -w * 0.09, y: -w * 0.04)
                Circle().fill(Color.black).frame(width: w * 0.08).offset(x: w * 0.09, y: -w * 0.04)
            }
            .accessibilityLabel("Ghost mark (placeholder)")
        })
    }
}

struct GhostVideo: NSViewRepresentable {
    let url: URL
    let playback: GhostPlayback
    let playing: Bool
    let onOneShotDone: @MainActor () -> Void
    func makeNSView(context: Context) -> GhostPlayerView { GhostPlayerView() }
    func updateNSView(_ v: GhostPlayerView, context: Context) {
        v.onOneShotDone = onOneShotDone
        v.configure(url: url, playback: playback, playing: playing)
    }
}

/// AVQueuePlayer on black, circle-masked so the square edge never shows. Playback comes from the pack data:
/// loop (AVPlayerLooper over the loop range), intro_then_loop (intro once, then loop), one_shot (once, then the view
/// hands back to idle), one_shot_hold (once, hold the hold frame). Paused while hidden or under Reduce Motion.
final class GhostPlayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var current: (URL, GhostPlayback)?
    private var endObserver: NSObjectProtocol?
    var onOneShotDone: (@MainActor () -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        layer?.masksToBounds = true
        CATransaction.commit()
    }

    func configure(url: URL, playback: GhostPlayback, playing: Bool) {
        if current?.0 != url || current?.1 != playback {
            current = (url, playback)
            build(url: url, pb: playback)
            isPlaying = true              // a new player: the branch below either plays it or parks it on a still frame
        }
        if playing {
            if player?.rate == 0 { player?.play() }
            isPlaying = true
        } else if isPlaying {
            isPlaying = false
            // Collapsed + idle: stop decoding and hold a still first frame (of the loop, when the pack has one).
            player?.pause()
            let start = current.map { pb -> Double in
                let p = pb.1
                switch p.mode {
                case .loop, .introThenLoop: return p.seconds(p.loop ?? 0...0).start
                case .oneShot, .oneShotHold: return p.seconds(p.once ?? 0...0).start
                }
            } ?? 0
            player?.seek(to: t(start), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
    private var isPlaying = false

    private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
    private func range(_ r: ClosedRange<Int>, _ pb: GhostPlayback) -> CMTimeRange {
        let s = pb.seconds(r)
        return CMTimeRange(start: t(s.start), end: t(s.end))
    }

    private func build(url: URL, pb: GhostPlayback) {
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        looper?.disableLooping(); looper = nil
        let p = AVQueuePlayer()
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        player = p
        playerLayer.player = p
        func onEnd(_ item: AVPlayerItem, _ f: @escaping @MainActor (AVQueuePlayer) -> Void) {
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                                 queue: .main) { [weak self, weak p] _ in
                MainActor.assumeIsolated { guard let self, let p, self.player === p else { return }; f(p) }
            }
        }
        switch pb.mode {
        case .loop:
            let r = pb.loop ?? 0...max(0, pb.frames - 1)
            looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url), timeRange: range(r, pb))
        case .introThenLoop:
            let intro = pb.intro ?? 0...0, loop = pb.loop ?? 0...max(0, pb.frames - 1)
            let item = AVPlayerItem(url: url)
            item.forwardPlaybackEndTime = t(pb.seconds(intro).end)
            p.insert(item, after: nil)
            onEnd(item) { [weak self] p in
                self?.looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url), timeRange: self?.range(loop, pb) ?? .zero)
                p.play()
            }
        case .oneShot, .oneShotHold:
            let r = pb.once ?? 0...max(0, pb.frames - 1)
            let item = AVPlayerItem(url: url)
            let hold = pb.mode == .oneShotHold ? (pb.holdFrame ?? r.upperBound) : r.upperBound
            item.forwardPlaybackEndTime = t(pb.mode == .oneShotHold ? Double(hold) / pb.fps + 0.5 / pb.fps : pb.seconds(r).end)
            p.actionAtItemEnd = .pause
            p.insert(item, after: nil)
            onEnd(item) { [weak self] p in
                if pb.mode == .oneShotHold { p.seek(to: self?.t(Double(hold) / pb.fps) ?? .zero, toleranceBefore: .zero, toleranceAfter: .zero) }
                else if pb.thenIdle { self?.onOneShotDone?() }
            }
        }
    }
}

// ───────────────────────────── glow ─────────────────────────────
enum GlowTint {
    static func color(_ s: GhostState) -> Color { .peakGreen }
}

/// Native glow: a soft ring that breathes (TimelineView(.animation) runs at the display's refresh, 120 Hz on ProMotion).
@MainActor struct NativeGlowRenderer: GhostGlowRendering {
    func glow(state: GhostState, reduceMotion: Bool, active: Bool) -> AnyView {
        if state == .attention || state == .error { return AnyView(EmptyView()) }   // attention: the pack's own bloom
        let tint = GlowTint.color(state)
        let strength: Double = state == .working ? 0.7 : 0.45
        if reduceMotion {
            return AnyView(Circle().stroke(tint, lineWidth: 1.5).blur(radius: 2).opacity(strength))
        }
        // Paused (one static frame) unless the mark is live: collapsed + idle costs no frames.
        return AnyView(TimelineView(.animation(paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 1.6) + 1) / 2
            ZStack {
                Circle().stroke(tint, lineWidth: 1.5).opacity(0.55 + 0.45 * phase)
                Circle().stroke(tint, lineWidth: 4).blur(radius: 4 + 3 * phase).opacity(strength * (0.35 + 0.4 * phase))
            }
        })
    }
}

/// Metal glow (.colorEffect on a ring around the mark). Used only when the bundle has default.metallib.
@available(macOS 14.0, *)
@MainActor struct ShaderGlowRenderer: GhostGlowRendering {
    static var available: Bool { Bundle.main.url(forResource: "default", withExtension: "metallib") != nil }
    func glow(state: GhostState, reduceMotion: Bool, active: Bool) -> AnyView {
        if state == .attention || state == .error { return AnyView(EmptyView()) }
        let tint = GlowTint.color(state)
        let start = Date()
        return AnyView(TimelineView(.animation(paused: reduceMotion || !active)) { ctx in
            let t = Float(ctx.date.timeIntervalSince(start))
            Circle().stroke(Color.white, lineWidth: 6).padding(-3)
                .colorEffect(ShaderLibrary.default.ghostGlow(.float(t), .color(tint), .float(0.6)))
                .blur(radius: 2)
        })
    }
}

extension Color {
    static let peakGreen = Color(red: 0x5B / 255, green: 0xE3 / 255, blue: 0x7D / 255)
    static let peakGold = Color(red: 0xF5 / 255, green: 0xC5 / 255, blue: 0x42 / 255)
}

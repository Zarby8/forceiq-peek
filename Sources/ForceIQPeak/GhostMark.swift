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
/// A steady loop parks (GhostMarkPark): its decoded frames run as a Core Animation keyframe animation and the player
/// pauses, so an open, idle chat decodes nothing for the mark. Any change (state, pause, window) unparks first.
final class GhostPlayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    private let parkLayer = CALayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var current: (URL, GhostPlayback)?
    private var endObserver: NSObjectProtocol?
    private var inLoop = false                     // the player is inside the repeating range (loop, or past the intro)
    private(set) var parked = false
    private var parkBegin = 0.0                    // host time of the parked loop's frame 0
    private var settleGen = 0
    @MainActor private static var loopFrames: [String: [CGImage]] = [:]
    @MainActor private static var decoding: Set<String> = []
    var onOneShotDone: (@MainActor () -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
        parkLayer.contentsGravity = .resizeAspectFill
        parkLayer.backgroundColor = NSColor.black.cgColor
        parkLayer.isHidden = true
        parkLayer.actions = ["contents": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(parkLayer)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        parkLayer.frame = bounds
        parkLayer.contentsScale = window?.backingScaleFactor ?? 2
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        layer?.masksToBounds = true
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { unpark(resume: false); player?.pause(); isPlaying = false } else if isPlaying { settled() }
    }

    func configure(url: URL, playback: GhostPlayback, playing: Bool) {
        if current?.0 != url || current?.1 != playback {
            unpark(resume: false)
            current = (url, playback)
            build(url: url, pb: playback)
            isPlaying = true              // a new player: the branch below either plays it or parks it on a still frame
        }
        if playing {
            if parked { return }
            if player?.rate == 0 { player?.play() }
            isPlaying = true
            settled()
        } else if isPlaying {
            isPlaying = false
            unpark(resume: false)
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
        inLoop = false
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
            inLoop = true
        case .introThenLoop:
            let intro = pb.intro ?? 0...0, loop = pb.loop ?? 0...max(0, pb.frames - 1)
            let item = AVPlayerItem(url: url)
            item.forwardPlaybackEndTime = t(pb.seconds(intro).end)
            p.insert(item, after: nil)
            onEnd(item) { [weak self] p in
                self?.looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url), timeRange: self?.range(loop, pb) ?? .zero)
                self?.inLoop = true
                p.play()
                self?.settled()
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
        loadLoopFrames()
    }

    // ── the parked loop (GhostMarkPark) ──
    private func key(_ u: URL, _ pb: GhostPlayback) -> String? {
        GhostMarkPark.loopRange(pb).map { "\(u.path)#\($0.lowerBound)-\($0.upperBound)" }
    }

    /// Something changed (or may now be steady): check again after the settle, if nothing else changes first.
    private func settled() {
        settleGen += 1
        let g = settleGen
        loadLoopFrames()
        DispatchQueue.main.asyncAfter(deadline: .now() + AvatarIdleCache.settle + 0.02) { [weak self] in
            MainActor.assumeIsolated { if let self, self.settleGen == g { self.tryPark() } }
        }
    }

    private func tryPark() {
        guard !parked, window != nil, let (u, pb) = current, let k = key(u, pb), let frames = Self.loopFrames[k],
              let r = GhostMarkPark.loopRange(pb), let p = player, p.rate != 0,
              let it = p.currentItem, it.status == .readyToPlay,
              GhostMarkPark.shouldPark(pb, inLoop: inLoop, playing: isPlaying, framesReady: true, settledFor: AvatarIdleCache.settle)
        else { return }
        let tt = it.currentTime().seconds
        guard tt.isFinite else { return }
        let now = CACurrentMediaTime()
        parkBegin = now - (tt - Double(r.lowerBound) / pb.fps)
        let a = CAKeyframeAnimation(keyPath: "contents")
        a.values = frames
        a.calculationMode = .discrete
        a.duration = Double(frames.count) / pb.fps
        a.repeatCount = .infinity
        a.beginTime = parkLayer.convertTime(parkBegin, from: nil)
        a.isRemovedOnCompletion = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        parkLayer.contents = frames[GhostMarkPark.frame(itemTime: tt, pb)]
        parkLayer.add(a, forKey: "loop")
        parkLayer.isHidden = false
        playerLayer.isHidden = true
        CATransaction.commit()
        p.pause()
        parked = true
        ThreePOAssets.log?("ghost mark parked asset=\(pb.asset) frames=\(frames.count)")
    }

    /// Back to the player. `resume`: the loop picks up at the parked phase (same frame, no jump).
    private func unpark(resume: Bool) {
        settleGen += 1
        guard parked else { return }
        parked = false
        if resume, let (_, pb) = current, let r = GhostMarkPark.loopRange(pb), let it = player?.currentItem {
            let n = Double(r.count) / pb.fps
            let ph = (CACurrentMediaTime() - parkBegin).truncatingRemainder(dividingBy: max(0.001, n))
            it.seek(to: t(Double(r.lowerBound) / pb.fps + ph), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.isHidden = false
        parkLayer.removeAllAnimations()
        parkLayer.contents = nil
        parkLayer.isHidden = true
        CATransaction.commit()
        if resume, isPlaying { player?.play() }
        ThreePOAssets.log?("ghost mark unparked")
    }

    /// Decodes the loop range once per launch (off the main thread). A short or failed decode never parks.
    private func loadLoopFrames() {
        guard let (u, pb) = current, let k = key(u, pb), let r = GhostMarkPark.loopRange(pb),
              Self.loopFrames[k] == nil, !Self.decoding.contains(k) else { return }
        Self.decoding.insert(k)
        let s = pb.seconds(r)
        Task.detached(priority: .utility) {
            let frames = Self.decode(u, from: s.start, to: s.end)
            await MainActor.run {
                Self.decoding.remove(k)
                if GhostMarkPark.complete(decoded: frames.count, pb) {
                    Self.loopFrames[k] = frames
                    ThreePOAssets.log?("ghost mark loop decoded asset=\(pb.asset) frames=\(frames.count)")
                } else {
                    ThreePOAssets.log?("ghost mark loop decode short asset=\(pb.asset) frames=\(frames.count) want=\(r.count): stays on the player")
                }
            }
        }
    }

    nonisolated private static func decode(_ u: URL, from a: Double, to b: Double) -> [CGImage] {
        let asset = AVURLAsset(url: u)
        guard let track = asset.tracks(withMediaType: .video).first, let r = try? AVAssetReader(asset: asset) else { return [] }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.alwaysCopiesSampleData = false
        guard r.canAdd(out) else { return [] }
        r.add(out)
        guard r.startReading() else { return [] }
        let ctx = CIContext(options: [.cacheIntermediates: false])
        var frames: [CGImage] = []
        let eps = 0.25 / 600
        while let sb = out.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard pts.isFinite, pts + eps >= a, pts + eps < b, let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let im = CIImage(cvPixelBuffer: pb)
            if let cg = ctx.createCGImage(im, from: im.extent) { frames.append(cg) }
        }
        return r.status == .completed ? frames : []
    }
}

// ───────────────────────────── glow ─────────────────────────────
enum GlowTint {
    static func color(_ s: GhostState) -> Color { .peakGreen }
}

/// Native glow: a soft ring that breathes (GlowBreath). Core Animation layer animations, run by the render server:
/// no SwiftUI update or CA commit per frame from Peak (the old TimelineView(.animation) re-rendered the whole expanded
/// panel at display refresh: ~8-13 % CPU, chat open and idle). Not live (collapsed + idle, hidden): a still frame.
@MainActor struct NativeGlowRenderer: GhostGlowRendering {
    func glow(state: GhostState, reduceMotion: Bool, active: Bool) -> AnyView {
        if state == .attention || state == .error { return AnyView(EmptyView()) }   // attention: the pack's own bloom
        let tint = GlowTint.color(state)
        let strength = GlowBreath.strength(state)
        if reduceMotion {
            return AnyView(Circle().stroke(tint, lineWidth: 1.5).blur(radius: 2).opacity(strength))
        }
        return AnyView(CAGlowView(tint: NSColor(tint), breath: GlowBreath(strength: strength), live: active))
    }
}

/// The breathing ring as two CAShapeLayers: a thin stroke (opacity breathes) and a stroked shadow path (radius and
/// opacity breathe). Animations are added once per (tint, strength, live) and run in the render server.
struct CAGlowView: NSViewRepresentable {
    let tint: NSColor
    let breath: GlowBreath
    let live: Bool
    func makeNSView(context: Context) -> CAGlowNSView { CAGlowNSView() }
    func updateNSView(_ v: CAGlowNSView, context: Context) { v.configure(tint: tint, breath: breath, live: live) }
}

final class CAGlowNSView: NSView {
    private let inner = CAShapeLayer()
    private let outer = CAShapeLayer()
    private var key: (NSColor, GlowBreath, Bool)?
    /// Test seam / debug: whether the breath is currently animating.
    private(set) var animating = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [outer, inner] { l.fillColor = nil; l.masksToBounds = false; layer?.addSublayer(l) }
        outer.strokeColor = nil
        outer.shadowOffset = .zero
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [outer, inner] { l.frame = bounds }
        let ring = CGPath(ellipseIn: bounds, transform: nil)       // = SwiftUI Circle() in this frame; strokes straddle it
        inner.path = ring
        outer.shadowPath = ring.copy(strokingWithWidth: CGFloat(key?.1.outerWidth ?? 4), lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        CATransaction.commit()
    }
    func configure(tint: NSColor, breath: GlowBreath, live: Bool) {
        if let k = key, k.0 == tint, k.1 == breath, k.2 == live { return }   // SwiftUI updates never restart the breath
        key = (tint, breath, live)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        inner.strokeColor = tint.cgColor
        inner.lineWidth = CGFloat(breath.innerWidth)
        outer.shadowColor = tint.cgColor
        let still = breath.at(phase: 0.5)
        inner.opacity = Float(still.inner); outer.shadowOpacity = Float(still.outer); outer.shadowRadius = CGFloat(still.blur)
        inner.removeAllAnimations(); outer.removeAllAnimations()
        animating = live
        if live {
            let sine = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)   // ≈ (sin + 1) / 2 between trough and crest
            func breathe(_ path: String, _ r: ClosedRange<Double>) -> CABasicAnimation {
                let a = CABasicAnimation(keyPath: path)
                a.fromValue = r.lowerBound; a.toValue = r.upperBound
                a.duration = GlowBreath.halfPeriod; a.autoreverses = true; a.repeatCount = .infinity
                a.timingFunction = sine; a.isRemovedOnCompletion = false
                return a
            }
            inner.add(breathe("opacity", breath.innerOpacity), forKey: "breath")
            let g = CAAnimationGroup()
            g.animations = [breathe("shadowOpacity", breath.outerOpacity), breathe("shadowRadius", breath.outerBlur)]
            g.duration = .infinity; g.isRemovedOnCompletion = false
            outer.add(g, forKey: "breath")
        }
        CATransaction.commit()
        needsLayout = true
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
        // Ambient: capped at PeakTokens.ambientShaderFPS (a SwiftUI re-render per tick; never display refresh).
        return AnyView(TimelineView(.animation(minimumInterval: 1 / PeakTokens.ambientShaderFPS, paused: reduceMotion || !active)) { ctx in
            let t = Float(ctx.date.timeIntervalSince(start))
            Circle().stroke(Color.white, lineWidth: 6).padding(-3)
                .colorEffect(ShaderLibrary.default.ghostGlow(.float(t), .color(tint), .float(0.6)))
                .blur(radius: 2)
        })
    }
}

extension Color {
    static let peakGreen = Color(hex: Brand.greenHex)
    static let peakGold = Color(hex: Brand.goldHex)
}

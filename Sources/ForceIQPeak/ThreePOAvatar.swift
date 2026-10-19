import AVFoundation
import AppKit
import PeakCore
import SwiftUI

// ───────────────────────────── 3PO avatar: BOB Motion ForceIQ-Peek-3PO-v1 (Resources/threepo) ─────────────────────────────
/// Assets: the bundled pack (Resources/threepo: MANIFEST.json v1.1 as shipped, hevc_alpha 64 px at 60 fps and, from the
/// v1.1 add-on, at 120 fps under fps120/, the neutral still), or
/// FORCEIQ_PEAK_3PO_DIR=<an unpacked pack root>. hevc_alpha (real alpha, proven in AVPlayerLayer on macOS 26.6.2);
/// h264_black only if a pack root has no complete hevc_alpha set. Nothing found: the static droid mark.
/// The live rig (Resources/threepo/rig/3po.usdz) comes first when it loads (ThreePORig.swift).
@MainActor enum ThreePOAssets {
    static let root: URL? = resolveRoot()
    private static func resolveRoot() -> URL? {
        if let d = ProcessInfo.processInfo.environment["FORCEIQ_PEAK_3PO_DIR"], !d.isEmpty {
            let u = URL(fileURLWithPath: (d as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("MANIFEST.json").path) { return u }
        }
        if let u = Bundle.main.resourceURL?.appendingPathComponent("threepo"),
           FileManager.default.fileExists(atPath: u.appendingPathComponent("MANIFEST.json").path) { return u }
        return nil
    }
    static let pack: ThreePOPack? = {
        guard let r = root, let d = try? Data(contentsOf: r.appendingPathComponent("MANIFEST.json")) else { return nil }
        for f in [AvatarFormat.hevcAlpha, .h264Black] {
            if let p = ThreePOPack.load(manifest: d, root: r, format: f), p.isComplete, !p.sizes.isEmpty { return p }
        }
        return nil
    }()
    /// The v1.1 120 fps add-on: the same format, every clip the 60 fps pack has, and at least one size on disk.
    static let pack120: ThreePOPack? = {
        guard let r = root, let p60 = pack, let d = try? Data(contentsOf: r.appendingPathComponent("MANIFEST.json")),
              let p = ThreePOPack.load(manifest: d, root: r, format: p60.format, rate: .fps120),
              p.isComplete, Set(p.frames.keys) == Set(p60.frames.keys), !p.sizes.isEmpty else { return nil }
        return p
    }()
    /// FORCEIQ_PEAK_3PO_FPS=60 pins the 60 fps pack and rig rate everywhere.
    static let fpsOverride = ProcessInfo.processInfo.environment["FORCEIQ_PEAK_3PO_FPS"]
    /// The rate for the screen Peek is on (AvatarFrameRate.choose: 120 only on a ≥ 120 Hz screen, else 60).
    static func rate(for screen: NSScreen?, px: Int? = nil) -> AvatarFrameRate {
        let has120 = pack120.map { p in px.map { p.sizes.contains($0) } ?? true } ?? false
        return AvatarFrameRate.choose(screenMaxFPS: screen?.maximumFramesPerSecond, has120: has120, override: fpsOverride)
    }
    static func pack(_ r: AvatarFrameRate) -> ThreePOPack? { r == .fps120 ? (pack120 ?? pack) : pack }
    static func url(_ c: AvatarClip, px: Int, rate: AvatarFrameRate = .fps60) -> URL? {
        guard let root, let p = pack(rate) else { return nil }
        return root.appendingPathComponent(p.path(c, px: px))
    }
    static let still: NSImage? = {
        guard let root, let pack else { return nil }
        for px in pack.sizes.reversed() {   // the largest still we carry (64 px today)
            if let i = NSImage(contentsOf: root.appendingPathComponent(ThreePOPack.stillPath(px: px))) { return i }
        }
        return nil
    }()
    /// Clip changes go to peak.log (clip names + a ms clock only) so the visual proof can line frames up.
    static var log: ((String) -> Void)?
    /// Demo only (FORCEIQ_PEAK_DEMO=1 + FORCEIQ_PEAK_DEMO_REDUCE_MOTION=1): the Reduce Motion path, for the visual proof.
    static var demoReduceMotion = false
}

/// The 3PO slot: rig (live, RealityKit) → the pack's rendered loops → the static droid mark, by what loaded
/// (AvatarTier). Reduce Motion or not live: a still. Each reply's small avatar is the still (one live droid per chat).
@MainActor struct AnimatedThreePOAvatar: ThreePOAvatarRendering {
    func avatar(size: CGFloat, signals: AvatarSignals, live: Bool, reduceMotion: Bool) -> AnyView {
        AnyView(ThreePOAvatarSlot(rig: ThreePORigLoader.shared, size: size, signals: signals, live: live,
                                  reduceMotion: reduceMotion || ThreePOAssets.demoReduceMotion))
    }
    func still(size: CGFloat) -> AnyView {
        guard let i = ThreePOAssets.still else { return StaticDroidAvatar().still(size: size) }
        return AnyView(Image(nsImage: i).resizable().interpolation(.high).frame(width: size, height: size).accessibilityLabel("3PO"))
    }
}

struct ThreePOAvatarSlot: View {
    @ObservedObject var rig: ThreePORigLoader
    let size: CGFloat
    let signals: AvatarSignals
    let live: Bool
    let reduceMotion: Bool
    var tier: AvatarTier {
        AvatarTier.choose(rig: rig.loaded, rigEnabled: ThreePORigFlag.enabled, loops: ThreePOAssets.pack != nil,
                          stillAvailable: ThreePOAssets.still != nil, reduceMotion: reduceMotion, live: live)
    }
    var body: some View {
        Group {
            switch tier {
            case .rig: if #available(macOS 15.0, *) { ThreePORigView(rig: rig, signals: signals) } else { DroidMark() }
            case .loops:
                let px = ThreePOAssets.pack!.pixelSize(points: Double(size), scale: Double(NSScreen.main?.backingScaleFactor ?? 2))
                ThreePOVideo(px: px, signals: signals, live: live)
            case .still: AnimatedThreePOAvatar().still(size: size)
            case .mark: DroidMark()
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("3PO")
        .onAppear { rig.loadIfNeeded() }
        .onChange(of: tier) { _, t in ThreePOAssets.log?("3po avatar tier=\(t.rawValue)") }
    }
}

struct ThreePOVideo: NSViewRepresentable {
    let px: Int
    let signals: AvatarSignals
    let live: Bool
    func makeNSView(context: Context) -> ThreePOPlayerView { ThreePOPlayerView(px: px) }
    func updateNSView(_ v: ThreePOPlayerView, context: Context) { v.update(signals: signals, live: live) }
    static func dismantleNSView(_ v: ThreePOPlayerView, coordinator: ()) { v.tearDown() }
}

/// Carries the KVO's new item to the main queue.
struct ItemRef: @unchecked Sendable { let item: AVPlayerItem?; init(_ i: AVPlayerItem?) { item = i } }

/// A queued clip that knows what it is, with a video output (the frame a cut freezes is read from it).
final class ThreePOClipItem: AVPlayerItem {
    var clip: AvatarClip = .loop(.idle)
}

/// One AVQueuePlayer on a transparent AVPlayerLayer. The queue is the plan's clips then the settled state's loop,
/// kept topped up with passes of that loop (gapless, like AVPlayerLooper, but every item is ours and carries a video
/// output: AVPlayerLooper's replicas drop outputs). A state change starts at once (AvatarSwitch): the frame on screen
/// freezes into an overlay, the queue is replaced under it with the pack's 20-frame transitions, and once the first
/// new frame is up the overlay fades out (AvatarCrossfade, 130 ms, ease-out). The alert flash settling back to idle
/// is the one change queued behind the clip on screen. Paused while not live; torn down when the chat unmounts.
/// Frame rate: the 120 fps clips only while the window is on a ≥ 120 Hz screen (ThreePOAssets.rate); a screen change
/// re-queues everything behind the clip on screen at the new rate (same names and durations), so the swap is gapless.
/// A steady idle parks (AvatarLoopPark): the idle clip's decoded frames play as a layer animation, the player pauses
/// (no CoreMedia work per frame); any change unparks with the parked frame as the cut's frozen frame.
final class ThreePOPlayerView: NSView {
    private let px: Int
    private(set) var rate: AvatarFrameRate = .fps60
    private var screenObs: NSObjectProtocol?
    private var announced = false
    private let playerLayer = AVPlayerLayer()
    private let snapLayer = CALayer()                              // the frozen frame a cut crossfades from
    private let parkLayer = CALayer()                              // the parked idle loop (a contents keyframe animation)
    private(set) var parked = false
    private var parkBegin = 0.0                                    // host time of the parked loop's frame 0
    private var settleGen = 0                                      // bumped by every change; a park check needs it unchanged
    @MainActor private static var idleFrames: [URL: [CGImage]] = [:]
    @MainActor private static var decoding: Set<URL> = []
    private let player = AVQueuePlayer()
    private var loopState: AvatarState = .idle                     // what the queue settles into (topped up with its passes)
    private var director = ThreePOAvatarDirector()
    private var signals = AvatarSignals()
    private(set) var current: AvatarClip = .loop(.idle)
    private var itemObs: NSKeyValueObservation?
    private var live = false
    private var fade = AvatarCrossfade()
    private var snap: CGImage?
    private var cutFrom: AVPlayerItem?                             // the item that was on screen when the cut landed
    private var link: CADisplayLink?
    private static let ci = CIContext(options: [.cacheIntermediates: false])
    private static let outputAttrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                     kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]

    init(px: Int) {
        self.px = px
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = ThreePOAssets.pack?.format == .h264Black ? NSColor.black.cgColor : NSColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(playerLayer)
        parkLayer.contentsGravity = .resizeAspect
        parkLayer.isHidden = true
        parkLayer.actions = ["contents": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(parkLayer)
        snapLayer.contentsGravity = .resizeAspect
        snapLayer.opacity = 0
        snapLayer.actions = ["opacity": NSNull(), "contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(snapLayer)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        playerLayer.player = player
        insert(AvatarPlan(clips: [], loop: .idle), after: nil)
        Self.warm()
        itemObs = player.observe(\.currentItem, options: [.new]) { [weak self] _, change in
            let item = ItemRef(change.newValue ?? nil)               // the item that came on screen, not whatever is current later
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.itemChanged(item.item) } }
        }
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        parkLayer.frame = bounds
        snapLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = screenObs { NotificationCenter.default.removeObserver(o); screenObs = nil }
        if let w = window {
            screenObs = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenChanged() }
            }
            screenChanged()
        }
        if window == nil { unpark(resume: false); player.pause(); stopLink() } else if live { player.play(); settled() }
    }

    /// Re-choose the rate for the window's screen. Changed: the queue behind the clip on screen is rebuilt at the new
    /// rate (nothing played yet: the whole queue), so the next clip boundary is the switch and nothing is cut.
    private func screenChanged() {
        let r = ThreePOAssets.rate(for: window?.screen, px: px)
        let first = !announced
        announced = true
        guard r != rate else {
            if first { ThreePOAssets.log?("3po avatar fps=\(r.rawValue) screen_max=\(window?.screen?.maximumFramesPerSecond ?? 0) tier=loops") }
            return
        }
        unpark(resume: true)                                     // the parked frames are per rate; re-park after the swap
        rate = r
        let cur = player.currentItem
        let fresh = (cur?.currentTime().seconds ?? 0) < 0.001 && player.rate == 0
        let keep: AVPlayerItem? = fresh ? nil : cur
        let clips = player.items().filter { $0 !== keep }.compactMap { ($0 as? ThreePOClipItem)?.clip }
        for it in player.items() where it !== keep { player.remove(it) }
        var after = keep
        for c in clips { if let it = item(c) { player.insert(it, after: after); after = it } }
        topUp()
        ThreePOAssets.log?("3po avatar fps=\(r.rawValue) screen_max=\(window?.screen?.maximumFramesPerSecond ?? 0) tier=loops")
        settled()
    }

    func update(signals s: AvatarSignals, live l: Bool) {
        if s != signals {
            signals = s
            if let plan = director.update(s, current: current) { route(plan) }
        }
        if l != live || (l && player.rate == 0 && !parked) {
            live = l
            if l { player.play(); settled() } else { unpark(resume: true); player.pause() }    // paused: a still, no decode
        }
    }

    func tearDown() {
        settleGen += 1
        parkLayer.removeAllAnimations()
        itemObs = nil
        if let o = screenObs { NotificationCenter.default.removeObserver(o); screenObs = nil }
        stopLink()
        player.pause()
        player.removeAllItems()
        playerLayer.player = nil
    }

    private func itemChanged(_ item: AVPlayerItem?) {
        topUp()
        guard let c = (item as? ThreePOClipItem)?.clip else { return }
        if c != current {
            current = c
            ThreePOAssets.log?("3po avatar clip=\(c.name)\(Self.kind(c)) t=\(Self.epoch())")
            settled()
        }
        if let plan = director.update(signals, current: c) { route(plan) }
    }

    /// Keep two passes of the settled loop queued behind whatever is playing (gapless looping).
    private func topUp() {
        guard player.currentItem != nil || player.items().isEmpty == false else { return }
        while player.items().count < 3, let it = item(.loop(loopState)) { player.insert(it, after: player.items().last) }
    }
    private func item(_ c: AvatarClip) -> ThreePOClipItem? {
        guard let u = ThreePOAssets.url(c, px: px, rate: rate) else { return nil }
        let it = ThreePOClipItem(url: u); it.clip = c
        it.add(AVPlayerItemVideoOutput(pixelBufferAttributes: Self.outputAttrs))
        return it
    }
    private static func kind(_ c: AvatarClip) -> String {
        switch c { case .loop: return " loop"; case .once: return " once"; case .transition: return "" }
    }
    private static func epoch() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    // ── frames (the cut's frozen frame) ──
    private static func output(_ it: AVPlayerItem) -> AVPlayerItemVideoOutput? {
        it.outputs.lazy.compactMap { $0 as? AVPlayerItemVideoOutput }.first
    }
    /// The first CoreImage render costs ~50 ms; pay it before the first cut.
    private static var warmed = false
    private static func warm() {
        guard !warmed else { return }
        warmed = true
        let im = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        _ = ci.createCGImage(im.composited(over: im), from: im.extent)
    }

    /// The frame on screen now: the parked loop's frame, else the current item's video output.
    private func frameOnScreen() -> CGImage? {
        if parked, let f = parkedFrame(CACurrentMediaTime()) { return f }
        guard let it = player.currentItem, let o = Self.output(it) else { return nil }
        let t = o.itemTime(forHostTime: CACurrentMediaTime())
        guard let pb = o.copyPixelBuffer(forItemTime: t.isValid ? t : it.currentTime(), itemTimeForDisplay: nil)
                ?? o.copyPixelBuffer(forItemTime: it.currentTime(), itemTimeForDisplay: nil) else { return nil }
        let im = CIImage(cvPixelBuffer: pb)
        return Self.ci.createCGImage(im, from: im.extent)
    }
    /// What is on screen mid-fade: the old overlay at `alpha` over the live frame, flattened into one image.
    private func composite(alpha a: Double) -> CGImage? {
        let live = frameOnScreen()
        guard let old = snap else { return live }
        var top = CIImage(cgImage: old).applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(a))])
        if let live { top = top.composited(over: CIImage(cgImage: live)) }
        return Self.ci.createCGImage(top, from: CGRect(x: 0, y: 0, width: old.width, height: old.height))
    }

    private func route(_ plan: AvatarPlan) {
        switch AvatarSwitch.mode(current: current, plan: plan) {
        case .cut: cut(plan)
        case .boundary: queue(plan)
        }
    }

    /// Start `plan` now: freeze the frame on screen, replace the queue under it, fade the frozen frame out once the
    /// new clip shows (latest wins: one overlay, one queue).
    private func cut(_ plan: AvatarPlan) {
        guard ThreePOAssets.pack != nil else { return }
        let how = fade.cut(now: CACurrentMediaTime())
        switch how {
        case .keep: break
        case .frame: snap = frameOnScreen()
        case .composite(let a): snap = composite(alpha: a)
        }
        unpark(resume: false)                                    // the parked frame is the frozen frame; the queue is replaced
        CATransaction.begin(); CATransaction.setDisableActions(true)
        snapLayer.contents = snap
        snapLayer.opacity = snap == nil ? 0 : 1
        CATransaction.commit()
        cutFrom = player.currentItem
        player.removeAllItems()
        insert(plan, after: nil)
        let snapKind: String = { switch how { case .keep: return "keep"; case .frame: return "frame"; case .composite: return "composite" } }()
        ThreePOAssets.log?("3po avatar cut plan=\(plan.clips.map(\.name).joined(separator: ",")) then=\(plan.loop.rawValue) snap=\(snap == nil ? "none" : snapKind) t=\(Self.epoch())")
        if live, player.rate == 0 { player.play() }
        startLink()
    }

    /// Queue `plan` behind the clip on screen (the alert flash settling back to idle: the flash plays whole).
    private func queue(_ plan: AvatarPlan) {
        guard ThreePOAssets.pack != nil else { return }
        unpark(resume: true)
        let cur = player.currentItem
        for it in player.items() where it !== cur { player.remove(it) }
        insert(plan, after: cur)
        ThreePOAssets.log?("3po avatar plan=\(plan.clips.map(\.name).joined(separator: ",")) then=\(plan.loop.rawValue)")
        if live, player.rate == 0 { player.play() }
    }

    /// The plan's clips after `first` (nil: from the top), then passes of the state it settles in.
    private func insert(_ plan: AvatarPlan, after first: AVPlayerItem?) {
        var after = first
        loopState = plan.loop
        for c in plan.clips {
            guard let it = item(c) else { continue }
            player.insert(it, after: after); after = it
        }
        for _ in 0..<2 { if let it = item(.loop(plan.loop)) { player.insert(it, after: after); after = it } }
    }

    // ── the crossfade clock (runs only while a frozen frame is up) ──
    private func startLink() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }
    private func stopLink() { link?.invalidate(); link = nil }

    @objc private func step(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        if case .armed = fade.phase, let it = player.currentItem, it !== cutFrom, it.status == .readyToPlay,
           let o = Self.output(it), o.hasNewPixelBuffer(forItemTime: it.currentTime()) || it.currentTime().seconds > 0.001 {
            if let w = fade.ready(now: now) { ThreePOAssets.log?("3po avatar crossfade ready_ms=\(Int(w * 1000)) t=\(Self.epoch())") }
        }
        let wasArmed: Bool = { if case .armed = fade.phase { return true }; return false }()
        let active = fade.tick(now: now)
        if wasArmed, case .fading = fade.phase { ThreePOAssets.log?("3po avatar crossfade ready=deadline t=\(Self.epoch())") }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        snapLayer.opacity = Float(fade.opacity(now))
        if !active { snapLayer.contents = nil; snap = nil }
        CATransaction.commit()
        if !active { stopLink(); settled() }
    }

    // ── the parked idle (AvatarLoopPark) ──
    private var idleURL: URL? { ThreePOAssets.url(.loop(.idle), px: px, rate: rate) }
    private var idleFPS: Double { ThreePOAssets.pack(rate)?.fps ?? 60 }

    /// Something changed (or may now be steady): check again after the settle, if nothing else changes first.
    private func settled() {
        settleGen += 1
        let g = settleGen
        loadIdleFrames()
        DispatchQueue.main.asyncAfter(deadline: .now() + AvatarIdleCache.settle + 0.02) { [weak self] in
            MainActor.assumeIsolated { if let self, self.settleGen == g { self.tryPark() } }
        }
    }

    private func tryPark() {
        guard !parked, window != nil, let u = idleURL, let frames = Self.idleFrames[u],
              let it = player.currentItem as? ThreePOClipItem, it.clip == current, it.status == .readyToPlay, player.rate != 0,
              AvatarLoopPark.shouldPark(current: current, loopState: loopState, overlayUp: link != nil, live: live,
                                        framesReady: true, settledFor: AvatarIdleCache.settle) else { return }
        let now = CACurrentMediaTime()
        let t = it.currentTime().seconds
        guard t.isFinite else { return }
        parkBegin = now - t
        let a = CAKeyframeAnimation(keyPath: "contents")
        a.values = frames
        a.calculationMode = .discrete
        a.duration = Double(frames.count) / idleFPS
        a.repeatCount = .infinity
        a.beginTime = parkLayer.convertTime(parkBegin, from: nil)
        a.isRemovedOnCompletion = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        parkLayer.contents = parkedFrame(now)
        parkLayer.add(a, forKey: "idle")
        parkLayer.isHidden = false
        playerLayer.isHidden = true                               // never both: the alpha edges would double up
        CATransaction.commit()
        player.pause()
        parked = true
        ThreePOAssets.log?("3po loops parked frames=\(frames.count) t=\(Self.epoch())")
    }

    private func parkedFrame(_ now: Double) -> CGImage? {
        guard let u = idleURL, let f = Self.idleFrames[u], !f.isEmpty else { return nil }
        return f[AvatarLoopPark.frame(local: now - parkBegin, frames: f.count, fps: idleFPS)]
    }

    /// Back to the player. `resume`: the idle item picks up at the parked loop's phase (same frame, no jump).
    private func unpark(resume: Bool) {
        guard parked else { return }
        parked = false
        let now = CACurrentMediaTime()
        if resume, let it = player.currentItem {
            let t = (now - parkBegin).truncatingRemainder(dividingBy: max(0.001, it.duration.seconds.isFinite ? it.duration.seconds : 2.5))
            it.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.isHidden = false
        parkLayer.removeAllAnimations()
        parkLayer.contents = nil
        parkLayer.isHidden = true
        CATransaction.commit()
        if live, resume { player.play() }
        ThreePOAssets.log?("3po loops unparked t=\(Self.epoch())")
    }

    /// Decodes the idle clip once per launch and size (off the main thread): every frame, BGRA with its alpha, the
    /// same CoreImage path as the cut's frozen frame. A short or failed decode never parks.
    private func loadIdleFrames() {
        guard let u = idleURL, Self.idleFrames[u] == nil, !Self.decoding.contains(u) else { return }
        Self.decoding.insert(u)
        let want = ThreePOAssets.pack(rate)?.frames["idle"]
        Task.detached(priority: .utility) {
            let frames = Self.decode(u)
            await MainActor.run {
                Self.decoding.remove(u)
                if AvatarLoopPark.complete(decoded: frames.count, manifest: want) {
                    Self.idleFrames[u] = frames
                    ThreePOAssets.log?("3po loops idle decoded frames=\(frames.count)")
                } else {
                    ThreePOAssets.log?("3po loops idle decode short frames=\(frames.count) want=\(want ?? 0): stays on the player")
                }
            }
        }
    }

    nonisolated private static func decode(_ u: URL) -> [CGImage] {
        let asset = AVURLAsset(url: u)
        guard let track = asset.tracks(withMediaType: .video).first, let r = try? AVAssetReader(asset: asset) else { return [] }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: outputAttrs)
        out.alwaysCopiesSampleData = false
        guard r.canAdd(out) else { return [] }
        r.add(out)
        guard r.startReading() else { return [] }
        let ctx = CIContext(options: [.cacheIntermediates: false])
        var frames: [CGImage] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let im = CIImage(cvPixelBuffer: pb)
            if let cg = ctx.createCGImage(im, from: im.extent) { frames.append(cg) }
        }
        return r.status == .completed ? frames : []
    }
}

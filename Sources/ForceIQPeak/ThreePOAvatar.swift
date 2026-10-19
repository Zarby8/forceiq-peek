import AVFoundation
import AppKit
import PeakCore
import SwiftUI

// ───────────────────────────── 3PO avatar: BOB Motion ForceIQ-Peak-3PO-v1 (Resources/threepo) ─────────────────────────────
/// Assets: the bundled pack (Resources/threepo: MANIFEST.json as shipped, hevc_alpha 64 px, the neutral still), or
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
    static func url(_ c: AvatarClip, px: Int) -> URL? {
        guard let root, let pack else { return nil }
        return root.appendingPathComponent(pack.path(c, px: px))
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
final class ThreePOPlayerView: NSView {
    private let px: Int
    private let playerLayer = AVPlayerLayer()
    private let snapLayer = CALayer()                              // the frozen frame a cut crossfades from
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
        snapLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { player.pause(); stopLink() } else if live { player.play() }
    }

    func update(signals s: AvatarSignals, live l: Bool) {
        if s != signals {
            signals = s
            if let plan = director.update(s, current: current) { route(plan) }
        }
        if l != live || (l && player.rate == 0) {
            live = l
            if l { player.play() } else { player.pause() }      // paused: the frame on screen stays (a still), no decode
        }
    }

    func tearDown() {
        itemObs = nil
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
        }
        if let plan = director.update(signals, current: c) { route(plan) }
    }

    /// Keep two passes of the settled loop queued behind whatever is playing (gapless looping).
    private func topUp() {
        guard player.currentItem != nil || player.items().isEmpty == false else { return }
        while player.items().count < 3, let it = item(.loop(loopState)) { player.insert(it, after: player.items().last) }
    }
    private func item(_ c: AvatarClip) -> ThreePOClipItem? {
        guard let u = ThreePOAssets.url(c, px: px) else { return nil }
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

    /// The frame on screen now, from the current item's video output.
    private func frameOnScreen() -> CGImage? {
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
        if !active { stopLink() }
    }
}

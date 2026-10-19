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

/// A queued clip that knows what it is (looper replicas are plain AVPlayerItems).
final class ThreePOClipItem: AVPlayerItem {
    var clip: AvatarClip = .loop(.idle)
    var last = false
}

/// One AVQueuePlayer on a transparent AVPlayerLayer. Each state loops with its own AVPlayerLooper. A state change
/// disables the current looper (its pass finishes, so switches land on a loop boundary) and queues the pack's 20-frame
/// transitions after it; when the last transition comes on screen the target state's looper starts behind it
/// (`.loopingItemsFollowExistingItems` with only that item queued: gapless). Paused while not live; torn down when
/// the chat unmounts (Peak collapsed).
final class ThreePOPlayerView: NSView {
    private let px: Int
    private let playerLayer = AVPlayerLayer()
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var looperState: AvatarState = .idle
    private var retired: [(AVPlayerLooper, AvatarState)] = []      // disabled loopers whose last pass may still be on screen
    private var pendingLoop: AvatarState?                          // starts when the plan's last clip is on screen
    private var director = ThreePOAvatarDirector()
    private var signals = AvatarSignals()
    private(set) var current: AvatarClip = .loop(.idle)
    private var itemObs: NSKeyValueObservation?
    private var live = false

    init(px: Int) {
        self.px = px
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = ThreePOAssets.pack?.format == .h264Black ? NSColor.black.cgColor : NSColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(playerLayer)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        playerLayer.player = player
        if let u = ThreePOAssets.url(.loop(.idle), px: px) {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: u))
        }
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
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { player.pause() } else if live { player.play() }
    }

    func update(signals s: AvatarSignals, live l: Bool) {
        if s != signals {
            signals = s
            if let plan = director.update(s, current: current) { apply(plan) }
        }
        if l != live || (l && player.rate == 0) {
            live = l
            if l { player.play() } else { player.pause() }      // paused: the frame on screen stays (a still), no decode
        }
    }

    func tearDown() {
        itemObs = nil
        player.pause()
        looper?.disableLooping(); looper = nil
        for (l, _) in retired { l.disableLooping() }
        retired = []
        player.removeAllItems()
        playerLayer.player = nil
    }

    private func clip(of item: AVPlayerItem?) -> AvatarClip? {
        guard let item else { return nil }
        if let c = item as? ThreePOClipItem { return c.clip }
        if let l = looper, l.loopingPlayerItems.contains(where: { $0 === item }) { return .loop(looperState) }
        for (l, s) in retired where l.loopingPlayerItems.contains(where: { $0 === item }) { return .loop(s) }
        return .loop(looperState)
    }

    private func itemChanged(_ item: AVPlayerItem?) {
        if let ci = item as? ThreePOClipItem, ci.last, let s = pendingLoop { startLoop(s) }
        guard let c = clip(of: item) else { return }
        if c != current {
            current = c
            ThreePOAssets.log?("3po avatar clip=\(c.name)\(Self.kind(c)) t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
        }
        if let plan = director.update(signals, current: c) { apply(plan) }
    }

    /// The target state's looper, behind the item on screen (the only item left queued when this runs).
    private func startLoop(_ s: AvatarState) {
        pendingLoop = nil
        guard let u = ThreePOAssets.url(.loop(s), px: px) else { return }
        for it in player.items() where it !== player.currentItem { player.remove(it) }
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: u), timeRange: .invalid,
                                existingItemsOrdering: .loopingItemsFollowExistingItems)
        looperState = s
    }
    private static func kind(_ c: AvatarClip) -> String {
        switch c { case .loop: return " loop"; case .once: return " once"; case .transition: return "" }
    }

    /// Replace everything queued after the clip on screen with `plan` (the clip on screen always finishes).
    private func apply(_ plan: AvatarPlan) {
        guard ThreePOAssets.pack != nil else { return }
        let cur = player.currentItem
        if let l = looper { l.disableLooping(); retired.append((l, looperState)); if retired.count > 2 { retired.removeFirst() } }
        looper = nil
        pendingLoop = nil
        for it in player.items() where it !== cur { player.remove(it) }
        var after = cur
        var items: [ThreePOClipItem] = []
        for c in plan.clips {
            guard let u = ThreePOAssets.url(c, px: px) else { continue }
            let it = ThreePOClipItem(url: u); it.clip = c
            player.insert(it, after: after); after = it; items.append(it)
        }
        if let lastItem = items.last {
            lastItem.last = true
            pendingLoop = plan.loop
            if lastItem === player.currentItem { startLoop(plan.loop) }
        } else {
            startLoop(plan.loop)                      // same state again: its looper follows the pass on screen
        }
        ThreePOAssets.log?("3po avatar plan=\(plan.clips.map(\.name).joined(separator: ",")) then=\(plan.loop.rawValue)")
        if live, player.rate == 0 { player.play() }
    }
}

import AppKit
import Combine
import PeakCore
import RealityKit
import SwiftUI
import simd

// ───────────────────────────── 3PO live rig (BOB Motion ForceIQ-Peak-3PO-v1 rig/3po.usdz, RealityKit) ─────────────────────────────
/// On by default (it passed the M5 first-load check). FORCEIQ_PEAK_3PO_RIG=0 turns it off (the rendered loops play);
/// FORCEIQ_PEAK_3PO_RIG=<path to a .usdz> loads that file instead of the bundled one.
@MainActor enum ThreePORigFlag {
    static let raw = ProcessInfo.processInfo.environment["FORCEIQ_PEAK_3PO_RIG"] ?? ""
    static var enabled: Bool { raw != "0" }
    static var url: URL? {
        if !raw.isEmpty && raw != "0" && raw != "1" { return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath) }
        return ThreePOAssets.root?.appendingPathComponent("rig/3po.usdz")
    }
}

/// Loads the rig once per launch (off the first chat open), checks the node contract and applies the README's load
/// fix (talk_light exports fully lit: emission → 0). Any miss → `loaded = false` and the slot falls back to the loops.
@MainActor final class ThreePORigLoader: ObservableObject {
    static let shared = ThreePORigLoader()
    @Published private(set) var loaded: Bool?
    private(set) var template: Entity?
    private var started = false

    func loadIfNeeded() {
        guard !started, ThreePORigFlag.enabled else { return }
        started = true
        guard #available(macOS 15.0, *) else { fail("needs macOS 15"); return }
        let u = ThreePORigFlag.url, t0 = Date()
        Task { @MainActor in
            switch await ThreePORigCheck.load(u) {
            case .success(let (e, fixed)):
                template = e
                loaded = true
                ThreePOAssets.log?("3po rig loaded ms=\(Int(Date().timeIntervalSince(t0) * 1000)) nodes=ok talk_light=0 materials=\(fixed)")
            case .failure(let f): fail(f.reason)
            }
        }
    }
    private func fail(_ why: String) {
        loaded = false
        ThreePOAssets.log?("3po rig fallback reason=\(why)")
    }
}

@available(macOS 15.0, *)
/// Drives one clone of the rig from the pack's curves (ThreePOCurves) on the same director/plan the video uses.
@MainActor final class ThreePORigDriver {
    let root: Entity
    let head: Entity, eye: Entity, scan: Entity
    let headBase: simd_quatf, eyeScale: SIMD3<Float>, scanScale: SIMD3<Float>, scanBase: simd_quatf
    struct Slot { let entity: ModelEntity; let index: Int; let base: PhysicallyBasedMaterial }
    var eyeMats: [Slot] = [], scanMats: [Slot] = [], talkMats: [Slot] = [], goldMats: [Slot] = []
    var timeline: AvatarTimeline
    var director = ThreePOAvatarDirector()
    var meter = TalkMeter()
    var signals = AvatarSignals()

    init(template: Entity, now: Double) {
        root = template.clone(recursive: true)
        head = root.findEntity(named: "head")!; eye = root.findEntity(named: "eye_glow")!; scan = root.findEntity(named: "eye_scan")!
        headBase = head.orientation; eyeScale = eye.scale; scanScale = scan.scale; scanBase = scan.orientation
        timeline = AvatarTimeline(now: now)
        ThreePORigCheck.visitMaterials(root) { me, i, m in
            switch m.name ?? "" {
            case let n where n.hasSuffix("eye_glow"): eyeMats.append(Slot(entity: me, index: i, base: m))
            case let n where n.hasSuffix("eye_scan"): scanMats.append(Slot(entity: me, index: i, base: m))
            case let n where n.hasSuffix("talk_light"): talkMats.append(Slot(entity: me, index: i, base: m))
            case let n where n.hasSuffix("gold"):
                var g = m; g.emissiveColor = .init(color: NSColor(srgbRed: 1, green: 0.78, blue: 0.35, alpha: 1)); g.emissiveIntensity = 0
                goldMats.append(Slot(entity: me, index: i, base: g))
            default: break
            }
        }
    }

    private var drive: Double?

    func update(signals s: AvatarSignals, now: Double) {
        meter.observe(chars: s.replyChars, now: now)
        guard s != signals else { return }
        signals = s
        if let p = director.update(s, current: timeline.current) { route(p, now: now) }
    }

    /// Cut now (blend from the pose on screen) or, for the alert flash settling, queue behind it (AvatarSwitch).
    private func route(_ p: AvatarPlan, now: Double) {
        let plan = p.clips.map(\.name).joined(separator: ",")
        switch AvatarSwitch.mode(current: timeline.current, plan: p) {
        case .cut:
            let c = timeline.cut(p, now: now, talkDrive: drive)
            let t = String(format: "%.3f", Date().timeIntervalSince1970)
            ThreePOAssets.log?("3po avatar cut plan=\(plan) then=\(p.loop.rawValue) t=\(t) tier=rig")
            ThreePOAssets.log?("3po avatar clip=\(c.name) t=\(t) tier=rig")
            apply(timeline.params(now, talkDrive: drive))          // this frame already moves
        case .boundary:
            timeline.apply(p)
            ThreePOAssets.log?("3po avatar plan=\(plan) then=\(p.loop.rawValue) tier=rig")
        }
    }

    func tick(now: Double) {
        for c in timeline.advance(to: now) {
            ThreePOAssets.log?("3po avatar clip=\(c.name) t=\(String(format: "%.3f", Date().timeIntervalSince1970)) tier=rig")
            if let p = director.update(signals, current: c) { route(p, now: now) }
        }
        let lvl = meter.tick(now: now)
        drive = signals.streaming ? lvl : nil
        // Idle and nothing changing: the slow idle sway at 20 Hz is indistinguishable at 32 pt, and an untouched scene
        // costs RealityKit far less than one rewritten every frame. Any change (a cut, a stream) is back to every frame.
        level = lvl
        if throttle, isSteadyIdle, now - lastApply < 1.0 / AvatarIdleCache.hz(rate) { return }
        apply(timeline.params(now, talkDrive: drive))
        lastApply = now
    }
    /// Off while the idle loop is being captured (every frame is posed exactly at its phase).
    var throttle = true
    /// The screen's avatar rate (ThreePORigHost): the steady idle poses at 20 Hz on 60 Hz screens, every refresh at 120.
    var rate: AvatarFrameRate = .fps60
    private var lastApply = -1.0
    private var level = 0.0
    /// The idle loop with nothing in flight: no blend, nothing queued, no stream (what the parked playback can stand in for).
    var isSteadyIdle: Bool {
        timeline.current == .loop(.idle) && timeline.fadeFrom == nil && timeline.queue.isEmpty && !signals.streaming && level < 0.001
    }

    /// Writes only what changed: a material swap is the expensive part of a frame, and idle leaves the talk light,
    /// the gold and (between blinks) the eyes untouched.
    func apply(_ p: ThreePOParams) {
        let d = Float.pi / 180
        let qx = simd_quatf(angle: Float(p.headPitch) * d, axis: [1, 0, 0])
        let qy = simd_quatf(angle: Float(p.headTilt) * d, axis: [0, 1, 0])
        let qz = simd_quatf(angle: Float(p.headYaw) * d, axis: [0, 0, 1])
        let o = headBase * (qz * qy * qx)                              // == Blender XYZ euler
        if o != head.orientation { head.orientation = o }
        let lid = Float(ThreePOCurves.lid(p))
        if lid != lastLid {
            eye.scale = [eyeScale.x, eyeScale.y, eyeScale.z * lid]
            scan.scale = [scanScale.x, scanScale.y, scanScale.z * lid]
            lastLid = lid
        }
        let so = scanBase * simd_quatf(angle: Float(p.scanAngle) * d, axis: [0, 0, 1])
        if so != scan.orientation { scan.orientation = so }
        set(eyeMats, Float(ThreePOCurves.eyeIntensity(p)), &last.eye)
        set(scanMats, Float(ThreePOCurves.scanIntensity(p)), &last.scan)
        set(talkMats, Float(p.talkAmp), &last.talk)
        set(goldMats, Float(0.5 * p.goldFlash), &last.gold)
    }
    private var lastLid: Float = -1
    private var last = (eye: Float(-1), scan: Float(-1), talk: Float(-1), gold: Float(-1))

    private func set(_ slots: [Slot], _ v: Float, _ was: inout Float) {
        guard abs(v - was) > 0.002 else { return }                    // below a visible step (8-bit emission)
        was = v
        for s in slots {
            var m = s.base; m.emissiveIntensity = v
            s.entity.model?.materials[s.index] = m
        }
    }
}

@available(macOS 15.0, *)
struct ThreePORigView: NSViewRepresentable {
    @ObservedObject var rig: ThreePORigLoader
    let signals: AvatarSignals
    func makeNSView(context: Context) -> ThreePORigHost { ThreePORigHost(template: rig.template!) }
    func updateNSView(_ v: ThreePORigHost, context: Context) { v.update(signals: signals) }
    static func dismantleNSView(_ v: ThreePORigHost, coordinator: ()) { v.tearDown() }
}

/// The rig slot. RealityKit's ARView renders every display frame while it is in a window (an empty, untouched scene
/// costs the same), so a steady idle droid parks it: one idle pass of the live rig is captured (20 fps, 50 frames on a
/// 60 Hz screen; 120 fps, 300 frames on a ≥ 120 Hz one; once per launch, size and rate), the ARView leaves the window
/// and a layer animation plays those frames in phase with the rig's clock (Core Animation, ~no app CPU). Any change
/// re-attaches the ARView at once; the parked frame stays over it until the rig has drawn, so the switch shows no gap.
/// The ARView follows its screen's refresh itself (120 on ProMotion); a screen change re-chooses the rate and unparks.
@available(macOS 15.0, *)
final class ThreePORigHost: NSView {
    let ar: ThreePORigARView
    private let overlay = NSView()
    private(set) var parked = false
    private var settledSince = CACurrentMediaTime()
    private var snapping = false
    private var lastBin = 0
    private var reveal = 0                                         // rig frames to wait before dropping the parked frame
    private(set) var rate: AvatarFrameRate = .fps60
    private var screenObs: NSObjectProtocol?
    private var announced = false
    @MainActor static var cache: [Int: CGImage] = [:]
    @MainActor static var cacheKey = ""
    @MainActor static var capturePasses = 0

    init(template: Entity) {
        ar = ThreePORigARView(template: template)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(ar)
        overlay.wantsLayer = true
        overlay.layer?.contentsGravity = .resizeAspect
        overlay.layer?.actions = ["contents": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
        overlay.isHidden = true
        addSubview(overlay)
        ar.onTick = { [weak self] now in self?.ticked(now) }
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        ar.frame = bounds; overlay.frame = bounds
    }

    func update(signals s: AvatarSignals) {
        let now = CACurrentMediaTime()
        if s != ar.driver.signals { unpark(); settledSince = now }
        ar.driver.update(signals: s, now: now)
    }

    func tearDown() {
        if let o = screenObs { NotificationCenter.default.removeObserver(o); screenObs = nil }
        overlay.layer?.removeAllAnimations(); if parked { addSubview(ar) }; ar.tearDown()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }                        // parked: the host stays in the window, the ARView leaves
        if screenObs == nil {
            screenObs = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenChanged() }
            }
        }
        screenChanged()
    }

    /// The rig's rate follows the window's screen; a change unparks (the capture is per rate) and re-settles.
    private func screenChanged() {
        let r = ThreePOAssets.rate(for: window?.screen)
        let first = !announced
        announced = true
        guard r != rate else {
            if first { ThreePOAssets.log?("3po avatar fps=\(r.rawValue) screen_max=\(window?.screen?.maximumFramesPerSecond ?? 0) tier=rig") }
            return
        }
        rate = r
        ar.driver.rate = r
        unpark()
        settledSince = CACurrentMediaTime()
        ThreePOAssets.log?("3po avatar fps=\(r.rawValue) screen_max=\(window?.screen?.maximumFramesPerSecond ?? 0) tier=rig")
    }

    private var key: String { "\(Int(bounds.width))x\(Int(bounds.height))@\(window?.backingScaleFactor ?? 2)/\(rate.rawValue)" }

    private func ticked(_ now: Double) {
        let d = ar.driver
        if reveal > 0 { reveal -= 1; if reveal == 0 { overlay.isHidden = true; overlay.layer?.removeAllAnimations() } }
        guard d.isSteadyIdle else { settledSince = now; d.throttle = true; return }
        if Self.cacheKey != key { Self.cache = [:]; Self.cacheKey = key; Self.capturePasses = 0 }
        let bins = AvatarIdleCache.bins(rate), passes = AvatarIdleCache.maxPasses(rate)
        let complete = Self.cache.count == bins
        d.throttle = complete || Self.capturePasses > passes
        if !complete, Self.capturePasses <= passes, !snapping, bounds.width > 0 {
            let b = AvatarIdleCache.bin(local: d.timeline.local(now), rate: rate)
            if b < lastBin { Self.capturePasses += 1 }               // wrapped: one more idle pass
            lastBin = b
            if Self.cache[b] == nil {
                snapping = true
                let k = key
                ar.snapshot(saveToHDR: false) { [weak self] img in
                    MainActor.assumeIsolated {
                        self?.snapping = false
                        guard Self.cacheKey == k, let cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                        Self.cache[b] = cg
                        if Self.cache.count == bins { ThreePOAssets.log?("3po rig idle captured frames=\(bins) size=\(k)") }
                    }
                }
            }
        }
        if AvatarIdleCache.shouldPark(steadyIdle: true, complete: complete, settledFor: now - settledSince) { park(now) }
    }

    private func park(_ now: Double) {
        guard !parked, let l = overlay.layer else { return }
        let bins = AvatarIdleCache.bins(rate)
        let frames = (0..<bins).compactMap { Self.cache[$0] }
        guard frames.count == bins else { return }
        let a = CAKeyframeAnimation(keyPath: "contents")
        a.values = frames
        a.calculationMode = .discrete
        a.duration = ThreePOCurves.loopSeconds[.idle] ?? 2.5
        a.repeatCount = .infinity
        a.beginTime = l.convertTime(now, from: nil) - ar.driver.timeline.local(now)   // in phase with the rig's clock
        a.isRemovedOnCompletion = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.contents = frames[AvatarIdleCache.bin(local: ar.driver.timeline.local(now), rate: rate)]
        l.add(a, forKey: "idle")
        overlay.isHidden = false
        reveal = 0
        CATransaction.commit()
        parked = true
        DispatchQueue.main.async { [weak self] in                // after the parked frame is on screen
            guard let self, self.parked else { return }
            self.ar.removeFromSuperview()
            ThreePOAssets.log?("3po rig parked t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
        }
    }

    private func unpark() {
        guard parked else { return }
        parked = false
        if ar.superview == nil { addSubview(ar, positioned: .below, relativeTo: overlay); ar.frame = bounds }
        reveal = 2                                               // drop the parked frame once the rig has drawn
        ThreePOAssets.log?("3po rig unparked t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
    }
}

/// A non-AR RealityKit view on black: the pack's camera (85 mm, fov 14.25°, at (0, -0.30, 15) looking down -Z) and
/// key/fill lights. Mounted only while the chat is open and live, so a collapsed Peak renders nothing.
@available(macOS 15.0, *)
final class ThreePORigARView: ARView {
    let driver: ThreePORigDriver
    private var sub: Cancellable?

    init(template: Entity) {
        driver = ThreePORigDriver(template: template, now: CACurrentMediaTime())
        super.init(frame: .zero)                                // macOS ARView is always non-AR
        environment.background = .color(.black)
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(driver.root)
        let cam = PerspectiveCamera()
        cam.camera.fieldOfViewInDegrees = 14.25
        cam.position = [0, -0.30, 15]
        anchor.addChild(cam)
        for (pos, i) in [(SIMD3<Float>(-4.5, 3.5, 6.0), Float(2600)), (SIMD3<Float>(5.0, 0.5, 5.0), Float(1000)), (SIMD3<Float>(2.5, 4.0, -5.0), Float(2800))] {
            let l = DirectionalLight(); l.light.intensity = i
            l.look(at: .zero, from: pos, relativeTo: nil)
            anchor.addChild(l)
        }
        scene.addAnchor(anchor)
        driver.apply(ThreePOCurves.state(.idle, 0))
        sub = scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                self?.driver.tick(now: now); self?.onTick?(now)
            }
        }
    }
    @MainActor required dynamic init(frame: CGRect) { fatalError("unused") }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("unused") }

    var onTick: ((Double) -> Void)?
    func tearDown() { sub?.cancel(); sub = nil; scene.anchors.removeAll() }
}

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

    func update(signals s: AvatarSignals, now: Double) {
        meter.observe(chars: s.replyChars, now: now)
        guard s != signals else { return }
        signals = s
        if let p = director.update(s, current: timeline.current) {
            timeline.apply(p)
            ThreePOAssets.log?("3po avatar plan=\(p.clips.map(\.name).joined(separator: ",")) then=\(p.loop.rawValue) tier=rig")
        }
    }

    func tick(now: Double) {
        for c in timeline.advance(to: now) {
            ThreePOAssets.log?("3po avatar clip=\(c.name) t=\(String(format: "%.3f", Date().timeIntervalSince1970)) tier=rig")
            if let p = director.update(signals, current: c) { timeline.apply(p) }
        }
        let drive = meter.tick(now: now)
        apply(ThreePOCurves.params(timeline.current, timeline.local(now), talkDrive: signals.streaming ? drive : nil))
    }

    func apply(_ p: ThreePOParams) {
        let d = Float.pi / 180
        let qx = simd_quatf(angle: Float(p.headPitch) * d, axis: [1, 0, 0])
        let qy = simd_quatf(angle: Float(p.headTilt) * d, axis: [0, 1, 0])
        let qz = simd_quatf(angle: Float(p.headYaw) * d, axis: [0, 0, 1])
        head.orientation = headBase * (qz * qy * qx)                   // == Blender XYZ euler
        let lid = Float(ThreePOCurves.lid(p))
        eye.scale = [eyeScale.x, eyeScale.y, eyeScale.z * lid]
        scan.scale = [scanScale.x, scanScale.y, scanScale.z * lid]
        scan.orientation = scanBase * simd_quatf(angle: Float(p.scanAngle) * d, axis: [0, 0, 1])
        set(eyeMats, Float(ThreePOCurves.eyeIntensity(p)))
        set(scanMats, Float(ThreePOCurves.scanIntensity(p)))
        set(talkMats, Float(p.talkAmp))
        set(goldMats, Float(0.5 * p.goldFlash))
    }

    private func set(_ slots: [Slot], _ v: Float) {
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
    func makeNSView(context: Context) -> ThreePORigARView { ThreePORigARView(template: rig.template!) }
    func updateNSView(_ v: ThreePORigARView, context: Context) { v.driver.update(signals: signals, now: CACurrentMediaTime()) }
    static func dismantleNSView(_ v: ThreePORigARView, coordinator: ()) { v.tearDown() }
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
            MainActor.assumeIsolated { self?.driver.tick(now: CACurrentMediaTime()) }
        }
    }
    @MainActor required dynamic init(frame: CGRect) { fatalError("unused") }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("unused") }

    func tearDown() { sub?.cancel(); sub = nil; scene.anchors.removeAll() }
}

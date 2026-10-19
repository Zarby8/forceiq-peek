#if canImport(RealityKit)
import Foundation
import RealityKit

/// The 3PO rig's first-load check (rig/3po.usdz from BOB Motion ForceIQ-Peak-3PO-v1): it loads, every prim the drive
/// needs is there (rig/README.md node contract), and the load fix is applied (talk_light exports fully lit → 0).
/// Any failure is a reason, and the 3PO slot falls back to the rendered loops, then the static droid mark.
@available(macOS 15.0, *)
public enum ThreePORigCheck {
    public static let nodes = ["head", "eye_glow", "eye_scan", "talk_light", "talk_light_ring"]

    public enum Failure: Error, Equatable, Sendable {
        case missing, loadError(String), nodesMissing([String]), noTalkLight
        public var reason: String {
            switch self {
            case .missing: return "asset missing"
            case .loadError(let e): return "load error \(e)"
            case .nodesMissing(let n): return "nodes missing \(n.joined(separator: ","))"
            case .noTalkLight: return "talk_light material not found"
            }
        }
    }

    @MainActor public static func load(_ url: URL?) async -> Result<(Entity, Int), Failure> {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
        let e: Entity
        do { e = try await Entity(contentsOf: url) } catch { return .failure(.loadError(String(describing: type(of: error)))) }
        let missing = nodes.filter { e.findEntity(named: $0) == nil }
        guard missing.isEmpty else { return .failure(.nodesMissing(missing)) }
        let n = zeroTalkLight(e)
        guard n > 0 else { return .failure(.noTalkLight) }
        return .success((e, n))
    }

    @MainActor public static func visitMaterials(_ e: Entity, _ f: (ModelEntity, Int, PhysicallyBasedMaterial) -> Void) {
        if let me = e as? ModelEntity, let mc = me.model {
            for (i, m) in mc.materials.enumerated() { if let p = m as? PhysicallyBasedMaterial { f(me, i, p) } }
        }
        for c in e.children { visitMaterials(c, f) }
    }

    /// README: "When the file first loads, talk_light is fully lit. Set its intensity to 0 at load." Returns how many.
    @MainActor @discardableResult public static func zeroTalkLight(_ e: Entity) -> Int {
        var n = 0
        visitMaterials(e) { me, i, m in
            guard (m.name ?? "").hasSuffix("talk_light") else { return }
            var z = m; z.emissiveIntensity = 0
            me.model?.materials[i] = z; n += 1
        }
        return n
    }

    /// talk_light emission now (the test reads it back after the fix).
    @MainActor public static func talkLightIntensities(_ e: Entity) -> [Float] {
        var out: [Float] = []
        visitMaterials(e) { _, _, m in if (m.name ?? "").hasSuffix("talk_light") { out.append(m.emissiveIntensity) } }
        return out
    }
}
#endif

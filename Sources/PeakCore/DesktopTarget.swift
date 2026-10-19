import Foundation

// Desktop actions: which FLOW process a live press may target. Pure (no AppKit): the presser and the locator feed it what
// they read from the running app.
//
// Production FLOW is NEVER a live target: the bundle id `com.forceiq.flowai`, the app at /Applications/FLOW.app, any
// process running under that bundle id, and any pid listed in FORCEIQ_PEAK_PROTECTED_PIDS are refused before anything
// is brought forward or pressed. The live press only reaches an isolated, non-production FLOW (e.g. FLOW's own UI-test
// build with its own bundle id, DB and prefs), named by the smoke-only FORCEIQ_PEAK_FLOW_TARGET_PID and/or
// FORCEIQ_PEAK_FLOW_TARGET_BUNDLE (see peak/scripts/real_press_smoke.sh).

public enum ProductionGuard {
    public static let productionBundleIDs: Set<String> = ["com.forceiq.flowai"]
    public static let productionAppPaths: [String] = ["/Applications/FLOW.app"]
    public static let protectedPidsEnv = "FORCEIQ_PEAK_PROTECTED_PIDS"

    /// Exact production bundle id (case and surrounding whitespace ignored). A FLOW test build with its own bundle id
    /// (e.g. `com.forceiq.flowai.uat.<run>`) is not production.
    public static func isProductionBundle(_ bundleID: String?) -> Bool {
        guard let b = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !b.isEmpty else { return false }
        return productionBundleIDs.contains(b)
    }

    /// The production app bundle on disk (case-insensitive, like the default APFS volume), or anything inside it.
    public static func isProductionAppPath(_ path: String?) -> Bool {
        guard let p = path, !p.isEmpty else { return false }
        let norm = URL(fileURLWithPath: p).standardizedFileURL.path.lowercased()
        return productionAppPaths.contains { prod in
            let pp = prod.lowercased()
            return norm == pp || norm.hasPrefix(pp + "/")
        }
    }

    /// FORCEIQ_PEAK_PROTECTED_PIDS: comma / space separated pids that are never a target (the smoke passes the pid of
    /// every running production FLOW here as well).
    public static func protectedPids(env: [String: String]) -> Set<Int32> {
        let raw = env[protectedPidsEnv] ?? ""
        return Set(raw.split { $0 == "," || $0 == " " }.compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 })
    }

    /// nil = this process is not production FLOW. Otherwise why it is refused. A process whose bundle id can't be read
    /// is refused too (it can't be shown to be non-production).
    public static func reason(pid: Int32, bundleID: String?, bundlePath: String?, protectedPids: Set<Int32>) -> String? {
        if protectedPids.contains(pid) { return "pid \(pid) is protected (production FLOW)" }
        if isProductionBundle(bundleID) { return "production FLOW (bundle \(bundleID!.trimmingCharacters(in: .whitespacesAndNewlines)))" }
        if isProductionAppPath(bundlePath) { return "production FLOW (\(productionAppPaths[0]))" }
        guard let b = bundleID, !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "pid \(pid) has no readable bundle id" }
        return nil
    }
}

/// The smoke-only target: the isolated FLOW instance a live press may reach, by pid and/or bundle id.
public struct FlowSmokeTarget: Equatable, Sendable {
    public static let pidEnv = "FORCEIQ_PEAK_FLOW_TARGET_PID"
    public static let bundleEnv = "FORCEIQ_PEAK_FLOW_TARGET_BUNDLE"
    public var pid: Int32?
    public var bundleID: String?
    /// The pid env var was set but isn't a positive integer: such a target matches nothing.
    public var invalid: Bool
    public init(pid: Int32? = nil, bundleID: String? = nil, invalid: Bool = false) { self.pid = pid; self.bundleID = bundleID; self.invalid = invalid }

    /// nil when neither env var is set (no smoke target: the profile's FLOW, which the presser refuses if it is production).
    public static func from(env: [String: String]) -> FlowSmokeTarget? {
        let p = env[pidEnv]?.trimmingCharacters(in: .whitespaces) ?? ""
        let b = env[bundleEnv]?.trimmingCharacters(in: .whitespaces) ?? ""
        if p.isEmpty && b.isEmpty { return nil }
        var t = FlowSmokeTarget(bundleID: b.isEmpty ? nil : b)
        if !p.isEmpty { if let v = Int32(p), v > 0 { t.pid = v } else { t.invalid = true } }
        return t
    }

    /// nil = the target itself names nothing production. Checked before any running process is looked at.
    public func refusal(protectedPids: Set<Int32>) -> String? {
        if invalid { return "the smoke target pid is not a valid pid" }
        if let p = pid, protectedPids.contains(p) { return "the smoke target pid \(p) is protected (production FLOW)" }
        if ProductionGuard.isProductionBundle(bundleID) { return "the smoke target bundle is production FLOW (\(bundleID!))" }
        return nil
    }

    /// The running process is exactly this target (every field that was given must match).
    public func matches(pid: Int32, bundleID: String?) -> Bool {
        if invalid { return false }
        if let p = self.pid, p != pid { return false }
        if let b = self.bundleID, b != bundleID { return false }
        return self.pid != nil || self.bundleID != nil
    }
}

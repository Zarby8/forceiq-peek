import Foundation

// Desktop actions, LIVE: one action only — press FLOW's 'Code Window' menu item for the client's package, after an
// explicit Run tap on the client-named confirm card. Everything else stays locate-only (the Command meeting start is
// never pressed). Live needs all of: settings.json `desktopActions` = true in a scratch GOAT_PEAK_ROOT (never
// ~/ForceIQ/peak), FORCEIQ_PEAK_DESKTOP_LIVE=1, and no dry-run opt-in (see DesktopActionGate). `desktopActions` stays
// OFF by default with no UI toggle.
//
// This file is pure: it decides WHETHER a press is allowed. The single AXPress call site lives in
// ForceIQPeak/DesktopPresser.swift (DesktopDryRunTests pins it there, and only there).

/// What the presser found in the frontmost FLOW process, right before pressing. Matching is exact.
public struct PressCandidate: Equatable, Sendable {
    public var role: String                 // must be AXMenuItem
    public var title: String                // must be exactly "Code Window"
    public var enabled: Bool
    public var pid: Int32                   // the process that owns the menu item
    public var bundleID: String?            // must be FLOW's
    public var frontmostPid: Int32?         // must equal pid (frontmost FLOW process)
    public var matches: Int                 // how many 'Code Window' menu items exist (must be exactly 1)
    public var documentPath: String?        // FLOW's front window AXDocument, if it exposes one
    public var windowTitle: String?         // FLOW's front window title (never logged unless it is the package)
    public init(role: String, title: String, enabled: Bool, pid: Int32, bundleID: String?, frontmostPid: Int32?, matches: Int = 1,
                documentPath: String? = nil, windowTitle: String? = nil) {
        self.role = role; self.title = title; self.enabled = enabled; self.pid = pid; self.bundleID = bundleID
        self.frontmostPid = frontmostPid; self.matches = matches; self.documentPath = documentPath; self.windowTitle = windowTitle
    }
}

public enum PressGuard {
    public static let role = "AXMenuItem"
    public static let title = "Code Window"

    /// nil = the press is allowed. Otherwise why nothing was pressed (client named; FLOW's own window text never echoed).
    public static func refusal(_ c: PressCandidate, flowBundle: String, packagePath: String, client: String) -> String? {
        if c.matches == 0 { return "no '\(title)' menu item in FLOW; nothing pressed" }
        if c.matches > 1 { return "\(c.matches) '\(title)' menu items in FLOW (ambiguous); nothing pressed" }
        if c.role != role { return "the target is a \(c.role), not an \(role); nothing pressed" }
        if c.title != title { return "the menu item's title isn't exactly '\(title)'; nothing pressed" }
        if c.bundleID != flowBundle { return "the menu item isn't in FLOW; nothing pressed" }
        if c.frontmostPid != c.pid { return "FLOW is not the frontmost app; nothing pressed" }
        if !c.enabled { return "'\(title)' is disabled in FLOW; nothing pressed" }
        if !frontWindowIsPackage(c, packagePath: packagePath) {
            return "FLOW's front window isn't \(client)'s package (\(URL(fileURLWithPath: packagePath).lastPathComponent)); nothing pressed"
        }
        return nil
    }

    /// FLOW's front window shows exactly this package: its AXDocument is the package, or (when FLOW exposes no document)
    /// its title contains the package's full name.
    public static func frontWindowIsPackage(_ c: PressCandidate, packagePath: String) -> Bool {
        let want = URL(fileURLWithPath: packagePath).standardizedFileURL.path
        if let d = c.documentPath, !d.isEmpty {
            let p = (d.hasPrefix("file://") ? URL(string: d)?.standardizedFileURL.path : URL(fileURLWithPath: d).standardizedFileURL.path) ?? ""
            return p.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == want.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let base = URL(fileURLWithPath: packagePath).deletingPathExtension().lastPathComponent
        guard base.count >= 8, let t = c.windowTitle else { return false }
        return t == base || t.contains(base)
    }
}

public struct PressResult: Equatable, Sendable {
    public var pressed: Bool
    public var stopped: Bool                // STOP seen right before the press: nothing pressed
    public var detail: String
    public var ms: Int
    public init(pressed: Bool, stopped: Bool = false, detail: String, ms: Int) {
        self.pressed = pressed; self.stopped = stopped; self.detail = detail; self.ms = ms
    }
}

/// The live action. Exactly one requirement: press FLOW's 'Code Window' menu item (AXPress on that exact element) when
/// PressGuard allows it, checking STOP immediately before the press.
public protocol DesktopPresser: Sendable {
    func pressCodeWindow(_ step: DryRunStep, packagePath: String, stop: StopSwitch) async -> PressResult
}

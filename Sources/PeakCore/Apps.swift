import Foundation

/// The app switcher. Its apps and bundle IDs come ONLY from the coach profile (overlay peak.apps), never from code.
/// An app that isn't installed on this Mac is shown with a gold outline and a gold 'Not installed' line (full opacity, never dimmed) and can't be launched.
public struct SwitcherApp: Equatable, Sendable, Identifiable, Codable {
    public let name: String
    public let bundleID: String
    public var id: String { bundleID }
    public init(name: String, bundleID: String) { self.name = name; self.bundleID = bundleID }
    enum CodingKeys: String, CodingKey { case name, bundleID = "bundle_id" }
}

/// Finds an installed app by bundle ID (the app side uses NSWorkspace; tests use a fake).
public protocol AppLocating: Sendable {
    func isInstalled(_ bundleID: String) -> Bool
}

public struct SwitcherEntry: Equatable, Sendable, Identifiable {
    public let app: SwitcherApp
    public let installed: Bool
    public var id: String { app.bundleID }
}

public enum AppSwitcher {
    public static func entries(_ profile: CoachProfile, _ locator: AppLocating) -> [SwitcherEntry] {
        profile.apps.map { SwitcherEntry(app: $0, installed: locator.isInstalled($0.bundleID)) }
    }
    /// Only a profile-listed, installed bundle ID may be activated or launched.
    public static func canActivate(_ bundleID: String, _ profile: CoachProfile, _ locator: AppLocating) -> Bool {
        profile.allowedBundleIDs.contains(bundleID) && locator.isInstalled(bundleID)
    }
}

/// How a switcher tap brings the target app to the coach, decided purely from the app's state.
/// The bug this fixes: activating a running app whose window lives in a full-screen Space does
/// not move the user to that Space, so the tap reads as dead. Measured live on this machine
/// (Nov 17, 2026) against a sacrificial full-screen app: NSRunningApplication.activate() — bare,
/// and with .activateAllWindows (the earlier fix) — returned true and changed nothing;
/// NSWorkspace.openApplication errored instead of switching; a Launch Services reopen
/// (`open -b`, the Dock-click path) switched Spaces every time, as did an AppleScript activate.
/// The plan therefore sends every running app — windowed, hidden, or full-screen — down the
/// reopen path (a reopen also unhides, so `hidden` no longer changes the plan). Not running →
/// launch (which already worked).
public enum SwitchActivationPlan: Equatable, Sendable {
    /// Not running: launch it (NSWorkspace, activates on open).
    case launch
    /// Running: reopen it through Launch Services (`open -b` via LocalCommand), the measured
    /// mechanism that carries the user into a full-screen app's Space.
    case reopen
}

public enum SwitchActivation {
    public static func plan(running: Bool, hidden: Bool) -> SwitchActivationPlan {
        running ? .reopen : .launch
    }
}

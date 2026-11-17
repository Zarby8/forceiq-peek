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
/// The bug this fixes: a bare `activate()` on a running app whose windows live in a full-screen
/// Space raises nothing the user can see — the app becomes active but the user stays on the
/// current Space, so the tap reads as dead. The path that carries the user across Spaces is
/// activation with `.activateAllWindows` (raise every window, switching to their Space), after
/// unhiding a hidden app. Not running → launch (which already worked).
public enum SwitchActivationPlan: Equatable, Sendable {
    /// Not running: launch it (NSWorkspace, activates on open).
    case launch
    /// Running: unhide first when hidden, then activate raising ALL windows so a full-screen
    /// window's Space comes with it.
    case activate(allWindows: Bool, unhideFirst: Bool)
}

public enum SwitchActivation {
    public static func plan(running: Bool, hidden: Bool) -> SwitchActivationPlan {
        guard running else { return .launch }
        return .activate(allWindows: true, unhideFirst: hidden)
    }
}

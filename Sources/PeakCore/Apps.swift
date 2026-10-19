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

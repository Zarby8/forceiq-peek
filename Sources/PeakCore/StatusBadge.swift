import Foundation

/// The always-on menu-bar badge: "PEAK" in brand green on black, visible whether or not the notch sheet is up (it is also
/// the one sign Peak is running, since collapsed Peak is just the notch). Presenting mode turns it gold so a shared screen
/// shows it. A black capsule keeps the colors legible on any menu bar, light or dark.
public struct StatusBadgeSpec: Equatable, Sendable {
    public let text: String
    /// The short form drawn in the notch's status wing (it is only ~96 pt wide).
    public let wingText: String
    public let textHex: UInt32
    public let backgroundHex: UInt32
    public let accessibilityLabel: String
}

public enum StatusBadge {
    public static func spec(presenting: Bool) -> StatusBadgeSpec {
        presenting
            ? StatusBadgeSpec(text: "PEAK · PRESENTING", wingText: "PRESENTING", textHex: Brand.goldHex, backgroundHex: Brand.blackHex,
                              accessibilityLabel: "ForceIQ Peak, presenting, client details hidden")
            : StatusBadgeSpec(text: "PEAK", wingText: "PEAK", textHex: Brand.greenHex, backgroundHex: Brand.blackHex, accessibilityLabel: "ForceIQ Peak")
    }
}

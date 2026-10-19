import Foundation

/// Presenting mode: one toggle (menu bar) for a shared screen. While it is on, nothing client-private is drawn anywhere:
/// alerts say only that something happened, the sheet shows one plain notice instead of cards / the next-session card /
/// 3PO / the ask field / drops, the Studio pill drops its client countdown, dictated words aren't echoed under the notch,
/// and "what's my day" says it is hidden. This is the one place the "every item names its client" rule is suspended, because
/// naming the client is exactly what a shared screen must not do. Persisted, so a relaunch never un-hides a shared screen.
public enum Presenting {
    public static let notice = "Presenting. Client details are hidden."
    public static let briefLine = "Presenting. Your day is hidden."
    public static let menuTitle = "Presenting (hide client details)"
    public static let statusTitle = "Peak · presenting"

    /// The alert as it may appear on a shared screen: no client, only the plain line.
    public static func redact(_ a: PeakAlert) -> PeakAlert {
        PeakAlert(id: a.id, kind: a.kind, client: "", line: a.plainLine, holdSeconds: a.holdSeconds, plainLine: a.plainLine)
    }
}

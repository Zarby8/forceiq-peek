import Foundation

/// What the status wing says right now. One short word, plus small shape-only dots; never more than the wing can hold.
///   idle            PEEK in green
///   a session soon  "<first name> 42m" in green (inside 60 min), "<first name> now" from its start until 15 min after
///   a gap needs you a gold dot (an unpaid / missing invoice or export; the sheet has the detail)
///   5090 held       a red dot (a meeting is live or within 2 h, or the meeting status is unknown: GPU jobs are held)
///   presenting      PRESENTING in gold, no dots, no names (Presenting.swift)
/// The first name is the client's: the full name is on the sheet, the peek and the accessibility label.
public struct WingSpec: Equatable, Sendable {
    public let text: String
    public let textHex: UInt32
    /// Shape colors drawn left to right before the text: red = 5090 held, gold = a gap needs you.
    public let dots: [UInt32]
    public let accessibilityLabel: String
}

public enum WingStatus {
    public static let soonSeconds: TimeInterval = 3600
    public static let nowGraceSeconds: TimeInterval = 15 * 60
    public static let nameLimit = 6

    public static func firstName(_ client: String, limit: Int = nameLimit) -> String {
        let first = client.split(separator: " ").first.map(String.init) ?? client
        return first.count > limit ? String(first.prefix(limit - 1)) + "…" : first
    }

    /// "42m", "now", or nil when the session is outside the window (more than an hour out, or long started).
    public static func countdown(to start: Date, now: Date) -> String? {
        let s = start.timeIntervalSince(now)
        if s >= soonSeconds { return nil }
        if s >= 60 { return "\(Int(s / 60))m" }
        if s > -nowGraceSeconds { return "now" }
        return nil
    }

    public static func spec(presenting: Bool, session: NextSession?, gaps: Int, light: GPULightState, now: Date) -> WingSpec {
        if presenting {
            let b = StatusBadge.spec(presenting: true)
            return WingSpec(text: b.wingText, textHex: b.textHex, dots: [], accessibilityLabel: b.accessibilityLabel)
        }
        var dots: [UInt32] = []
        if light.holdsGPU { dots.append(Brand.redHex) }
        if gaps > 0 { dots.append(Brand.goldHex) }
        var text = StatusBadge.spec(presenting: false).wingText
        var label = ["ForceIQ Peek"]
        if let s = session, let c = countdown(to: s.scheduledAt, now: now) {
            text = "\(firstName(s.client)) \(c)"
            label.append(c == "now" ? "\(s.client) now" : "\(s.client) in \(c.dropLast()) minutes")
        }
        if light.holdsGPU { label.append("5090 held") }
        if gaps > 0 { label.append(gaps == 1 ? "1 gap needs you" : "\(gaps) gaps need you") }
        return WingSpec(text: text, textHex: Brand.greenHex, dots: dots, accessibilityLabel: label.joined(separator: ", "))
    }
}

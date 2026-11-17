import Foundation

// Recording DND: while Command records a meeting, Peek goes fully dark — no panel, no peek, no
// expansion — and held Claude approvals pass through to the terminal (the app wires recordingDND into
// the presenting check). The signal is the engine's next-meeting `recording` field (a RecordingOperation
// row in an active status for the live booking's room), NOT the gpu_window.live heuristic, which only
// says a meeting is live, not that it is being recorded.
//
// The tracker is pure and clock-injected so every edge is unit-tested:
//   true  → engage (remember when)
//   false → release, and clear any stuck latch
//   nil   → no change (unknown never engages and never releases)
//   stuck bound → while engaged, if now passes the meeting's scheduled end + 45 min (or, with no
//   known end, engagement + 3 h), force-release and LATCH ignore: further `true` reads are ignored
//   until a `false` read arrives. A stuck-on flag can never hide Peek forever.

public struct RecordingDNDTracker: Equatable, Sendable {
    public private(set) var engaged = false
    public private(set) var engagedAt: Date? = nil
    /// Latched after a stuck-bound force-release: `true` reads are ignored until a `false` read clears it.
    public private(set) var latchedIgnore = false

    /// Grace past the meeting's scheduled end before an engaged DND counts as stuck.
    public static let endGrace: TimeInterval = 45 * 60
    /// With no known meeting end, the hard bound on one engagement.
    public static let noEndBound: TimeInterval = 3 * 3600

    public init() {}

    /// One feed read. Returns the engaged state after the read.
    @discardableResult
    public mutating func update(recording: Bool?, meetingEnd: Date?, now: Date) -> Bool {
        if latchedIgnore {
            if recording == false {
                latchedIgnore = false
                engaged = false
                engagedAt = nil
            }
            return engaged
        }
        switch recording {
        case true:
            if !engaged { engaged = true; engagedAt = now }
        case false:
            engaged = false
            engagedAt = nil
        case nil:
            break   // unknown: no change
        }
        if engaged, let start = engagedAt {
            let bound = meetingEnd.map { $0.addingTimeInterval(Self.endGrace) }
                ?? start.addingTimeInterval(Self.noEndBound)
            if now > bound {
                engaged = false
                engagedAt = nil
                latchedIgnore = true
            }
        }
        return engaged
    }
}

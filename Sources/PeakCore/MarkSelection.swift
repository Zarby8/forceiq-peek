import Foundation

/// Which mark Peek wears in the notch: the eyes (the default), the BOB Motion video loops, or the GHOST
/// character pack. One resolution rule everywhere (PeakMark.resolve): FORCEIQ_PEAK_MARK wins when it names
/// a mark; else the settings.json `mark` key (PeakPrefs.mark); else the eyes. An unrecognized value selects
/// nothing and falls through, so a typo in either place can never blank the pill. The settings key is
/// per-Mac and unset by default, so a fresh install — or another coach's Mac — keeps the eyes until
/// someone opts in on that machine.
public enum PeakMark: String, CaseIterable, Sendable {
    case eyes, bob, ghost

    /// Video marks render through the video renderer over a bundled pack; the eyes are pure vector.
    public var isVideo: Bool { self != .eyes }

    /// The one resolution: env first, then the persisted setting, then the eyes.
    public static func resolve(env: [String: String], setting: PeakMark?) -> PeakMark {
        if let raw = env["FORCEIQ_PEAK_MARK"], let m = PeakMark(rawValue: raw) { return m }
        return setting ?? .eyes
    }
}

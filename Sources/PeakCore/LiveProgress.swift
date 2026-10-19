import Foundation

/// What GOAT is working on right now, for the thin gold line under the notch. Only what GOAT's live doc reports:
/// fixes it is running and shift downloads (Live Activity rule: nothing else, so no upscale or meeting-pack progress).
/// The line is determinate only when every running download reports its own percent and no fix is running; otherwise it is
/// a dashed line that says "working" without claiming how far. A percent is never estimated or made up here.
public struct LiveProgress: Equatable, Sendable {
    public let fixes: Int
    public let downloads: Int
    /// 0...1, or nil when the engine gave no percent for every running download (or a fix is running too).
    public let fraction: Double?
    public static let idle = LiveProgress(fixes: 0, downloads: 0, fraction: nil)

    public init(fixes: Int, downloads: Int, fraction: Double?) { self.fixes = fixes; self.downloads = downloads; self.fraction = fraction }

    public init(_ s: EngineSnapshot) {
        let f = max(0, s.fixesRunning), d = max(0, s.downloadsRunning)
        var frac: Double?
        if f == 0, d > 0, s.downloadPercents.count == d {
            frac = min(1, max(0, s.downloadPercents.reduce(0, +) / Double(d) / 100))
        }
        self.init(fixes: f, downloads: d, fraction: frac)
    }

    public var working: Bool { fixes > 0 || downloads > 0 }

    /// The line's spoken label (VoiceOver): plain words, no client.
    public var summary: String {
        guard working else { return "" }
        if let p = fraction, downloads > 0 { return "Downloading, \(Int((p * 100).rounded())) percent" }
        if fixes > 0 && downloads > 0 { return "Fixing and downloading" }
        return fixes > 0 ? "Fixing" : "Downloading"
    }
}

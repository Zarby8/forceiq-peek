import Foundation

// What is running right now, for the sheet (read-only). GOAT's local feed (GET /api/peak/running, this Mac only) hands over Command's
// own pipeline status, the same model the iOS app and its Live Activities show, trimmed to two lanes: an upscale going through the
// pipeline and a meeting pack going transcript, summary, PDF, publication. Peek only shows it; it never derives or changes anything.

public enum RunningLane: String, Sendable { case upscale, postMeeting = "post_meeting" }

public struct RunningRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let lane: RunningLane
    /// running, queued, waiting or attention (a published pack that still needs a look).
    public let stage: String
    public let client: String
    public let what: String
    public let step: String
    /// 0...100, or nil when Command reports no fraction.
    public let percent: Double?
    public let detail: String
    public let stepsDone: Int
    public let stepsTotal: Int
    public var needsLook: Bool { stage == "attention" }
    public init(id: String, lane: RunningLane, stage: String, client: String = "", what: String = "", step: String = "", percent: Double? = nil,
                detail: String = "", stepsDone: Int = 0, stepsTotal: Int = 0) {
        self.id = id; self.lane = lane; self.stage = stage; self.client = client; self.what = what; self.step = step
        self.percent = percent; self.detail = detail; self.stepsDone = stepsDone; self.stepsTotal = stepsTotal
    }
}

public struct RunningFeed: Equatable, Sendable {
    /// Command answered. False = couldn't ask: never the same thing as "nothing is running".
    public var known: Bool
    public var rows: [RunningRow]
    public init(known: Bool = true, rows: [RunningRow] = []) { self.known = known; self.rows = rows }
}

extension EngineParse {
    /// GET /api/peak/running. nil when the engine said it couldn't read it.
    public static func running(_ d: Data) -> RunningFeed? {
        guard let o = obj(d), (o["ok"] as? Bool) == true else { return nil }
        guard (o["known"] as? Bool) == true else { return RunningFeed(known: false) }
        let rows: [RunningRow] = ((o["items"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let lane = RunningLane(rawValue: str(r["lane"])), !str(r["id"]).isEmpty else { return nil }
            let p = r["percent"] as? NSNumber
            let percent = p.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue }
            return RunningRow(id: str(r["id"]), lane: lane, stage: str(r["stage"]), client: str(r["client"]), what: str(r["what"]), step: str(r["step"]),
                              percent: percent.map { min(100, max(0, $0)) }, detail: str(r["detail"]),
                              stepsDone: (r["steps_done"] as? Int) ?? 0, stepsTotal: (r["steps_total"] as? Int) ?? 0)
        }
        return RunningFeed(known: true, rows: rows)
    }
}

/// The words on a row. Names stay on the sheet (it is hidden while presenting) and never reach a log.
public enum RunningText {
    public static func title(_ r: RunningRow) -> String {
        let fallback = r.lane == .upscale ? "Upscale" : "Meeting pack"
        let parts = [r.client, r.what].filter { !$0.isEmpty }
        return parts.isEmpty ? fallback : parts.joined(separator: " · ")
    }

    public static func percent(_ p: Double) -> String {
        let r = (p * 10).rounded() / 10                                           // one decimal first, so 9.96 reads "10%"
        return r >= 10 || r == 0 ? "\(Int(r.rounded()))%" : String(format: "%.1f%%", r)
    }

    /// "RIFE interpolation" for a running step; "Queued · step", "Waiting · step" or "Needs a look · step" otherwise.
    public static func status(_ r: RunningRow) -> String {
        let lead: String
        switch r.stage { case "queued": lead = "Queued"; case "waiting": lead = "Waiting"; case "attention": lead = "Needs a look"; default: lead = "" }
        return [lead, r.step].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Command's own detail (frames, or its sentence) and how many steps are done.
    public static func footnote(_ r: RunningRow) -> String? {
        let steps = r.stepsTotal > 0 ? "\(r.stepsDone) of \(r.stepsTotal) steps" : ""
        let s = [r.detail, steps].filter { !$0.isEmpty }.joined(separator: " · ")
        return s.isEmpty ? nil : s
    }
}

@MainActor public final class RunningModel: ObservableObject {
    nonisolated public static let path = "/api/peak/running"
    nonisolated public static let expandedInterval: TimeInterval = 15       // the sheet is open: near-live
    nonisolated public static let busyInterval: TimeInterval = 60           // collapsed, but something is running
    nonisolated public static let idleInterval: TimeInterval = 120          // collapsed and nothing running
    nonisolated public static let retryInterval: TimeInterval = 60          // a failed read
    nonisolated public static let missingInterval: TimeInterval = 600       // an engine without the feed
    /// Two unknown reads in a row before the sheet says it can't tell (one is a blip).
    nonisolated public static let unavailableAfter = 2

    @Published public private(set) var feed: RunningFeed?
    @Published public private(set) var unavailable = false
    public let enabled: Bool
    public private(set) var fetches = 0
    public private(set) var dead = false
    private var unknownStreak = 0
    private var nextDue: Date? = nil
    private var inFlight = false
    let transport: ThreePOTransport
    weak var logger: PeakLogging?

    public init(transport: ThreePOTransport, enabled: Bool, logger: PeakLogging? = nil) {
        self.transport = transport; self.enabled = enabled; self.logger = logger
    }

    /// The sheet just opened: read now instead of waiting out the quiet interval.
    public func nudge() { nextDue = nil }

    /// Demo and tests only.
    public func setFeed(_ f: RunningFeed?) { feed = f; unavailable = false }

    /// One GET when enabled and due. Returns whether a request went out.
    @discardableResult
    public func tick(now: Date = Date(), expanded: Bool) async -> Bool {
        guard enabled, !dead, !inFlight else { return false }
        if let d = nextDue, now < d { return false }
        inFlight = true; defer { inFlight = false }
        fetches += 1
        let (code, data) = await transport.get(Self.path)
        if code == 200, let f = EngineParse.running(data) {
            if f.known { feed = f; unknownStreak = 0; unavailable = false }
            else { unknownStreak += 1; feed = nil; unavailable = unknownStreak >= Self.unavailableAfter }
            nextDue = now.addingTimeInterval(expanded ? Self.expandedInterval : (f.rows.isEmpty ? Self.idleInterval : Self.busyInterval))
        } else {
            if code == 403 { dead = true }
            if code == 404 || code == 403 { feed = nil; unavailable = false }       // an engine without the feed: nothing to show
            else { unknownStreak += 1; unavailable = unknownStreak >= Self.unavailableAfter }
            nextDue = now.addingTimeInterval(code == 404 || code == 403 ? Self.missingInterval : Self.retryInterval)
        }
        logger?.log(logLine(code))
        return true
    }

    /// Counts only: no client names.
    func logLine(_ code: Int) -> String {
        guard let f = feed else { return "running fetch code=\(code) feed=none unavailable=\(unavailable ? "yes" : "no")" }
        return "running fetch code=\(code) upscale=\(f.rows.filter { $0.lane == .upscale }.count) packs=\(f.rows.filter { $0.lane == .postMeeting }.count)"
    }
}

/// How the expanded Peek home list (RUNNING cards + waiting cards) sizes against the leftover sheet.
/// Pinned chrome (title row, 5090 light, switcher) does not scroll; this is the viewport the list must scroll inside.
/// Minimum row heights are conservative: if this overflows, the real sheet does too.
public enum PeekHomeOverflow {
    /// Leftover height on the 360 pt expanded sheet in pill mode (the larger leftover). Notch mode is tighter.
    public static let viewportHeight: Double = 214
    public static let stackSpacing: Double = 8
    public static let runningHeaderHeight: Double = 17
    public static let runningRowGap: Double = 6
    /// RunningRowView: padding plus title / status — a short row is still at least this tall.
    public static let runningRowMinHeight: Double = 56
    public static let waitingRowMinHeight: Double = 46
    public static let pillMinHeight: Double = 28

    public struct Measure: Equatable, Sendable {
        public var contentHeight: Double
        public var viewportHeight: Double
        public var overflows: Bool { contentHeight > viewportHeight }
        public var scrollingEnabled: Bool { overflows }
        public var scrollbarAvailable: Bool { overflows }
    }

    public static func measure(runningRows: Int, waitingRows: Int, showsPill: Bool) -> Measure {
        var h = 0.0
        var blocks = 0
        if showsPill { h += pillMinHeight; blocks += 1 }
        if runningRows > 0 {
            h += runningHeaderHeight + Double(runningRows) * runningRowMinHeight + Double(max(0, runningRows - 1)) * runningRowGap
            blocks += 1
        }
        if waitingRows > 0 {
            h += Double(waitingRows) * waitingRowMinHeight + Double(max(0, waitingRows - 1)) * stackSpacing
            blocks += 1
        }
        if blocks > 1 { h += Double(blocks - 1) * stackSpacing }
        return Measure(contentHeight: h, viewportHeight: viewportHeight)
    }

    /// The clipped layout on the expanded running page: gold next-session pill, three RUNNING cards, and a waiting list
    /// sitting below the fold. Sample names only. The third row has no client because Command sent none (title falls back
    /// to "Upscale"); the first two name the client.
    public static func clippedRunningPage() -> (feed: RunningFeed, waitingRows: Int, showsPill: Bool) {
        let feed = RunningFeed(known: true, rows: [
            RunningRow(id: "u1", lane: .upscale, stage: "running", client: "Sample Skater", what: "Demo City Rockets · 10.30",
                       step: "RIFE interpolation", percent: 50, detail: "26063 / 52078 frames", stepsDone: 11, stepsTotal: 25),
            RunningRow(id: "u2", lane: .upscale, stage: "running", client: "Sample Skater",
                       step: "Interpolating (RIFE 2x, 60fps)"),
            RunningRow(id: "u3", lane: .upscale, stage: "queued", step: "Waiting for the GPU"),
        ])
        return (feed, 2, true)
    }
}

import Foundation

/// Stage 5 — ONE "needs you" mechanism plus the glanceable extras (launcher tile readouts, tonight's
/// games, the money rollup), all fed by the same engine snapshot. Everything here is pure: parse,
/// decide, format. Silent when all is fine; plain words when it isn't; nothing invented — a signal
/// the engine couldn't source truthfully simply never appears.

/// A 5090 pipeline job that failed, with the step that broke (from the engine's live-activities doc).
public struct PipelineFailure: Equatable, Sendable {
    public let id: String
    public let title: String
    public let step: String
    public init(id: String, title: String, step: String) { self.id = id; self.title = title; self.step = step }
    public var line: String { step.isEmpty ? "\(title) failed" : "\(title) failed at \(step)" }
}

/// Command's past-due rollup (engine-computed from Command's invoices; Command stays the system of record).
public struct MoneyRollup: Equatable, Sendable {
    public let count: Int
    public let totalCents: Int
    public init(count: Int, totalCents: Int) { self.count = count; self.totalCents = totalCents }
    /// "3 unpaid invoices past due · $3,000" — nil when nothing is past due (the line stays invisible).
    public var line: String? {
        guard count > 0 else { return nil }
        let dollars = (totalCents + 50) / 100
        return "\(count) unpaid invoice\(count == 1 ? "" : "s") past due · $\(Self.grouped(dollars))"
    }
    static func grouped(_ n: Int) -> String {
        var s = String(n), out = ""
        while s.count > 3 { out = "," + String(s.suffix(3)) + out; s = String(s.dropLast(3)) }
        return s + out
    }
}

/// Tonight's games for this coach's clients (engine-computed from Ghost's schedule).
public struct TonightGames: Equatable, Sendable {
    public let clients: Int
    public let nextStart: Date?
    public init(clients: Int, nextStart: Date?) { self.clients = clients; self.nextStart = nextStart }
}

public enum TonightLine {
    /// "3 clients tonight · puck drop 7:30 PM" / "1 client tonight" — nil when nobody plays.
    public static func text(_ t: TonightGames, now: Date) -> String? {
        guard t.clients > 0 else { return nil }
        var s = "\(t.clients) client\(t.clients == 1 ? "" : "s") tonight"
        if let start = t.nextStart, start >= now {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h:mm a"
            s += " · puck drop \(f.string(from: start))"
        }
        return s
    }
}

/// Live readouts for the launcher tiles. Only truthfully-sourced signals exist here: GOAT's 5090 queue
/// depth (engine) and Command's sessions remaining today (the snapshot's own `today` list). The Ghost
/// release gate and FLOW TestFlight have no truthful engine path, so those tiles stay plain.
public struct TileReadouts: Equatable, Sendable {
    public var queueDepth: Int? = nil
    public var sessionsRemaining: Int? = nil
    public init() {}
    public static func build(from s: EngineSnapshot, now: Date) -> TileReadouts {
        var r = TileReadouts()
        r.queueDepth = s.queueDepth
        r.sessionsRemaining = (s.today ?? []).filter {
            $0.scheduledAt.addingTimeInterval(Double($0.durationMinutes) * 60) > now
        }.count
        return r
    }
    public func text(forBundleID bundleID: String) -> String? {
        switch bundleID {
        case "com.forceiq.commandbox": return queueDepth.map { "\($0) in queue" }
        case "com.forceiq.command": return sessionsRemaining.map { "\($0) left today" }
        default: return nil
        }
    }
}

/// One thing that needs the coach, in plain words. `id` is the dedupe key for the latch.
public struct NeedsYouFault: Equatable, Sendable {
    public let id: String
    public let line: String
    public init(id: String, line: String) { self.id = id; self.line = line }
}

public enum NeedsYou {
    public static let diskLowThresholdGB = 10.0
    public static func faults(from s: EngineSnapshot, now: Date) -> [NeedsYouFault] {
        var out: [NeedsYouFault] = []
        for f in s.pipelineFailures {
            out.append(NeedsYouFault(id: "pipeline:\(f.id)", line: f.line))
        }
        if s.gpuWindow?.calendarIssue != nil {
            out.append(NeedsYouFault(id: "calendar", line: "Calendar access is off — Peek can't see today's gaps."))
        }
        if let gb = s.diskFreeGB, gb < diskLowThresholdGB {
            out.append(NeedsYouFault(id: "disk", line: "Disk nearly full — \(Int(gb)) GB free on this Mac."))
        }
        if s.meetingError != nil {
            out.append(NeedsYouFault(id: "feed", line: "The meeting feed is down — lines may be stale."))
        }
        return out
    }
}

/// The dedupe latch (same pattern as the watcher's stuck flag): a fault is "fresh" only the first
/// cycle it appears; it stays current while it persists and clears when it resolves, so a persistent
/// fault never re-nags every feed cycle.
public struct FaultLatch: Sendable {
    private var active: Set<String> = []
    public init() {}
    public mutating func update(_ faults: [NeedsYouFault]) -> (current: [NeedsYouFault], fresh: [NeedsYouFault]) {
        let fresh = faults.filter { !active.contains($0.id) }
        active = Set(faults.map(\.id))
        return (faults, fresh)
    }
}

/// Stage 6 presence: the OTHER coach's currently-live session (engine peakmeeting, from the same
/// bookings read; presence only — his own meetings surface stays owner-filtered as always).
public struct OtherCoachLive: Equatable, Sendable {
    public let coach: String
    public let client: String
    public init(coach: String, client: String) { self.coach = coach; self.client = client }
    /// "Shane is meeting with {client}" — first name only, as the coach is known in the building.
    public var line: String { "\(coach.split(separator: " ").first.map(String.init) ?? coach) is meeting with \(client)" }
    public static func parse(_ o: [String: Any]) -> OtherCoachLive? {
        guard let p = o["other_coach_live"] as? [String: Any],
              let coach = p["coach"] as? String, !coach.isEmpty,
              let client = p["client"] as? String, !client.isEmpty else { return nil }
        return OtherCoachLive(coach: coach, client: client)
    }
}

/// Parsers for the Stage-5 feed fields (sibling of GPUWindow.parse / RecordingSignal.parse).
public enum Stage5Parse {
    public static func queueDepth(_ o: [String: Any]) -> Int? { o["queue_depth"] as? Int }
    public static func money(_ o: [String: Any]) -> MoneyRollup? {
        guard let m = o["money"] as? [String: Any], let c = m["count"] as? Int, let t = m["total_cents"] as? Int
        else { return nil }
        return MoneyRollup(count: c, totalCents: t)
    }
    public static func tonight(_ o: [String: Any]) -> TonightGames? {
        guard let t = o["tonight"] as? [String: Any], let c = t["clients"] as? Int else { return nil }
        return TonightGames(clients: c, nextStart: (t["next_start"] as? String).flatMap { EngineParse.date($0) })
    }
    public static func diskFreeGB(_ o: [String: Any]) -> Double? {
        if let d = o["disk_free_gb"] as? Double { return d }
        if let i = o["disk_free_gb"] as? Int { return Double(i) }
        return nil
    }
    /// Failed pipeline activities from the /api/live doc: state "failed", step = the pipeline step id.
    public static func pipelineFailures(liveData d: Data) -> [PipelineFailure] {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let items = o["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { it in
            guard (it["state"] as? String) == "failed", let key = it["key"] as? String else { return nil }
            return PipelineFailure(id: key, title: (it["title"] as? String) ?? key, step: (it["step"] as? String) ?? "")
        }
    }
}

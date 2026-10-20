import Foundation

// "Pack ready" and "FLOW package ready" (read-only). GOAT's local feed (GET /api/peak/ready, this Mac only) lists the meeting
// packs GHOST has published and the FLOW packages built for this coach's roster; Peek reads it about every 10 minutes and the
// AlertPolicy peeks only what is NEW since Peek first saw that source. Behind settings.json `readyAlerts` (on by default).

public struct ReadyItem: Equatable, Sendable {
    public let id: String
    public let client: String
    public init(id: String, client: String) { self.id = id; self.client = client }
}

public struct ReadyFeed: Equatable, Sendable {
    /// At least one roster client's pack list was read this time. False = the packs half is unknown: nothing is baselined.
    public var packsKnown: Bool
    /// The clients whose pack list was read successfully. A client is baselined only after a successful read, so a read that
    /// failed once and recovered later never turns that client's existing packs into news.
    public var packsChecked: [String]
    public var packs: [ReadyItem]
    /// FLOW's project folder was listed. False (folder missing or unreadable) = unknown, never "nothing there".
    public var flowKnown: Bool
    public var flow: [ReadyItem]
    public init(packsKnown: Bool = false, packsChecked: [String] = [], packs: [ReadyItem] = [], flowKnown: Bool = false, flow: [ReadyItem] = []) {
        self.packsKnown = packsKnown; self.packsChecked = packsChecked; self.packs = packs; self.flowKnown = flowKnown; self.flow = flow
    }
}

extension EngineParse {
    /// GET /api/peak/ready. nil when the engine said it couldn't read it (ok false) or the body isn't the feed.
    public static func ready(_ d: Data) -> ReadyFeed? {
        guard let o = obj(d), (o["ok"] as? Bool) == true else { return nil }
        func items(_ v: Any?) -> [ReadyItem] {
            ((v as? [[String: Any]]) ?? []).compactMap { r in
                let id = str(r["id"]), client = str(r["client"])
                return id.isEmpty || client.isEmpty ? nil : ReadyItem(id: id, client: client)
            }
        }
        let p = (o["packs"] as? [String: Any]) ?? [:], f = (o["flow"] as? [String: Any]) ?? [:]
        return ReadyFeed(packsKnown: (p["known"] as? Bool) == true, packsChecked: strs(p["checked"]), packs: items(p["items"]),
                         flowKnown: (f["known"] as? Bool) == true, flow: items(f["items"]))
    }
}

@MainActor public final class ReadyModel {
    nonisolated public static let path = "/api/peak/ready"
    nonisolated public static let pollInterval: TimeInterval = 600          // every 10 min at most
    nonisolated public static let retryInterval: TimeInterval = 1800        // after a failed read or an engine without the feed
    public let enabled: Bool
    /// The last good read, or nil (flag off, an engine without the feed, or never read). The policy never baselines on nil.
    public private(set) var feed: ReadyFeed?
    public private(set) var fetches = 0
    public private(set) var dead = false
    private var nextDue: Date? = nil
    private var inFlight = false
    let transport: ThreePOTransport
    weak var logger: PeakLogging?

    public init(transport: ThreePOTransport, enabled: Bool, logger: PeakLogging? = nil) {
        self.transport = transport; self.enabled = enabled; self.logger = logger
    }

    /// One GET when enabled and due. Returns whether a request went out. Flag off: never.
    @discardableResult
    public func tick(now: Date = Date()) async -> Bool {
        guard enabled, !dead, !inFlight else { return false }
        if let d = nextDue, now < d { return false }
        inFlight = true; defer { inFlight = false }
        fetches += 1
        let (code, data) = await transport.get(Self.path)
        if code == 200, let f = EngineParse.ready(data) {
            feed = f; nextDue = now.addingTimeInterval(Self.pollInterval)
        } else {
            if code == 403 { dead = true }
            if code == 404 || code == 403 { feed = nil }                    // an engine without the feed: not available, never baselined
            nextDue = now.addingTimeInterval(Self.retryInterval)
        }
        logger?.log(logLine(code))
        return true
    }

    /// Counts only: no client names or ids.
    func logLine(_ code: Int) -> String {
        guard let f = feed else { return "ready fetch code=\(code) feed=none" }
        return "ready fetch code=\(code) packs=\(f.packs.count) checked=\(f.packsChecked.count) packs_known=\(f.packsKnown ? "yes" : "no") flow=\(f.flow.count) flow_known=\(f.flowKnown ? "yes" : "no")"
    }
}

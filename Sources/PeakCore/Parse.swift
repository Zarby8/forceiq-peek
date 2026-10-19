import Foundation

/// Tolerant decoders for the local GOAT engine's JSON (phone.py on 127.0.0.1:8765). Missing fields never crash.
public enum EngineParse {
    static func obj(_ d: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
    static func str(_ v: Any?) -> String { (v as? String) ?? (v.map { "\($0)" } ?? "") }
    static func strs(_ v: Any?) -> [String] { (v as? [Any])?.compactMap { $0 as? String } ?? [] }

    public static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// GET /api/peak/next-meeting
    public static func meeting(_ d: Data) -> (MeetingRow?, String?) {
        guard let o = obj(d) else { return (nil, "Bad answer from GOAT.") }
        let err = o["error"] as? String
        guard let m = o["meeting"] as? [String: Any], let at = date(str(m["scheduled_at"])) else { return (nil, err) }
        let client = str(m["client"]).trimmingCharacters(in: .whitespaces)
        guard !client.isEmpty else { return (nil, err) }
        // Peek never joins: a booking's join / meeting URL is ignored; only Command's room page (validated) opens.
        let open = CommandLink.safe((m["open_url"] as? String) ?? "")
        return (MeetingRow(client: client, scheduledAt: at, durationMinutes: (m["duration_minutes"] as? Int) ?? 60,
                           joinURL: nil, openURL: open), err)
    }

    /// GET /api/live → fixes + running counts (downloads only count toward the "working" Ghost state) + the percent each
    /// running download reports (a row without a numeric percent contributes none, so nothing is ever estimated).
    public static func live(_ d: Data) -> (fixes: [FixRow], fixing: Int, downloading: Int, percents: [Double], done: [DownloadDone]) {
        guard let o = obj(d) else { return ([], 0, 0, [], []) }
        let fixes: [FixRow] = ((o["fixes"] as? [[String: Any]]) ?? []).map { f in
            let who = str(f["who"]).isEmpty ? (strs(f["clients"]).first ?? "") : str(f["who"])
            return FixRow(title: str(f["title"]).isEmpty ? str(f["what"]) : str(f["title"]), client: who,
                          state: str(f["state"]), message: str(f["message"]))
        }
        let c = (o["counts"] as? [String: Any]) ?? [:]
        let fixing = (c["fixing"] as? Int) ?? fixes.filter { $0.state == "running" }.count
        let rows = (o["downloads"] as? [[String: Any]]) ?? []
        let downloading = (c["downloading"] as? Int)
            ?? rows.filter { ["running", "downloading", "queued"].contains(str($0["state"])) }.count
        let percents: [Double] = rows.filter { str($0["state"]) == "running" }.compactMap { r in
            guard let n = r["percent"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue
        }
        let done: [DownloadDone] = rows.compactMap { r in
            guard str(r["state"]) == "done" else { return nil }
            let parts = str(r["what"]).components(separatedBy: " · ")
            guard parts.count >= 2, parts[0] == "Shift download" else { return nil }        // shift downloads only, never a provider grab
            let client = parts[1].trimmingCharacters(in: .whitespaces)
            guard !client.isEmpty else { return nil }
            let id = str(r["file"]).isEmpty ? str(r["what"]) + str(r["at"]) : str(r["file"])
            return DownloadDone(id: id, client: client)
        }
        return (fixes, fixing, downloading, percents, done)
    }

    /// GET /api/approvals
    public static func approvals(_ d: Data) -> [ApprovalRow] {
        guard let o = obj(d) else { return [] }
        return ((o["items"] as? [[String: Any]]) ?? []).compactMap { i in
            let id = str(i["id"])
            guard id.range(of: #"^[0-9a-f]{12}$"#, options: .regularExpression) != nil else { return nil }
            let client = str(i["client"]).isEmpty ? (strs(i["clients"]).first ?? "") : str(i["client"])
            let ap = i["approve"] as? [String: Any]
            return ApprovalRow(id: id, kind: str(i["kind"]), kindLabel: str(i["kind_label"]), title: str(i["title"]), why: str(i["why"]),
                               client: client, gate: str(i["gate"]), touches: strs(i["touches"]), outputs: strs(i["outputs"]),
                               actLabel: str(ap?["label"]).isEmpty ? str(ap?["act"]) : str(ap?["label"]),
                               test: (i["test"] as? Bool) ?? false)
        }
    }

    /// GET /api/family-delivery-alerts (enabled=false when GOAT_FAMILY_DELIVERY_ALERTS is off: no Command call was made)
    public static func family(_ d: Data) -> (enabled: Bool, rows: [FamilyRow]) {
        guard let o = obj(d) else { return (false, []) }
        let on = (o["enabled"] as? Bool) ?? false
        let rows: [FamilyRow] = ((o["alerts"] as? [[String: Any]]) ?? []).map {
            FamilyRow(jobID: str($0["job_id"]).isEmpty ? str($0["id"]) : str($0["job_id"]), client: str($0["client"]).isEmpty ? str($0["client_name"]) : str($0["client"]),
                      reason: str($0["reason"]), link: ($0["family_link"] as? String) ?? ($0["link"] as? String),
                      meetingDate: str($0["meeting_date"]))
        }
        return (on, on ? rows : [])
    }
}

/// Command deep links Peek may open: forceiq-command://app/open#path=<path> under /sessions, /clients or /schedule only,
/// and NEVER with workflow= (Command's meeting-with-client workflow auto-joins LiveKit). Anything else → the schedule.
public enum CommandLink {
    public static let schedule = "forceiq-command://app/open#path=%2Fschedule"
    static let prefix = "forceiq-command://app/open#path="
    static let allowed = ["/sessions", "/clients", "/schedule"]
    static let idRx = #"^[A-Za-z0-9_-]{1,80}$"#

    public static func build(path: String) -> String {
        guard isAllowed(path) else { return schedule }
        var cs = CharacterSet.alphanumerics; cs.insert(charactersIn: "-_.~")
        return prefix + (path.addingPercentEncoding(withAllowedCharacters: cs) ?? "%2Fschedule")
    }

    /// The room page for a coaching session (opens the room; Chris taps Join / Record himself in Command).
    public static func room(sessionID: String?, clientID: String? = nil) -> String {
        if let s = sessionID, s.range(of: idRx, options: .regularExpression) != nil { return build(path: "/sessions/live?session=\(s)") }
        if let c = clientID, c.range(of: idRx, options: .regularExpression) != nil { return build(path: "/clients/\(c)") }
        return schedule
    }

    static func isAllowed(_ path: String) -> Bool {
        guard !path.lowercased().contains("workflow=") else { return false }
        return allowed.contains { path == $0 || path.hasPrefix($0 + "/") || path.hasPrefix($0 + "?") }
    }

    /// Re-validates a link from the engine: wrong scheme / host / path or any workflow= → the schedule.
    public static func safe(_ link: String) -> String {
        guard link.hasPrefix(prefix), !link.lowercased().contains("workflow"),
              let path = String(link.dropFirst(prefix.count)).removingPercentEncoding, !path.lowercased().contains("workflow=") else { return schedule }
        return isAllowed(path) ? build(path: path) : schedule
    }
}

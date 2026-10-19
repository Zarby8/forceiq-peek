import Foundation

// "Start a meeting with <client>" → Command's own Start sheet (Command #685), behind a flag that is OFF by default.
//
//   forceiq-command://meeting/start?client_id=<uuid>&source=goat
//
// The link opens Command's staff route /sessions/start: a confirm sheet with the client's name and Start / Cancel.
// Nothing starts on load; nothing starts until the coach taps Start in Command. A bad or missing id lands on
// /sessions/start?error=invalid. Peak builds the link ONLY from a validated, trimmed, lower-case UUID taken from this
// coach's Command directory (GET /clients/directory through the engine's existing Command session); a heard or typed
// name never goes into the link.
//
// Matching: only an exact, unique display_name match (case- and whitespace-normalised) goes straight to the link card.
// Partial, fuzzy, or several matches give a pick card naming the candidates; no match gives a plain "not found" card.
// The directory is cached in memory only, briefly (DirectoryCache); nothing is written to disk. Logs carry counts and
// outcomes only (match=unique|ambiguous|none), never a client name or id.
//
// Flag: settings.json `commandMeetingLink` (no UI) or env FORCEIQ_PEAK_COMMAND_MEETING_LINK=1. Off = the meeting start
// is exactly what it was (#26/#28: the room page / schedule card; locate-only under the desktop dry-run / live gates).
// Desktop dry-run / live modes keep the meeting start locate-only even with the flag on. Mac only (iOS is out of scope).

public enum CommandMeetingLinkGate {
    public static let env = "FORCEIQ_PEAK_COMMAND_MEETING_LINK"
    /// On only when the env opt-in is exactly "1" or settings.json `commandMeetingLink` is true. Default off.
    public static func enabled(env e: [String: String], setting: Bool = false) -> Bool { e[env] == "1" || setting }
}

public enum CommandMeetingLink {
    public static let prefix = "forceiq-command://meeting/start?client_id="
    public static let source = "goat"
    static let uuidRx = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
    static let linkRx = #"^forceiq-command://meeting/start\?client_id=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}&source=goat$"#

    /// A trimmed, lower-case UUID, or nil (names, ids of another shape, anything with extra characters).
    public static func clientID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s.range(of: uuidRx, options: .regularExpression) != nil ? s : nil
    }

    /// The deep link for a validated client id; nil when the id isn't a UUID (nothing is built from a name).
    public static func url(clientID raw: String?) -> String? {
        guard let id = clientID(raw) else { return nil }
        return prefix + id + "&source=" + source
    }

    /// Re-validates a link right before Run opens it: exactly the shape above, nothing else.
    public static func isValid(_ link: String?) -> Bool {
        guard let l = link else { return false }
        return l.range(of: linkRx, options: .regularExpression) != nil
    }
}

/// One row of this coach's Command directory (active clients only, already scoped by Command).
public struct DirectoryClient: Equatable, Sendable {
    public var id: String               // validated lower-case UUID
    public var displayName: String
    public init?(id: String, displayName: String) {
        guard let cid = CommandMeetingLink.clientID(id) else { return nil }
        let n = displayName.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        self.id = cid; self.displayName = n
    }
}

/// GET /api/peak/client-directory, parsed. Every id is re-validated here; a non-UUID row is dropped and counted.
public enum DirectoryResult: Equatable, Sendable {
    case clients([DirectoryClient], dropped: Int)
    case signedOut(CommandSignInNotice)          // the existing "Command sign-in expired, tap to sign in" state (401 / dead session)
    case forbidden(String)                       // 403: a client-role session can't list clients (dead state, no retry)
    case failed(String)

    public var outcome: String {
        switch self {
        case .clients: return "ok"; case .signedOut: return "expired"; case .forbidden: return "forbidden"; case .failed: return "failed"
        }
    }

    public static func parse(_ code: Int, _ d: Data) -> DirectoryResult {
        if code == 401 { return .signedOut(CommandSignInNotice()) }
        if code == 403 { return .failed("GOAT refused the client directory on this Mac.") }      // the engine's local-only gate
        guard let o = EngineParse.obj(d) else { return .failed("Couldn't read the client directory.") }
        if let n = EngineParse.commandSignIn(d) { return .signedOut(n) }
        if EngineParse.str(o["auth"]) == "expired" { return .signedOut(CommandSignInNotice()) }
        if EngineParse.str(o["auth"]) == "forbidden" {
            let m = EngineParse.str(o["error"]).trimmingCharacters(in: .whitespaces)
            return .forbidden(m.isEmpty ? "This Command sign-in can't list clients (coach or admin only)." : String(m.prefix(200)))
        }
        guard code == 200, (o["ok"] as? Bool) == true, let rows = o["clients"] as? [Any] else {
            let m = EngineParse.str(o["error"]).trimmingCharacters(in: .whitespaces)
            return .failed(m.isEmpty ? "Command didn't answer for the client directory." : String(m.prefix(200)))
        }
        var out: [DirectoryClient] = [], dropped = 0
        for r in rows {
            guard let x = r as? [String: Any], let id = x["id"] as? String, let n = x["display_name"] as? String,
                  let c = DirectoryClient(id: id, displayName: n) else { dropped += 1; continue }
            out.append(c)
        }
        return .clients(out, dropped: dropped)
    }
}

public enum DirectoryMatch: Equatable, Sendable {
    case unique(DirectoryClient)                 // exact (normalised) and the only one: straight to the link card
    case ambiguous([DirectoryClient])            // several exact, partial or fuzzy: the coach picks (never auto)
    case none

    public var outcome: String {
        switch self { case .unique: return "unique"; case .ambiguous: return "ambiguous"; case .none: return "none" }
    }
}

public enum DirectoryMatcher {
    /// Case- and whitespace-normalised (curly apostrophes folded): the only form an exact match compares.
    public static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "’", with: "'").lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    public static func match(_ heard: String, in clients: [DirectoryClient]) -> DirectoryMatch {
        let want = normalize(heard)
        guard !want.isEmpty, !clients.isEmpty else { return .none }
        let exact = clients.filter { normalize($0.displayName) == want }
        if exact.count == 1 { return .unique(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }
        // Not exact: partial / fuzzy candidates from the same resolver the roster uses, then near misses. Always a pick.
        let names = uniqueNames(clients)
        var hits = ClientCommands.resolve(heard, roster: names)
        if hits.isEmpty { hits = ClientCommands.near(heard, roster: names) }
        let picked = hits.flatMap { h in clients.filter { $0.displayName == h } }
        return picked.isEmpty ? .none : .ambiguous(Array(picked.prefix(6)))
    }

    static func uniqueNames(_ c: [DirectoryClient]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for x in c where !seen.contains(x.displayName) { seen.insert(x.displayName); out.append(x.displayName) }
        return out
    }

    /// Button labels for a pick card: the display_name; a name shared by several clients gets " (2)", " (3)" … so each
    /// button maps to one client. Ids never appear in a label.
    public static func labels(_ c: [DirectoryClient]) -> [(String, DirectoryClient)] {
        var count: [String: Int] = [:], total: [String: Int] = [:]
        for x in c { total[x.displayName, default: 0] += 1 }
        return c.map { x in
            count[x.displayName, default: 0] += 1
            let n = count[x.displayName]!
            return (total[x.displayName]! > 1 && n > 1 ? "\(x.displayName) (\(n))" : x.displayName, x)
        }
    }
}

/// The directory, in memory only, for a short while (default 120 s; a failure for 30 s so a dead or forbidden session
/// is not asked again on every command, and nothing ever loops). Never written to disk.
public final class DirectoryCache: @unchecked Sendable {
    public static let path = "/api/peak/client-directory"
    public let ttl: TimeInterval
    public let failureTTL: TimeInterval
    private var hit: (DirectoryResult, Date)?
    private let lock = NSLock()
    public init(ttl: TimeInterval = 120, failureTTL: TimeInterval = 30) { self.ttl = ttl; self.failureTTL = failureTTL }

    public func cached(now: Date = Date()) -> DirectoryResult? {
        lock.lock(); defer { lock.unlock() }
        guard let h = hit else { return nil }
        let life: TimeInterval
        if case .clients = h.0 { life = ttl } else { life = failureTTL }
        return now.timeIntervalSince(h.1) < life ? h.0 : nil
    }

    public func store(_ r: DirectoryResult, now: Date = Date()) { lock.lock(); hit = (r, now); lock.unlock() }
    public func clear() { lock.lock(); hit = nil; lock.unlock() }

    /// One GET through the engine when nothing fresh is cached. (fromCache tells the caller whether a request went out.)
    public func load(_ transport: ThreePOTransport, now: Date = Date()) async -> (DirectoryResult, fromCache: Bool) {
        if let r = cached(now: now) { return (r, true) }
        let (code, d) = await transport.get(Self.path)
        let r = DirectoryResult.parse(code, d)
        store(r, now: now)
        return (r, false)
    }
}

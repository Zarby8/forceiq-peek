import Foundation

/// The one-thing brief for today's session, derived locally from the next-session feed only
/// (GET /api/peak/next-session: the session + Ghost since-last-met lines). Peek invents nothing:
/// every line comes from the feed, and what the feed cannot say is said plainly instead.
///
/// What the feed cannot give: a per-metric Ghost regression (it carries only aggregates — games,
/// G/A/P, one Ghost-score average, the latest result) and no clip link. A true "biggest regression
/// + proving clip" needs a session-brief engine route; until then the brief leads with the sharpest
/// available signal and names the game to pull in FLOW. `needsEngineRoute` is true today, and the
/// card says so in one line.
public struct SessionBrief: Equatable, Sendable {
    public let client: String
    public let headline: String          // the one thing to teach today
    public let supportLines: [String]    // the feed lines behind it, in engine order
    public let filmLine: String          // the game to pull in FLOW (or why there is none)
    public let filmReadiness: String?    // Stage 5: pipeline film state in plain words; nil = ready/unknown (quiet)
    public let caveat: String            // what this brief cannot say, and what would fix it
    public let needsEngineRoute: Bool
}

/// Pure derivation from the feed. The engine's line formats are fixed (engine/peaknextsession.py):
/// "Last met {date}.", "{n} game(s) since then.", "{G} G, {A} A, {P} P since last met.",
/// "Latest: {date} vs {opponent}, {result} {score}.", "Ghost score avg {x} since last met.",
/// "Team changed: {a} -> {b}." A line that doesn't parse is ignored, never guessed: the date must
/// be YYYY-MM-DD, the opponent must be a real name (never "?"), and the average must be a number.
public enum SessionBriefBuilder {
    public static let caveat = "Built from Ghost since-last-met. A per-metric regression and a clip link need a session-brief engine route."

    struct Parsed: Equatable {
        var games: String?
        var points: String?
        var latestDate: String?
        var latestOpponent: String?
        var latestResult: String?
        var latestScore: String?
        var ghostAvg: String?
        var teamChange: String?
    }

    static func isISODate(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.joined().allSatisfy(\.isNumber)
    }

    static func parse(_ lines: [String]) -> Parsed {
        var p = Parsed()
        for line in lines {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("Latest: ") {
                let rest = String(l.dropFirst("Latest: ".count))
                let parts = rest.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                let head = parts[0]
                if let vs = head.range(of: " vs ") {
                    let date = String(head[..<vs.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let opp = String(head[vs.upperBound...]).trimmingCharacters(in: .whitespaces)
                    guard isISODate(date), !opp.isEmpty, opp != "?" else { continue }
                    p.latestDate = date
                    p.latestOpponent = opp
                    if parts.count > 1 {
                        let res = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        let toks = res.split(separator: " ").map(String.init)
                        p.latestResult = toks.first
                        if toks.count > 1 { p.latestScore = toks.dropFirst().joined(separator: " ") }
                    }
                }
            } else if l.hasPrefix("Ghost score avg ") {
                let rest = String(l.dropFirst("Ghost score avg ".count))
                if let tok = rest.split(separator: " ").first.map(String.init), Double(tok) != nil {
                    p.ghostAvg = tok
                }
            } else if l.contains(" G, "), l.hasSuffix(" P since last met.") {
                p.points = l
            } else if l.hasSuffix(" games since then.") || l.hasSuffix(" game since then.") {
                p.games = l
            } else if l.hasPrefix("Team changed: ") {
                p.teamChange = l
            }
        }
        return p
    }

    /// The brief for today's session, or nil when there is no session today (the brief is per-session).
    public static func build(session: NextSession, since: SinceLastMet?) -> SessionBrief? {
        guard session.today else { return nil }
        let p = parse(since?.lines ?? [])

        let latestLine: String? = {
            guard let d = p.latestDate, let o = p.latestOpponent else { return nil }
            var s = "Latest: \(d) vs \(o)"
            if let r = p.latestResult { s += ", \(r)" + (p.latestScore.map { " \($0)" } ?? "") }
            return s + "."
        }()

        // The headline leads with one feed fact; whichever fact it spends is NOT repeated
        // in the support lines — each fact appears once on the card. (The win/loss Latest
        // line used to print as the headline AND as the last support line; the date the
        // loss headline drops still rides the film line, which names the game to pull.)
        var spent = Set<String>()
        let headline: String = {
            if p.latestResult == "L", let o = p.latestOpponent {
                spent.insert("latest")
                let score = p.latestScore.map { " \($0)" } ?? ""
                return "Last game: lost\(score) to \(o). Open on what broke down."
            }
            if let latest = latestLine {
                spent.insert("latest")
                return "\(latest) Start with that game."
            }
            if let avg = p.ghostAvg {
                spent.insert("avg")
                return "Ghost score avg \(avg) since last met. Hold the standard from there."
            }
            if let pts = p.points {
                spent.insert("points")
                return "\(pts) Start from the totals."
            }
            return "No Ghost read for \(session.client) yet — open the last breakdown."
        }()

        var support: [String] = []
        if let g = p.games { support.append(g) }
        if let pts = p.points, !spent.contains("points") { support.append(pts) }
        if let avg = p.ghostAvg, !spent.contains("avg") {
            support.append("Ghost score avg \(avg) since last met.")
        }
        if let tc = p.teamChange { support.append(tc) }
        if let latest = latestLine, !spent.contains("latest") { support.append(latest) }

        let filmLine: String = {
            guard let d = p.latestDate, let o = p.latestOpponent else {
                return "No game since last met — open the last breakdown instead."
            }
            return "Film: \(d) vs \(o) — pull it in FLOW."
        }()

        return SessionBrief(client: session.client, headline: headline, supportLines: Array(support.prefix(4)),
                            filmLine: filmLine, filmReadiness: session.film?.readinessLine, caveat: caveat, needsEngineRoute: true)
    }
}

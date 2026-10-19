import Foundation

// Client commands Peak recognises itself, typed or spoken (the voice transcript goes through ThreePOStore.send() exactly
// like a typed message). Two today:
//   "Open <client>'s FLOW package (and hit the code button)"   "Start a meeting with <client>"
// Each one only produces a describe-first confirm card naming the client, the meeting and the time, with Run / Ask Claude /
// Copy prompt. Nothing runs until Run is tapped, and Run only opens Command's own UI (its room page or schedule) or brings
// FLOW forward. Peak never joins, records, books or reschedules, and never touches the recorder. A desktop click (FLOW's
// code button) is a Cua action: it stays behind settings `desktop_actions`, OFF until the STOP dry run passes.
// An unclear client gets a pick card instead. Zero tokens; nothing leaves this Mac.

public enum ClientCommandKind: String, Sendable { case flowPackage = "flow_package", startMeeting = "start_meeting" }

public struct ClientCommand: Equatable, Sendable {
    public var kind: ClientCommandKind
    public var spokenClient: String
    public var codeButton = false
    public var when: String? = nil
    public var said: String
}

public struct ClientCommandContext: Sendable {
    public var roster: [String]
    public var meeting: MeetingRow?
    public var desktopActions: Bool
    public var flowApp: String?            // the profile's FLOW app name (allow-listed), if any
    public var now: Date
    public var timeZone: TimeZone
    /// .dryRun only from DesktopActionGate (env + scratch root); Run then locates and reports, nothing else.
    public var desktopMode: DesktopActionMode
    public init(roster: [String], meeting: MeetingRow? = nil, desktopActions: Bool = false, flowApp: String? = nil,
                now: Date = Date(), timeZone: TimeZone = .current, desktopMode: DesktopActionMode = .off) {
        self.roster = roster; self.meeting = meeting; self.desktopActions = desktopActions; self.flowApp = flowApp
        self.now = now; self.timeZone = timeZone; self.desktopMode = desktopMode
    }
}

public enum ClientCommands {
    // ── parse ──
    static func normalize(_ t: String) -> String {
        var s = t.replacingOccurrences(of: "’", with: "'").lowercased()
        s = s.replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        // spoken lead-ins: "hey 3po,", "okay so,", "um,", "please"
        let lead = #"^(?:(?:hey|ok|okay|so|um|uh|like|please|3po|threepio|three p o)[, ]+)+"#
        s = s.replacingOccurrences(of: lead, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }
    static let flowA = try! NSRegularExpression(pattern: #"^open (?:up )?(?:the )?(?:latest )?flow package for (.+?)(?: and (?:hit|press|click|tap|push) (?:the )?code button)?$"#)
    static let flowB = try! NSRegularExpression(pattern: #"^open (?:up )?(.+?)(?:'s)? (?:latest |last |newest )?flow package(?: and (?:hit|press|click|tap|push) (?:the )?code button)?$"#)
    static let meet = try! NSRegularExpression(pattern: #"^(?:start|begin|open) (?:a |the |my )?(?:meeting|session|call|check-in|check in) (?:with|for) (.+?)(?: (?:at|around) ([0-9][0-9:. ]*(?:am|pm|a\.m\.|p\.m\.)?|noon))?$"#)

    static func groups(_ rx: NSRegularExpression, _ s: String) -> [String?]? {
        guard let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }

    public static func parse(_ text: String) -> ClientCommand? {
        let s = normalize(text)
        guard !s.isEmpty, s.count <= 200 else { return nil }
        let code = s.range(of: #" and (?:hit|press|click|tap|push) (?:the )?code button$"#, options: .regularExpression) != nil
        if let g = groups(flowA, s) ?? groups(flowB, s), let c = g[1], !c.isEmpty {
            return ClientCommand(kind: .flowPackage, spokenClient: clean(c), codeButton: code, said: text)
        }
        if let g = groups(meet, s), let c = g[1], !c.isEmpty {
            var who = clean(c)
            // trailing chatter after the name: ", um, after lunch" → when
            var when = g.count > 2 ? g[2] : nil
            if let r = who.range(of: #",? (?:um,? |uh,? )?(?:after|before|later|today|tomorrow|this) .*$"#, options: .regularExpression) {
                when = when ?? String(who[r]).trimmingCharacters(in: CharacterSet(charactersIn: ", ")); who = String(who[..<r.lowerBound])
            }
            return ClientCommand(kind: .startMeeting, spokenClient: clean(who), when: when?.trimmingCharacters(in: .whitespaces), said: text)
        }
        return nil
    }
    static func clean(_ c: String) -> String {
        var x = c.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        for p in ["client ", "the client "] where x.hasPrefix(p) { x = String(x.dropFirst(p.count)) }
        if x.hasSuffix("'s") { x = String(x.dropLast(2)) }
        return x
    }

    // ── resolve against this coach's roster ──
    /// Roster names for what was said, best first. One → that client; several equally good → ambiguous (pick card).
    public static func resolve(_ spoken: String, roster: [String]) -> [String] {
        let said = spoken.lowercased().split { !$0.isLetter && $0 != "-" }.map(String.init).filter { !$0.isEmpty }
        guard !said.isEmpty else { return [] }
        var scored: [(String, Double)] = []
        for full in roster {
            let toks = full.lowercased().split { !$0.isLetter && $0 != "-" }.map(String.init)
            guard !toks.isEmpty else { continue }
            var score = 0.0
            if toks == said { score = 4 }
            else if said.count > 1, said.allSatisfy({ toks.contains($0) }) { score = 3 }
            else if said.contains(where: { s in s.count >= 3 && toks.contains(s) }) { score = 2 }
            else {
                var best = 0.0
                for s in said where s.count >= 3 {
                    for t in toks { best = max(best, VoiceNameGuard.similarity(s, t), s.hasSuffix("s") ? VoiceNameGuard.similarity(String(s.dropLast()), t) : 0) }
                }
                if best >= 0.75 { score = best }
            }
            if score > 0 { scored.append((full, score)) }
        }
        guard let top = scored.map(\.1).max() else { return [] }
        let tied = scored.filter { abs($0.1 - top) < 0.001 }.map(\.0)
        if tied.count > 1 { return tied }
        return scored.sorted { $0.1 > $1.1 }.map(\.0).prefix(1).map { $0 }
    }
    /// Near misses for a pick card when nothing matched well enough (best 3, similarity ≥ 0.5).
    static func near(_ spoken: String, roster: [String]) -> [String] {
        let said = spoken.lowercased().split { !$0.isLetter }.map(String.init)
        return roster.map { full -> (String, Double) in
            let toks = full.lowercased().split { !$0.isLetter }.map(String.init)
            let b = said.flatMap { s in toks.map { VoiceNameGuard.similarity(s, $0) } }.max() ?? 0
            // A name the recogniser split into other words ("Tobias Marchetti's" → "to buy a smartis"): runs of up to
            // four spoken words, squashed, against the squashed full name. Offered as a pick only; never auto-chosen.
            let whole = toks.joined()
            var w = 0.0
            for i in said.indices { for j in (i + 1)...min(said.count, i + 4) { w = max(w, VoiceNameGuard.similarity(said[i..<j].joined(), whole)) } }
            return (full, max(b, w))
        }.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
    }

    // ── route: text → a local reply with one card, or nil (then it goes to 3PO as usual) ──
    public static func route(_ text: String, _ ctx: ClientCommandContext, id: String) -> (reply: String, card: ProposalCard)? {
        guard let cmd = parse(text) else { return nil }
        return route(cmd, ctx, id: id)
    }

    public static func route(_ cmd: ClientCommand, _ ctx: ClientCommandContext, id: String) -> (reply: String, card: ProposalCard) {
        let hits = resolve(cmd.spokenClient, roster: ctx.roster)
        if hits.count == 1 {
            let c = card(cmd, client: hits[0], ctx, id: id)
            return ("Here's what that does for \(hits[0]). Nothing runs until you tap Run.", c)
        }
        let picks = hits.isEmpty ? near(cmd.spokenClient, roster: ctx.roster) : hits
        return (hits.isEmpty ? "I don't see \u{201C}\(cmd.spokenClient)\u{201D} on your roster. Which client did you mean?"
                             : "More than one client matches \u{201C}\(cmd.spokenClient)\u{201D}. Which one?",
                pickCard(cmd, picks: picks, id: id))
    }

    public static func pickCard(_ cmd: ClientCommand, picks: [String], id: String) -> ProposalCard {
        var c = ProposalCard(id: id, action: "pick_client", label: cmd.kind == .flowPackage ? "Open a FLOW package" : "Start a meeting",
                             client: nil, inputs: ["You said: \(cmd.said)"], touches: "Nothing (a pick only)", outputs: [],
                             reason: picks.isEmpty ? "No client on your roster sounds like that." : "Pick the client. The next card shows what Run would do.",
                             message: "Nothing has run.", status: "pick", viewOnly: false, previewBody: nil, confirmBody: nil)
        c.origin = .pick; c.picks = picks
        return c
    }

    static func sameClient(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    public static func when(_ d: Date, now: Date, tz: TimeZone) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = "EEE MMM d, h:mm a"
        let mins = Int((d.timeIntervalSince(now) / 60).rounded())
        let rel = mins >= 0 ? (mins < 60 ? "in \(mins) min" : "in \(mins / 60) h \(mins % 60) min") : "started \(-mins) min ago"
        return "\(f.string(from: d)) \(tz.abbreviation(for: d) ?? "") (\(rel))".replacingOccurrences(of: "  ", with: " ")
    }

    /// The confirm card: client, meeting, time, and exactly what Run opens.
    public static func card(_ cmd: ClientCommand, client: String, _ ctx: ClientCommandContext, id: String) -> ProposalCard {
        let m = ctx.meeting.flatMap { sameClient($0.client, client) ? $0 : nil }
        let meetingLine = m.map { "Meeting: next booking in Command, \($0.durationMinutes) min" } ?? "Meeting: none booked in Command"
        let timeLine = m.map { "Time: " + when($0.scheduledAt, now: ctx.now, tz: ctx.timeZone) } ?? "Time: not booked"
        var c: ProposalCard
        switch cmd.kind {
        case .startMeeting:
            let link = m.map { CommandLink.safe($0.openURL) } ?? CommandLink.schedule
            c = ProposalCard(id: id, action: "start_meeting", label: "Start a meeting with \(client)", client: client,
                             inputs: ["Client: \(client)", meetingLine, timeLine] + (cmd.when.map { ["You asked for: \($0)"] } ?? []),
                             touches: m == nil ? "Opens Command's schedule (Command's own UI). Nothing is booked from Peak."
                                               : "Opens Command's room page for this booking (Command's own UI). You tap Join / Record in Command; Peak never joins, records or books.",
                             outputs: [m == nil ? "Command: the schedule" : "Command: the room page"],
                             reason: "You said: \u{201C}\(cmd.said)\u{201D}", message: "Nothing has run. Run only opens Command.",
                             status: "proposed", viewOnly: false, previewBody: nil, confirmBody: nil)
            c.link = link
        case .flowPackage:
            let click = cmd.codeButton
            c = ProposalCard(id: id, action: click ? "flow_package_code" : "flow_package",
                             label: "Open \(client)'s FLOW package" + (click ? " and press the code button" : ""), client: client,
                             inputs: ["Client: \(client)", "Package: \(client)'s latest FLOW package (~/Desktop/FLOW)", meetingLine,
                                      "Time: now, when you tap Run"],
                             touches: click
                                 ? "Brings FLOW forward. The code button is a desktop click (Cua): it stays behind Desktop actions (\(ctx.desktopActions ? "on" : "off"), and not wired from Peak until the STOP dry run passes), so you press it in FLOW."
                                 : "Brings FLOW forward.",
                             outputs: ["FLOW in front"], reason: "You said: \u{201C}\(cmd.said)\u{201D}",
                             message: "Nothing has run. Run only opens FLOW.",
                             status: "proposed", viewOnly: false, previewBody: nil, confirmBody: nil)
            c.appName = ctx.flowApp ?? "FLOW"
        }
        c.origin = .command
        if ctx.desktopMode == .dryRun {
            c.touches = "Dry run for \(client): Run plans each step and locates its target (deep link, URL scheme, App Intents, "
                + "Accessibility, Cua last) and reports. Nothing is clicked, typed, opened or booked" + (cmd.kind == .flowPackage ? "; FLOW may come forward." : ".")
                + " STOP aborts at once."
            c.message = "Nothing has run. Run starts a dry run for \(client) (locate and report only)."
            c.outputs = ["A dry-run report for \(client)"]
        }
        return c
    }
}

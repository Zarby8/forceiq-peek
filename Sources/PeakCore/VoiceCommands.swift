import Foundation

// Client commands Peak recognises itself, typed or spoken (the voice transcript goes through ThreePOStore.send() exactly
// like a typed message). Two today:
//   "Open <client>'s FLOW package (and hit the code button)"   "Start a meeting with <client>"
// Each one only produces a describe-first confirm card naming the client, the meeting and the time, with Run / Ask Claude /
// Copy prompt. Nothing runs until Run is tapped, and Run only opens Command's own UI (its room page or schedule) or brings
// FLOW forward. Peak never joins, records, books or reschedules, and never touches the recorder. A desktop click (FLOW's
// code button) is a Cua action: it stays behind settings `desktopActions` (OFF, no UI); Peak presses FLOW's
// Code Window only in a gated scratch live setup after Run (see DesktopLive.swift).
// An unclear client gets a pick card instead. Zero tokens; nothing leaves this Mac.
// With the Command meeting link flag on (CommandMeetingLink.swift, OFF by default), "start a meeting" resolves the client
// in this coach's Command directory instead, and Run opens Command's own Start sheet (nothing starts until Start there).

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
    /// The Command meeting link (CommandMeetingLinkGate; OFF by default). On, and only with desktop actions off, a
    /// "start a meeting" command resolves the client in this coach's Command directory and Run opens Command's Start
    /// sheet (CommandMeetingLink.swift). Off: the meeting card is exactly what it was.
    public var commandMeetingLink: Bool
    /// Cua is the live press's backend (CuaGate open; only ever with desktopMode .live). The card then says so.
    public var cua: Bool
    public init(roster: [String], meeting: MeetingRow? = nil, desktopActions: Bool = false, flowApp: String? = nil,
                now: Date = Date(), timeZone: TimeZone = .current, desktopMode: DesktopActionMode = .off, commandMeetingLink: Bool = false,
                cua: Bool = false) {
        self.roster = roster; self.meeting = meeting; self.desktopActions = desktopActions; self.flowApp = flowApp
        self.now = now; self.timeZone = timeZone; self.desktopMode = desktopMode; self.commandMeetingLink = commandMeetingLink
        self.cua = cua && desktopMode == .live
    }
    /// The meeting link path applies: the flag is on and no desktop dry-run / live gate is active (those stay locate-only).
    public var usesMeetingLink: Bool { commandMeetingLink && desktopMode == .off }
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
                                 ? "Brings FLOW forward. The code button is a desktop click (Cua): it stays behind Desktop actions (\(ctx.desktopActions ? "on" : "off"); Peak presses it only in a scratch live setup after Run), so you press it in FLOW."
                                 : "Brings FLOW forward.",
                             outputs: ["FLOW in front"], reason: "You said: \u{201C}\(cmd.said)\u{201D}",
                             message: "Nothing has run. Run only opens FLOW.",
                             status: "proposed", viewOnly: false, previewBody: nil, confirmBody: nil)
            c.appName = ctx.flowApp ?? "FLOW"
        }
        c.origin = .command
        if ctx.desktopMode == .live && cmd.kind == .flowPackage && cmd.codeButton {
            c.touches = "Live for \(client): Run finds \(client)'s latest FLOW package, brings FLOW forward, then presses FLOW's "
                + "'Code Window' menu item (an Accessibility press on that exact item, only if FLOW's front window is \(client)'s package). "
                + "Nothing else is clicked or typed. STOP (or Esc) halts it at once, even right before the press."
                + (ctx.cua ? " Cua makes that press (cua-driver invokes the menu item through Accessibility), and only after a second card says what it will do and what it touches and you tap its Run." : "")
            c.message = "Nothing has run. Run presses FLOW's Code Window for \(client) after those checks; STOP halts it."
            c.outputs = ["FLOW's Code Window for \(client)'s package"]
        } else if ctx.desktopMode == .dryRun || ctx.desktopMode == .live {      // live mode: everything else stays locate-only
            c.touches = "Dry run for \(client): Run plans each step and locates its target (deep link, URL scheme, App Intents, "
                + "Accessibility, Cua last) and reports. Nothing is clicked, typed, opened or booked" + (cmd.kind == .flowPackage ? "; FLOW may come forward." : ".")
                + " STOP aborts at once."
            c.message = "Nothing has run. Run starts a dry run for \(client) (locate and report only)."
            c.outputs = ["A dry-run report for \(client)"]
        }
        return c
    }
}

// ── the Command meeting link (flag on): cards built from this coach's Command directory ──
public extension ClientCommands {
    static let meetingLinkAction = "start_meeting_link"
    static let notFoundAction = "client_not_found"
    static let directoryProblemAction = "command_directory"

    /// The describe-first card for ONE directory client: names the client, says Run only opens Command's Start sheet and
    /// that nothing starts until Start is tapped in Command. nil when the id isn't a valid UUID (no link from a name).
    static func meetingLinkCard(_ cmd: ClientCommand, client: DirectoryClient, _ ctx: ClientCommandContext, id: String,
                                exact: Bool) -> ProposalCard? {
        guard let link = CommandMeetingLink.url(clientID: client.id) else { return nil }
        let name = client.displayName
        let m = ctx.meeting.flatMap { sameClient($0.client, name) ? $0 : nil }
        let timeLine = m.map { "Next booking: " + when($0.scheduledAt, now: ctx.now, tz: ctx.timeZone) } ?? "Next booking: none in Command"
        var c = ProposalCard(id: id, action: meetingLinkAction, label: "Start a meeting with \(name)", client: name,
                             inputs: ["Client: \(name)",
                                      exact ? "Matched: exactly one client with this name in your Command directory" : "Matched: you picked this client",
                                      timeLine] + (cmd.when.map { ["You asked for: \($0)"] } ?? []),
                             touches: "Opens Command's Start meeting sheet for \(name) (Command's own confirm, with Start and Cancel). "
                                + "Nothing starts until you tap Start in Command; Cancel there leaves everything as it was. "
                                + "Peak never joins, records or books.",
                             outputs: ["Command: the Start meeting sheet for \(name)"],
                             reason: "You said: \u{201C}\(cmd.said)\u{201D}",
                             message: "Nothing has run. Run only opens Command's Start sheet.",
                             status: "proposed", viewOnly: false, previewBody: nil, confirmBody: nil)
        c.origin = .command
        c.link = link
        return c
    }

    /// Several, partial or fuzzy matches: the coach picks one by name (button labels from DirectoryMatcher.labels).
    static func meetingLinkPickCard(_ cmd: ClientCommand, labels: [String], id: String) -> ProposalCard {
        var c = ProposalCard(id: id, action: "pick_client", label: "Start a meeting", client: nil,
                             inputs: ["You said: \(cmd.said)"], touches: "Nothing (a pick only)", outputs: [],
                             reason: "Pick the client from your Command directory. The next card shows what Run would do.",
                             message: "Nothing has run.", status: "pick", viewOnly: false, previewBody: nil, confirmBody: nil)
        c.origin = .pick; c.picks = labels
        return c
    }

    /// No client in the directory sounds like that: a plain card, nothing to run.
    static func notFoundCard(_ cmd: ClientCommand, id: String) -> ProposalCard {
        var c = ProposalCard(id: id, action: notFoundAction, label: "Start a meeting", client: nil,
                             inputs: ["You said: \(cmd.said)"], touches: "Nothing", outputs: [],
                             reason: "No active client in your Command directory matches \u{201C}\(cmd.spokenClient)\u{201D}.",
                             message: "Not found. Nothing has run.", status: "not_found", viewOnly: true, previewBody: nil, confirmBody: nil)
        c.origin = .command
        return c
    }

    /// The directory couldn't be read (sign-in expired, a client-role session, Command down): one plain card, no Run.
    static func directoryProblemCard(_ cmd: ClientCommand, _ r: DirectoryResult, id: String) -> ProposalCard {
        let why: String, msg: String
        switch r {
        case .signedOut(let n): why = n.message; msg = "Nothing has run. Tap \(n.label) on Peak's home, then ask again."
        case .forbidden(let m): why = m; msg = "Nothing has run. Sign in to Command as a coach or admin, then ask again."
        case .failed(let m): why = m; msg = "Nothing has run. Try again in a minute."
        case .clients: why = "Your Command directory is empty."; msg = "Nothing has run."
        }
        var c = ProposalCard(id: id, action: directoryProblemAction, label: "Start a meeting", client: nil,
                             inputs: ["You said: \(cmd.said)"], touches: "Nothing", outputs: [],
                             reason: why, message: msg, status: r.outcome, viewOnly: true, previewBody: nil, confirmBody: nil)
        c.origin = .command
        return c
    }
}

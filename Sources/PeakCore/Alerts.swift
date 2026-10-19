import Foundation

// Notch alerts: a one-line peek that drops out of the notch for a few seconds, then retracts. This file is the whole
// decision (pure: no UI, no clock, no network); the app only shows what it returns.
//
// Only two things are urgent enough to interrupt: a meeting that starts within 10 minutes, and a fix that just failed
// (a failure that appears after Peak is up, never the ones already in the feed at launch). Every alert names its client.
// Nothing peeks while Peak is already open, while the coach is dictating, during a live meeting, in quiet hours, under
// do-not-disturb, or within a minute of the last peek. A suppressed alert is not spent: it can still fire once the gate lifts.

public enum PeakAlertKind: String, Sendable {
    case meetingSoon = "meeting-soon", fixFailed = "fix-failed", signInExpired = "sign-in-expired", approval, family, downloadDone = "download-done"
    /// The dot's brand color: green = good news or a countdown, gold = something needs you.
    public var dotHex: UInt32 {
        switch self { case .meetingSoon, .downloadDone: return Brand.greenHex; default: return Brand.goldHex }
    }
    /// The client-free wording (Presenting, and the default when an alert doesn't give its own).
    var defaultPlainLine: String {
        switch self {
        case .meetingSoon: return "A session is coming up"; case .fixFailed: return "A fix failed"
        case .signInExpired: return "Command sign-in expired"; case .approval: return "An item needs your OK"
        case .family: return "A family delivery needs you"; case .downloadDone: return "A download finished"
        }
    }
    /// Lower = more urgent: when several are waiting, the most urgent peeks first.
    var priority: Int {
        switch self { case .meetingSoon: return 0; case .fixFailed: return 1; case .signInExpired: return 2; case .approval: return 3; case .family: return 4; case .downloadDone: return 5 }
    }
}

public struct PeakAlert: Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: PeakAlertKind
    public let client: String
    public let line: String
    public let holdSeconds: Double
    /// The same alert without the client, for a shared screen (Presenting.redact).
    public let plainLine: String
    /// The inline peek's two halves: the client on the left of the notch, what happened on the right. With no client (presenting)
    /// the plain line splits after its first two words ("A session" | "in 9 min").
    public var lead: String { client.isEmpty ? PeakAlert.words(line).lead : client }
    public var trail: String {
        client.isEmpty ? PeakAlert.words(line).trail
            : String(line.dropFirst(client.count)).trimmingCharacters(in: CharacterSet(charactersIn: " :"))
    }
    static func words(_ s: String) -> (lead: String, trail: String) {
        let w = s.split(separator: " ", omittingEmptySubsequences: true)
        return (w.prefix(2).joined(separator: " "), w.dropFirst(2).joined(separator: " "))
    }
    public init(id: String, kind: PeakAlertKind, client: String, line: String, holdSeconds: Double, plainLine: String? = nil) {
        self.id = id; self.kind = kind; self.client = client; self.line = line; self.holdSeconds = holdSeconds
        self.plainLine = plainLine ?? kind.defaultPlainLine
    }
}

/// A daily window (local time) with no peeks. start == end means no window; start > end wraps midnight (22:00 to 07:00).
public struct QuietHours: Equatable, Sendable {
    public let startMinute: Int
    public let endMinute: Int
    public init(startMinute: Int, endMinute: Int) { self.startMinute = startMinute; self.endMinute = endMinute }
    public init?(start: String, end: String) {
        guard let s = QuietHours.minute(start), let e = QuietHours.minute(end) else { return nil }
        self.init(startMinute: s, endMinute: e)
    }
    /// "HH:mm" (24 h) as minutes after midnight; nil for anything else.
    public static func minute(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2, p[0].count == 2, p[1].count == 2, let h = Int(p[0]), let m = Int(p[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
    public func contains(_ d: Date, calendar: Calendar = .current) -> Bool {
        guard startMinute != endMinute else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: d)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return startMinute < endMinute ? (m >= startMinute && m < endMinute) : (m >= startMinute || m < endMinute)
    }
}

public struct AlertContext: Sendable {
    public var now: Date
    public var expanded: Bool
    public var dictating: Bool
    public var dndUntil: Date?
    public var quietHours: QuietHours?
    public var calendar: Calendar
    public init(now: Date, expanded: Bool = false, dictating: Bool = false, dndUntil: Date? = nil, quietHours: QuietHours? = nil, calendar: Calendar = .current) {
        self.now = now; self.expanded = expanded; self.dictating = dictating; self.dndUntil = dndUntil
        self.quietHours = quietHours; self.calendar = calendar
    }
}

public enum AlertSuppression: String, Sendable { case expanded, dictating, doNotDisturb = "dnd", quietHours = "quiet-hours", liveMeeting = "live-meeting", cooldown }

public struct AlertPolicy: Sendable {
    public static let leadSeconds: TimeInterval = 600
    public static let cooldownSeconds: TimeInterval = 60
    public static let meetingHold: Double = 6
    public static let fixHold: Double = 8
    public static let signInHold: Double = 8
    public static let infoHold: Double = 6

    public private(set) var shown: Set<String> = []
    public private(set) var lastShownAt: Date?
    public private(set) var lastSuppression: AlertSuppression?
    private var primed = false
    private var primedSources: Set<String> = []
    private var signInWasExpired = false
    private var signInPending = false
    static let signInID = "signin:pending"
    public init() {}

    /// The first reason an alert may not peek right now, or nil. Order = which reason is reported when several apply.
    public static func suppression(_ ctx: AlertContext, snapshot s: EngineSnapshot, lastShownAt: Date?) -> AlertSuppression? {
        if ctx.expanded { return .expanded }
        if ctx.dictating { return .dictating }
        if let until = ctx.dndUntil, until > ctx.now { return .doNotDisturb }
        if ctx.quietHours?.contains(ctx.now, calendar: ctx.calendar) == true { return .quietHours }
        if liveMeeting(s, now: ctx.now) { return .liveMeeting }
        if let last = lastShownAt, ctx.now.timeIntervalSince(last) < cooldownSeconds { return .cooldown }
        return nil
    }

    /// A session is running right now (today's sessions, plus the feed's next meeting if it has already started).
    public static func liveMeeting(_ s: EngineSnapshot, now: Date) -> Bool {
        var spans = (s.today ?? []).map { ($0.scheduledAt, $0.durationMinutes) }
        if let m = s.meeting { spans.append((m.scheduledAt, m.durationMinutes)) }
        return spans.contains { $0.0 <= now && now < $0.0.addingTimeInterval(Double($0.1) * 60) }
    }

    /// The one alert to peek now, if any. `cards` are the roster-scoped cards (a client who isn't this coach's never peeks).
    /// What can peek: a meeting within 10 minutes, a fix that failed, Command's sign-in expiring, a new approval waiting, a new
    /// family-delivery alert, a shift download finishing. Everything but the meeting is news only: what was already there when
    /// Peak first read that source is the baseline and never peeks. `isMyClient` scopes download rows to this coach's roster.
    public mutating func next(snapshot s: EngineSnapshot, cards: [PeakCard], context ctx: AlertContext,
                              isMyClient: (String) -> Bool = { _ in false }) -> PeakAlert? {
        var fresh: [PeakAlert] = []
        for c in cards where c.kind == .meeting {
            guard let at = c.startsAt else { continue }
            let secs = at.timeIntervalSince(ctx.now)
            guard secs > 0, secs <= Self.leadSeconds, !shown.contains(c.id) else { continue }
            let mins = max(1, Int((secs / 60).rounded(.up)))
            fresh.append(PeakAlert(id: c.id, kind: .meetingSoon, client: c.client, line: "\(c.client) in \(mins) min", holdSeconds: Self.meetingHold, plainLine: "A session in \(mins) min"))
        }
        let fixesKnown = s.liveAt != nil                                         // this read really included GOAT's live doc
        for f in s.fixes where fixesKnown && f.state == "failed" {
            guard let c = cards.first(where: { $0.kind == .fix && $0.client == f.client && $0.title == f.title }) else { continue }
            let id = "\(c.id):failed"
            guard !shown.contains(id) else { continue }
            if !primed { shown.insert(id); continue }                         // already failing when Peak came up: not news
            fresh.append(PeakAlert(id: id, kind: .fixFailed, client: c.client, line: "\(c.client): a fix failed", holdSeconds: Self.fixHold))
        }
        if fixesKnown { primed = true }
        // Command's sign-in expiring (a transition after Peak is up; held, not spent, until it can peek or it is signed in again).
        let expired = s.commandSignIn != nil
        if primedSources.contains("signin") { if expired && !signInWasExpired { signInPending = true } }
        if !expired { signInPending = false }
        signInWasExpired = expired; primedSources.insert("signin")
        if signInPending {
            fresh.append(PeakAlert(id: Self.signInID, kind: .signInExpired, client: "", line: "Command sign-in expired", holdSeconds: Self.signInHold))
        }
        for (kind, cardKind, source, known, say, plain) in [
            (PeakAlertKind.approval, CardKind.approval, "approvals", s.approvalsAt != nil, "needs your OK", "An item needs your OK"),
            (PeakAlertKind.family, CardKind.family, "family", s.familyEnabled, "family delivery needs you", "A family delivery needs you")] {
            guard known else { continue }
            for c in cards where c.kind == cardKind {
                guard !shown.contains(c.id) else { continue }
                if !primedSources.contains(source) { shown.insert(c.id); continue }
                fresh.append(PeakAlert(id: c.id, kind: kind, client: c.client, line: "\(c.client): \(say)", holdSeconds: Self.infoHold, plainLine: plain))
            }
            primedSources.insert(source)
        }
        if s.liveAt != nil {
            for d in s.downloadsDone where isMyClient(d.client) {
                let id = "download:\(d.id)"
                guard !shown.contains(id) else { continue }
                if !primedSources.contains("downloads") { shown.insert(id); continue }
                fresh.append(PeakAlert(id: id, kind: .downloadDone, client: d.client, line: "\(d.client): download finished",
                                       holdSeconds: Self.infoHold, plainLine: "A download finished"))
            }
            primedSources.insert("downloads")
        }
        fresh.sort { $0.kind.priority < $1.kind.priority }
        guard let a = fresh.first else { lastSuppression = nil; return nil }
        if let why = Self.suppression(ctx, snapshot: s, lastShownAt: lastShownAt) { lastSuppression = why; return nil }
        lastSuppression = nil
        if a.id == Self.signInID { signInPending = false } else { shown.insert(a.id) }
        lastShownAt = ctx.now
        return a
    }
}

public enum DoNotDisturb {
    /// The next 07:00 local after `now` ("until tomorrow morning").
    public static func tomorrowMorning(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: 7, minute: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(12 * 3600)
    }
}

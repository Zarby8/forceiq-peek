import Foundation

// Peek's Claude Code watcher (spec: peek-agent-watcher-spec-2026-11-16). Detection is hooks + a Unix socket,
// copied from Coucou's proven mechanism: a relay (relay/peek-hook.py) forwards one stripped JSON line per hook
// event; this file is the whole state decision — pure types, no UI, no network.
//
// The relay strips content at the source (spec §7): Peek never receives a prompt, a tool input (beyond the
// held-approval summary below), a tool response or an assistant message. What crosses the socket is only:
// session_id, event name, tool NAME, cwd, timestamp, tmux labels, a rate-limit flag, and — for a held
// PermissionRequest / AskUserQuestion only — the derived display summary the approval card shows.

/// One hook event as the relay forwards it (one JSON line on peek.sock).
public struct AgentHookEvent: Equatable, Sendable {
    public var sessionID: String
    /// Claude Code's hook_event_name (SessionStart, UserPromptSubmit, PreToolUse, Notification, Stop, …).
    public var name: String
    /// The tool's name only (PreToolUse / PostToolUse / PermissionRequest); nil for lifecycle events.
    public var toolName: String?
    public var cwd: String
    public var at: Date
    public var tmuxPane: String?
    public var tmuxSession: String?
    public var tmuxWindow: String?
    /// Notification only: the relay saw "rate limit" in the notification text (the text itself never crosses).
    public var rateLimited: Bool
    /// Held events only (PermissionRequest, AskUserQuestion): the relay is waiting for Peek's reply line.
    public var held: Bool
    /// Held PermissionRequest only: the §7 derived summary (Bash command ≤ 120 chars, or "Edit path (+a −b)").
    public var summary: String?
    /// Held AskUserQuestion only: the question (≤ 200 chars) and its option labels.
    public var question: String?
    public var options: [String]

    public init(sessionID: String, name: String, toolName: String? = nil, cwd: String, at: Date,
                tmuxPane: String? = nil, tmuxSession: String? = nil, tmuxWindow: String? = nil,
                rateLimited: Bool = false, held: Bool = false, summary: String? = nil,
                question: String? = nil, options: [String] = []) {
        self.sessionID = sessionID; self.name = name; self.toolName = toolName; self.cwd = cwd; self.at = at
        self.tmuxPane = tmuxPane; self.tmuxSession = tmuxSession; self.tmuxWindow = tmuxWindow
        self.rateLimited = rateLimited; self.held = held; self.summary = summary
        self.question = question; self.options = options
    }

    /// Parse one relay line (already decoded to a dictionary). nil for anything malformed: a watcher must
    /// never guess at a session it can't identify.
    public static func parse(_ o: [String: Any]) -> AgentHookEvent? {
        guard let sid = o["session_id"] as? String, !sid.isEmpty,
              let name = o["event"] as? String, !name.isEmpty,
              let ts = (o["ts"] as? NSNumber)?.doubleValue else { return nil }
        func s(_ k: String) -> String? {
            let v = (o[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty ?? true) ? nil : v
        }
        return AgentHookEvent(sessionID: sid, name: name, toolName: s("tool"), cwd: s("cwd") ?? "",
                              at: Date(timeIntervalSince1970: ts), tmuxPane: s("tmux_pane"),
                              tmuxSession: s("tmux_session"), tmuxWindow: s("tmux_window"),
                              rateLimited: (o["rate_limit"] as? Bool) ?? false, held: (o["held"] as? Bool) ?? false,
                              summary: s("summary"), question: s("question"),
                              options: (o["options"] as? [Any])?.compactMap { $0 as? String } ?? [])
    }
}

public enum AgentSessionState: String, Sendable, CaseIterable {
    case idle, working, waiting, done, failed
    /// The pill dot's color (a shape color; red is shapes-only, as with the 5090 light). nil = no dot.
    public var dotHex: UInt32? {
        switch self {
        case .working: return Brand.goldHex
        case .waiting: return Brand.greenHex
        case .done: return Brand.whiteHex
        case .failed: return Brand.redHex
        case .idle: return nil
        }
    }
    /// Worst-first ordering for the pill: a failure outranks a wait, a wait outranks work.
    public var severity: Int {
        switch self { case .failed: return 4; case .waiting: return 3; case .working: return 2; case .done: return 1; case .idle: return 0 }
    }
}

/// One live Claude session, as the sheet may show it: state, project folder basename, tmux label, times.
/// Nothing content-bearing exists here to show.
public struct AgentSession: Equatable, Sendable, Identifiable {
    public var id: String { sessionID }
    public let sessionID: String
    public var state: AgentSessionState
    /// Project folder basename (the sheet only; never the pill, never an alert).
    public var folder: String
    /// "deploy · 2" (tmux session · window) when the session runs in tmux, else nil.
    public var tmuxLabel: String?
    /// The raw tmux target behind the label (session name, window index, pane id), kept for the
    /// sheet's tap-to-jump. Labels are display; these are what tmux can select.
    public var tmuxSessionName: String?
    public var tmuxWindowIndex: String?
    public var tmuxPaneID: String?
    public var lastEventAt: Date
    public var stateSince: Date
    public var turnStartedAt: Date?
    /// A held PermissionRequest / AskUserQuestion is waiting on Christopher (the approval card exists).
    public var waitingActionable: Bool
    public var rateLimited: Bool
    /// When the current stuck episode was flagged (the registry's sweep latches it); nil = not flagged.
    /// Latched once per episode: it clears when the session leaves .working, so a session is never
    /// nagged twice for the same stall — and a later, separate stall is a new episode.
    public var stuckSince: Date?

    public init(sessionID: String, state: AgentSessionState, folder: String, tmuxLabel: String?,
                lastEventAt: Date, stateSince: Date, turnStartedAt: Date? = nil,
                waitingActionable: Bool = false, rateLimited: Bool = false,
                tmuxSessionName: String? = nil, tmuxWindowIndex: String? = nil, tmuxPaneID: String? = nil,
                stuckSince: Date? = nil) {
        self.sessionID = sessionID; self.state = state; self.folder = folder; self.tmuxLabel = tmuxLabel
        self.lastEventAt = lastEventAt; self.stateSince = stateSince; self.turnStartedAt = turnStartedAt
        self.waitingActionable = waitingActionable; self.rateLimited = rateLimited
        self.tmuxSessionName = tmuxSessionName; self.tmuxWindowIndex = tmuxWindowIndex; self.tmuxPaneID = tmuxPaneID
        self.stuckSince = stuckSince
    }

    static func folderName(_ cwd: String) -> String {
        let t = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "?" }
        return (t as NSString).lastPathComponent.isEmpty ? t : (t as NSString).lastPathComponent
    }

    static func tmuxLabel(session: String?, window: String?) -> String? {
        guard let s = session, !s.isEmpty else { return nil }
        if let w = window, !w.isEmpty { return "\(s) · \(w)" }
        return s
    }

    /// The row's right-hand words: "working 12m", "waiting 45s", "done 09:41", "failed 3m ago", "idle".
    public func displayLine(now: Date, tz: TimeZone = BriefClock.zone) -> String {
        switch state {
        case .working, .waiting:
            let base = state == .waiting && rateLimited ? "waiting · rate limit" : state.rawValue
            return "\(base) \(Self.age(stateSince, now: now))"
        case .done: return "done \(BriefClock.time(stateSince, tz: tz))"
        case .failed: return "failed \(Self.age(stateSince, now: now)) ago"
        case .idle: return "idle"
        }
    }

    static func age(_ from: Date, now: Date) -> String {
        durationText(max(0, now.timeIntervalSince(from)))
    }

    /// "45s", "12m", "1h 05m" — the one duration format every watcher surface uses.
    public static func durationText(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }

    // ── stuck (watcher-plus): a session working far beyond normal, or silent mid-turn ──
    /// Continuous time in .working before the session counts as stuck.
    public static let stuckWorkingAfter: TimeInterval = 20 * 60
    /// Silence (no hook events) while still .working before the session counts as stuck. This sits
    /// well inside the sweep's 30-minute silence rule: stuck is the warning, the sweep's flip to
    /// idle at 30 min is the give-up — one rule set, two thresholds, no duplication.
    public static let stuckSilentAfter: TimeInterval = 10 * 60

    /// Stuck right now, computed from the clocks (the registry's sweep latches the flag itself).
    public func isStuck(now: Date) -> Bool {
        guard state == .working else { return false }
        return now.timeIntervalSince(stateSince) >= Self.stuckWorkingAfter
            || now.timeIntervalSince(lastEventAt) >= Self.stuckSilentAfter
    }

    /// Flagged stuck by the sweep (the latched, once-per-episode form of `isStuck`).
    public var isFlaggedStuck: Bool { stuckSince != nil }

    /// Where a tap on this session's sheet row can take the coach. A tmux target wins (the relay
    /// recorded the real session/window/pane); a session with no tmux target lives in the Claude
    /// desktop app — activating the app is the best jump that exists (there is no deep link to a
    /// conversation). No target at all: the row stays display-only.
    public func jumpTarget(claudeAppRunning: Bool) -> AgentJumpTarget {
        if let s = tmuxSessionName, !s.isEmpty {
            return .tmux(session: s, window: tmuxWindowIndex, pane: tmuxPaneID)
        }
        return claudeAppRunning ? .claudeApp : .none
    }
}

/// The resolved destination of a tap on a session row (see AgentSession.jumpTarget).
public enum AgentJumpTarget: Equatable, Sendable {
    case tmux(session: String, window: String?, pane: String?)
    case claudeApp
    case none
}

/// One thing that finished happening, kept in the registry's journal: a session's turn ended (done
/// or failed, with the working span's duration), or a held approval lapsed unanswered at its
/// deadline. Folder + tmux label only — the same stripped identity the live rows carry. The journal
/// feeds two surfaces: the last-finish line (sheet + the pill's done-fade window) and the
/// while-you-were-away recap assembled over a sleep window.
public struct AgentHistoryEntry: Equatable, Sendable {
    public enum Kind: String, Sendable { case finished, failed, approvalLapsed }
    public var kind: Kind
    public var folder: String
    public var tmuxLabel: String?
    public var at: Date
    /// The working span (turn start → Stop / StopFailure); nil when the turn's start was never seen.
    public var duration: TimeInterval?

    public init(kind: Kind, folder: String, tmuxLabel: String?, at: Date, duration: TimeInterval? = nil) {
        self.kind = kind; self.folder = folder; self.tmuxLabel = tmuxLabel; self.at = at; self.duration = duration
    }

    /// The outcome word the surfaces share.
    public var outcome: String {
        switch kind {
        case .finished: return "done"
        case .failed: return "failed"
        case .approvalLapsed: return "approval lapsed"
        }
    }

    /// "FlowAI · done · 12m" — folder + outcome + duration (duration omitted when unknown).
    public var line: String {
        var parts = [folder, outcome]
        if let d = duration { parts.append(AgentSession.durationText(d)) }
        return parts.joined(separator: " · ")
    }

    /// The sheet's last-finish form: the line plus the wall-clock time it happened.
    public var sheetLine: String { "\(line) · \(BriefClock.time(at))" }
}

/// The while-you-were-away recap: what the registry journaled between the mark falling asleep and
/// waking. Assembled by the registry over the sleep window; nil (no card) when nothing happened.
public struct AgentRecap: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public var id: String
        public var text: String
        public var at: Date
        public init(id: String, text: String, at: Date) { self.id = id; self.text = text; self.at = at }
    }
    public var lines: [Line]
    public var from: Date
    public var to: Date
    public init(lines: [Line], from: Date, to: Date) { self.lines = lines; self.from = from; self.to = to }
}

/// The session registry: every state transition in spec §4, and nothing inferred from processes or files.
/// Pure and value-typed so the whole watcher decision is unit-testable; the app model wraps it.
public struct AgentRegistry: Equatable, Sendable {
    public private(set) var sessions: [String: AgentSession] = [:]
    /// The journal of finished things, oldest first, capped (see AgentHistoryEntry).
    public private(set) var history: [AgentHistoryEntry] = []
    public static let historyLimit = 60
    /// How long a done session (and its finish line) holds before fading to idle (the sweep's rule).
    public static let doneFadeSeconds: TimeInterval = 60
    public init() {}

    /// Sessions in sheet order: worst state first, then most recently active.
    public var ordered: [AgentSession] {
        sessions.values.sorted {
            $0.state.severity != $1.state.severity ? $0.state.severity > $1.state.severity
                : $0.lastEventAt > $1.lastEventAt
        }
    }

    public var pill: AgentPillSummary {
        let worst = sessions.values.max { $0.state.severity < $1.state.severity }?.state
        return AgentPillSummary(count: sessions.count, worst: worst)
    }

    /// The flagged stuck session to surface (the longest-running one when several stall at once).
    public var stuckSession: AgentSession? {
        sessions.values.filter { $0.isFlaggedStuck }.min { $0.stateSince < $1.stateSince }
    }

    /// The most recent finished turn (the sheet's last-finish line; the pill shows it briefly).
    public var lastFinish: AgentHistoryEntry? { history.last { $0.kind == .finished } }

    private mutating func note(_ entry: AgentHistoryEntry) {
        history.append(entry)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    /// A held approval hit its deadline unanswered (the model saw the deadline pass; the terminal
    /// asked instead). Decided, dropped and pass-through requests are NOT lapses and never land here.
    public mutating func noteApprovalLapsed(folder: String, tmuxLabel: String?, at: Date) {
        note(AgentHistoryEntry(kind: .approvalLapsed, folder: folder, tmuxLabel: tmuxLabel, at: at))
    }

    /// The recap over a sleep window: journal entries inside (from, to], oldest first, as display
    /// lines. nil when nothing happened while the mark slept — no card, no noise.
    public func recap(from: Date, to: Date) -> AgentRecap? {
        let entries = history.filter { $0.at > from && $0.at <= to }.sorted { $0.at < $1.at }
        guard !entries.isEmpty else { return nil }
        let lines = entries.enumerated().map { i, e in
            AgentRecap.Line(id: "\(Int(e.at.timeIntervalSince1970 * 1000))-\(i)", text: e.line, at: e.at)
        }
        return AgentRecap(lines: lines, from: from, to: to)
    }

    /// One event. Returns the session's new state, or nil when the event ended / didn't identify a session.
    @discardableResult
    public mutating func apply(_ e: AgentHookEvent) -> AgentSessionState? {
        if e.name == "SessionEnd" { sessions[e.sessionID] = nil; return nil }
        var s = sessions[e.sessionID] ?? AgentSession(
            sessionID: e.sessionID, state: .idle, folder: AgentSession.folderName(e.cwd),
            tmuxLabel: AgentSession.tmuxLabel(session: e.tmuxSession, window: e.tmuxWindow),
            lastEventAt: e.at, stateSince: e.at,
            tmuxSessionName: e.tmuxSession, tmuxWindowIndex: e.tmuxWindow, tmuxPaneID: e.tmuxPane)
        // A session that moved folders / panes re-labels (the same session_id in a new cwd is a new project).
        if !e.cwd.isEmpty { s.folder = AgentSession.folderName(e.cwd) }
        if let l = AgentSession.tmuxLabel(session: e.tmuxSession, window: e.tmuxWindow) { s.tmuxLabel = l }
        if let v = e.tmuxSession, !v.isEmpty { s.tmuxSessionName = v }
        if let v = e.tmuxWindow, !v.isEmpty { s.tmuxWindowIndex = v }
        if let v = e.tmuxPane, !v.isEmpty { s.tmuxPaneID = v }
        s.lastEventAt = max(s.lastEventAt, e.at)

        func move(_ next: AgentSessionState) {
            if s.state != next { s.state = next; s.stateSince = e.at }
        }
        switch e.name {
        case "SessionStart":
            if sessions[e.sessionID] == nil { move(.idle) }
        case "UserPromptSubmit":
            s.turnStartedAt = e.at; s.rateLimited = false; s.waitingActionable = false; move(.working)
        case "PreToolUse", "PostToolUse":
            s.waitingActionable = false; if s.state != .working { move(.working) }
            if s.turnStartedAt == nil { s.turnStartedAt = e.at }
        case "PostToolUseFailure":
            // A failed tool is not a failed session: it keeps working (spec §4).
            s.waitingActionable = false; if s.state != .working { move(.working) }
            if s.turnStartedAt == nil { s.turnStartedAt = e.at }
        case "Notification":
            if e.rateLimited { s.rateLimited = true }
            if s.state == .working || s.state == .idle { move(.waiting) }
        case "PermissionRequest":
            s.waitingActionable = e.held
            if s.state == .working || s.state == .idle { move(.waiting) }
        case "Stop":
            note(AgentHistoryEntry(kind: .finished, folder: s.folder, tmuxLabel: s.tmuxLabel, at: e.at,
                                   duration: s.turnStartedAt.map { e.at.timeIntervalSince($0) }))
            s.turnStartedAt = nil; s.waitingActionable = false; move(.done)
        case "StopFailure":
            note(AgentHistoryEntry(kind: .failed, folder: s.folder, tmuxLabel: s.tmuxLabel, at: e.at,
                                   duration: s.turnStartedAt.map { e.at.timeIntervalSince($0) }))
            s.turnStartedAt = nil; s.waitingActionable = false; move(.failed)
        default:
            break   // SubagentStart/Stop and anything new: noted (lastEventAt), no state claim
        }
        if s.state != .working { s.stuckSince = nil }   // leaving working ends any stuck episode
        sessions[e.sessionID] = s
        return s.state
    }

    /// A decision was taken on the session's held request: it is no longer actionable; the next work
    /// event (or the wait timeout) moves the state on.
    public mutating func clearActionable(sessionID: String) {
        sessions[sessionID]?.waitingActionable = false
    }

    /// Clock-driven transitions (spec §4): done fades after 60 s, failed holds 5 min, an unanswered
    /// display-only wait times out after 10 min, a turn silent for 30 min stops counting as working,
    /// and a session silent for 12 h is gone even without SessionEnd.
    public mutating func sweep(now: Date) {
        for (id, var s) in sessions {
            if now.timeIntervalSince(s.lastEventAt) > 12 * 3600 { sessions[id] = nil; continue }
            switch s.state {
            case .done where now.timeIntervalSince(s.stateSince) > Self.doneFadeSeconds:
                s.state = .idle; s.stateSince = now
            case .failed where now.timeIntervalSince(s.stateSince) > 5 * 60:
                s.state = .idle; s.stateSince = now
            case .waiting where !s.waitingActionable && now.timeIntervalSince(s.stateSince) > 10 * 60:
                s.state = .idle; s.stateSince = now
            case .working where now.timeIntervalSince(s.lastEventAt) > 30 * 60:
                s.state = .idle; s.stateSince = now; s.turnStartedAt = nil
            default: break
            }
            // The stuck flag latches on the clock: set the first sweep where the session crosses a
            // threshold, held while the episode lasts, cleared as soon as it no longer holds (it
            // acted, finished, failed, or swept to idle) — once per episode, never a repeated nag.
            if s.isStuck(now: now) { if s.stuckSince == nil { s.stuckSince = now } }
            else { s.stuckSince = nil }
            sessions[id] = s
        }
    }
}

/// The collapsed pill's whole agent surface: one dot + one count (spec §5). No text, no names.
public struct AgentPillSummary: Equatable, Sendable {
    public var count: Int
    public var worst: AgentSessionState?
    public init(count: Int, worst: AgentSessionState?) { self.count = count; self.worst = worst }
    public static let none = AgentPillSummary(count: 0, worst: nil)
    /// The dot's hex; nil when only idle sessions exist (the count still shows) or there are none.
    public var dotHex: UInt32? { worst.flatMap { $0.dotHex } }
    /// Only the working dot pulses; every other state is a still shape.
    public var pulses: Bool { worst == .working }
    public var accessibilityLabel: String {
        guard count > 0 else { return "No Claude sessions" }
        let n = count == 1 ? "1 Claude session" : "\(count) Claude sessions"
        guard let w = worst, w != .idle else { return n }
        return "\(n), one \(w.rawValue)"
    }
}

/// The collapsed pill's watcher text line (watcher-plus): the one watcher sentence allowed next to
/// the dot + count. A flagged stuck session outranks everything (it needs the coach's eye); a fresh
/// finish shows for the done-fade window, then the pill goes back to its usual occupants. Folder
/// names only — and the view suppresses the line entirely while presenting, like every other
/// name-bearing pill surface.
public struct AgentPillLine: Equatable, Sendable {
    public enum Kind: String, Sendable { case stuck, finish }
    public var kind: Kind
    public var text: String
    public var accessibilityLabel: String
    public init(kind: Kind, text: String, accessibilityLabel: String) {
        self.kind = kind; self.text = text; self.accessibilityLabel = accessibilityLabel
    }
}

public enum AgentPillLineBuilder {
    public static func build(stuck: AgentSession?, lastFinish: AgentHistoryEntry?, now: Date) -> AgentPillLine? {
        if let s = stuck {
            let age = AgentSession.age(s.stateSince, now: now)
            return AgentPillLine(kind: .stuck, text: "\(s.folder) · working \(age)",
                                 accessibilityLabel: "\(s.folder) has been working for \(age); it looks stuck")
        }
        if let f = lastFinish, now.timeIntervalSince(f.at) <= AgentRegistry.doneFadeSeconds {
            return AgentPillLine(kind: .finish, text: f.line,
                                 accessibilityLabel: "\(f.folder) finished\(f.duration.map { " after \(AgentSession.durationText($0))" } ?? "")")
        }
        return nil
    }
}

/// A held PermissionRequest / AskUserQuestion waiting on Christopher (spec §3.1). Carries only the §7
/// derived summary — never a raw tool_input, never file contents — and it dies with the decision.
public struct AgentApproval: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case permission, question }
    public let id: String
    public let sessionID: String
    public let kind: Kind
    public let toolName: String?
    public let summary: String?
    public let question: String?
    public let options: [String]
    public let folder: String
    public let tmuxLabel: String?
    public let receivedAt: Date
    public let deadline: Date

    public init(event e: AgentHookEvent, receivedAt: Date) {
        self.id = "\(e.sessionID)|\(Int(e.at.timeIntervalSince1970 * 1000))"
        self.sessionID = e.sessionID
        self.kind = e.question != nil ? .question : .permission
        self.toolName = e.toolName
        self.summary = e.summary
        self.question = e.question
        self.options = e.options
        self.folder = AgentSession.folderName(e.cwd)
        self.tmuxLabel = AgentSession.tmuxLabel(session: e.tmuxSession, window: e.tmuxWindow)
        self.receivedAt = receivedAt
        self.deadline = receivedAt.addingTimeInterval(kind == .question ? 130 : 120)
    }

    /// The card's request line: the question, else the derived summary, else the bare tool name.
    public var requestLine: String {
        if let q = question { return q }
        if let s = summary, !s.isEmpty { return s }
        if let t = toolName { return t }
        return "Permission"
    }

    /// 1 → 0 over the Claude Code hook budget; the card's countdown bar.
    public func budgetFraction(now: Date) -> Double {
        let total = deadline.timeIntervalSince(receivedAt)
        guard total > 0 else { return 0 }
        return min(1, max(0, deadline.timeIntervalSince(now) / total))
    }
}

/// What Christopher tapped on the approval card. The reply line is what Peek writes back on the held
/// socket; the relay turns it into Claude Code's hookSpecificOutput. No line (nil) = the terminal asks
/// as usual — the standing fallback for "answer in terminal", a timeout, or a pass-through.
public enum AgentDecision: Equatable, Sendable {
    case allow, deny, answer(String), terminal

    public func replyLine(for kind: AgentApproval.Kind) -> String? {
        switch (self, kind) {
        case (.allow, .permission): return "{\"decision\":\"allow\"}"
        case (.deny, .permission): return "{\"decision\":\"deny\"}"
        case (.answer(let label), .question): return "{\"decision\":\"answer\",\"label\":\(Self.jsonString(label))}"
        default: return nil
        }
    }

    /// A minimal JSON string literal (labels are short UI strings; escape the structural characters).
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }
}

/// The app's watcher: the registry plus the FIFO of held approvals. Socket events arrive via `receive`;
/// the reply closure belongs to the held connection — calling it with a line answers, with nil falls
/// back to the terminal, and never calling it is made safe by `tick` expiring past-deadline requests.
@MainActor public final class AgentWatchModel: ObservableObject {
    @Published public private(set) var sessions: [AgentSession] = []
    @Published public private(set) var pending: [AgentApproval] = []
    /// The flagged stuck session, if any (drives the pill line and the mark's escalation).
    @Published public private(set) var stuck: AgentSession?
    /// The most recent finished turn (the sheet's last-finish line, until superseded).
    @Published public private(set) var lastFinish: AgentHistoryEntry?
    /// The collapsed pill's watcher text line right now (stuck, or a finish inside its fade window).
    @Published public private(set) var pillLine: AgentPillLine?
    /// The while-you-were-away recap waiting for the first expansion after a wake; nil = no card.
    @Published public private(set) var recap: AgentRecap?
    public var clock: () -> Date = Date.init
    /// Presenting at arrival: a held request passes straight through (spec §3.1) — no card, no hold.
    public var isPresenting: () -> Bool = { false }
    /// A new held request landed (and is being held): the app may expand the notch once.
    public var onHeldRequest: ((AgentApproval) -> Void)?
    weak var logger: PeakLogging?
    private var registry = AgentRegistry()
    private var resolvers: [String: (String?) -> Void] = [:]
    private var loggedStuckID: String?

    public init(logger: PeakLogging? = nil) { self.logger = logger }

    public var summary: AgentPillSummary { registry.pill }
    public var firstPending: AgentApproval? { pending.first }
    /// Held requests queued behind the first card ("+1 asking").
    public var queuedCount: Int { max(0, pending.count - 1) }

    /// One event from the socket. `reply` is non-nil only for held events; the model owns it from here.
    public func receive(_ e: AgentHookEvent, reply: ((String?) -> Void)? = nil) {
        let now = clock()
        let before = registry.sessions[e.sessionID]?.state
        registry.apply(e)
        if e.name == "SessionEnd" { resolveSession(sessionID: e.sessionID, line: nil) }
        if e.held, let reply {
            let a = AgentApproval(event: e, receivedAt: now)
            if isPresenting() {
                reply(nil)   // instant pass-through: the terminal prompt appears within a second
                registry.clearActionable(sessionID: e.sessionID)
                logger?.log("agents approval=passthrough-presenting")
            } else {
                resolvers[a.id] = reply
                pending.append(a)
                logger?.log("agents approval=held kind=\(a.kind.rawValue)")
                onHeldRequest?(a)
            }
        }
        publish()
        let after = registry.sessions[e.sessionID]?.state
        if after != before, let after { logger?.log("agents state=\(after.rawValue) sessions=\(registry.sessions.count)") }
    }

    /// A card button. Answering (or choosing the terminal) resolves the held connection exactly once.
    public func decide(_ a: AgentApproval, _ d: AgentDecision) {
        guard let reply = resolvers.removeValue(forKey: a.id) else { return }
        pending.removeAll { $0.id == a.id }
        registry.clearActionable(sessionID: a.sessionID)
        reply(d.replyLine(for: a.kind))
        logger?.log("agents approval=decided kind=\(a.kind.rawValue)")
        publish()
    }

    /// The relay went away (EOF) or the server dropped the connection: forget the request without
    /// replying — there is nothing left to answer.
    public func dropHeld(id: String) {
        guard resolvers.removeValue(forKey: id) != nil else { return }
        if let a = pending.first(where: { $0.id == id }) { registry.clearActionable(sessionID: a.sessionID) }
        pending.removeAll { $0.id == id }
        publish()
    }

    /// Presenting turned on mid-hold: every held request falls back to its terminal prompt now.
    public func cancelAllHeld() {
        for a in pending { resolvers[a.id]?(nil); registry.clearActionable(sessionID: a.sessionID) }
        resolvers.removeAll(); pending.removeAll()
        publish()
    }

    /// The clock tick (Peek's 30 s refresh, plus the card's own countdown): expire held requests past
    /// their deadline — reply nil, the terminal asks — and run the registry sweeps. An expiry is a
    /// lapse: it is journaled, so a sleep window that spans it can recap "approval lapsed".
    public func tick() {
        let now = clock()
        for a in pending where now >= a.deadline {
            resolvers.removeValue(forKey: a.id)?(nil)
            registry.clearActionable(sessionID: a.sessionID)
            registry.noteApprovalLapsed(folder: a.folder, tmuxLabel: a.tmuxLabel, at: now)
            logger?.log("agents approval=expired kind=\(a.kind.rawValue)")
        }
        pending.removeAll { now >= $0.deadline }
        registry.sweep(now: now)
        publish()
    }

    /// The card model woke from a sleep window: assemble the recap over it. Nothing happened →
    /// recap stays nil and no card ever shows. A recap already waiting is replaced by the newer one.
    public func presentRecap(from: Date, to: Date) {
        recap = registry.recap(from: from, to: to)
        if let r = recap { logger?.log("agents recap lines=\(r.lines.count)") }
    }

    /// The recap card's Dismiss: shown once, then gone (the next wake assembles a fresh one).
    public func dismissRecap() { recap = nil }

    private func resolveSession(sessionID: String, line: String?) {
        for a in pending where a.sessionID == sessionID { resolvers.removeValue(forKey: a.id)?(line) }
        pending.removeAll { $0.sessionID == sessionID }
    }

    private func publish() {
        sessions = registry.ordered
        stuck = registry.stuckSession
        lastFinish = registry.lastFinish
        pillLine = AgentPillLineBuilder.build(stuck: stuck, lastFinish: lastFinish, now: clock())
        // Log a stuck flag once per episode: the registry latch does the once-only, this just
        // records the moment the surfaced stuck session changes (or clears).
        if stuck?.sessionID != loggedStuckID {
            if let s = stuck { logger?.log("agents stuck folder=\(s.folder)") }
            loggedStuckID = stuck?.sessionID
        }
    }
}

import Foundation

/// The live coaching checklist: read → technique → execution → finishing, checked off as the
/// meeting covers each stage. Local to Peek only — nothing here reads, writes or sends anything.
/// The meeting itself is found without naming a client: the live Command booking is the
/// `gpu_window` span (source "command") containing now, plus `live` (Command live on this Mac).
/// That makes the checklist presenting-safe by construction: stages and times only, never a name.
///
/// The nudge: at 10:00 remaining the notch expands itself with the uncovered stages as a ranked
/// parking lot; picking one marks it "Closing on this". It fires once per live span; the app
/// decides whether to expand (Peek hidden stays hidden — the lot is still there when it opens).
/// Dismissing the lot holds for that span.
public enum ChecklistStage: String, Sendable, CaseIterable, Identifiable {
    case read, technique, execution, finishing
    public var id: String { rawValue }
    /// The stage word on the grid tile.
    public var label: String {
        switch self {
        case .read: return "READ"
        case .technique: return "TECHNIQUE"
        case .execution: return "EXECUTION"
        case .finishing: return "FINISHING"
        }
    }
    /// The short word in the collapsed pill line.
    public var short: String {
        switch self {
        case .read: return "READ"
        case .technique: return "TECH"
        case .execution: return "EXEC"
        case .finishing: return "FIN"
        }
    }
}

/// Pure timing over the gpu_window spans. A span is the live meeting when it is a Command booking
/// (source "command") and contains now.
public enum MeetingClock {
    public static func liveSpan(spans: [GPUSpan], now: Date) -> GPUSpan? {
        spans.first { $0.source == "command" && $0.start <= now && now <= $0.end }
    }

    public static func isLive(commandLive: Bool, span: GPUSpan?, now: Date) -> Bool {
        commandLive && span != nil
    }

    public static func elapsedSeconds(span: GPUSpan, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(span.start))
    }

    public static func remainingSeconds(span: GPUSpan, now: Date) -> TimeInterval {
        max(0, span.end.timeIntervalSince(now))
    }

    /// "38:12" (minutes:seconds, no hours — a session is an hour).
    public static func elapsedText(span: GPUSpan, now: Date) -> String {
        let s = Int(elapsedSeconds(span: span, now: now))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "07:32" for the nudge header.
    public static func remainingText(span: GPUSpan, now: Date) -> String {
        let s = Int(remainingSeconds(span: span, now: now))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// The nudge is due in the last 10 minutes of the meeting, while it is still running.
    public static let nudgeThresholdSeconds: TimeInterval = 600
    public static func nudgeDue(span: GPUSpan, now: Date) -> Bool {
        let r = remainingSeconds(span: span, now: now)
        return r > 0 && r <= nudgeThresholdSeconds
    }
}

@MainActor public final class MeetingChecklistModel: ObservableObject {
    public enum Nudge: Equatable, Sendable { case none, fire }

    @Published public private(set) var covered: Set<ChecklistStage> = []
    @Published public private(set) var closing: ChecklistStage? = nil
    @Published public private(set) var nudgeShown = false
    @Published public private(set) var liveSpan: GPUSpan? = nil
    @Published public private(set) var commandLive = false
    private var nudgeFiredFor: String? = nil
    private var nudgeDismissedFor: String? = nil

    public init() {}

    /// The live span's identity: state resets when the meeting changes.
    static func key(_ span: GPUSpan) -> String { "\(span.start.timeIntervalSince1970)-\(span.end.timeIntervalSince1970)" }
    var spanKey: String? { liveSpan.map(Self.key) }

    public func isLive(now: Date = Date()) -> Bool { MeetingClock.isLive(commandLive: commandLive, span: liveSpan, now: now) }
    public func elapsedText(now: Date = Date()) -> String? {
        guard let s = liveSpan else { return nil }
        return MeetingClock.elapsedText(span: s, now: now)
    }
    public func remainingSeconds(now: Date = Date()) -> TimeInterval? {
        guard let s = liveSpan else { return nil }
        return MeetingClock.remainingSeconds(span: s, now: now)
    }

    /// The collapsed pill line: elapsed time plus one mark per stage (covered ✓, first uncovered ●,
    /// later stages ○). No client name, so it may show while presenting.
    public func collapsedText(now: Date = Date()) -> String? {
        guard let s = liveSpan, isLive(now: now) else { return nil }
        let firstUncovered = ChecklistStage.allCases.first { !covered.contains($0) }
        let marks = ChecklistStage.allCases.map { stage -> String in
            if covered.contains(stage) { return "\(stage.short) ✓" }
            return stage == firstUncovered ? "\(stage.short) ●" : "\(stage.short) ○"
        }.joined(separator: " · ")
        return "\(MeetingClock.elapsedText(span: s, now: now)) · \(marks)"
    }

    /// The parking lot: uncovered stages, in coaching order. The nudge ranks exactly this.
    public var parkingLot: [ChecklistStage] { ChecklistStage.allCases.filter { !covered.contains($0) } }

    /// One refresh-tick call. Returns `.fire` once, when the nudge is due for this span and has not
    /// fired yet; the app expands the notch then. `nudgeShown` is set when due (unless the coach
    /// dismissed it for this span), even when the app cannot expand, so the lot is there when the
    /// coach opens Peek.
    @discardableResult
    public func update(spans: [GPUSpan], live: Bool, now: Date = Date()) -> Nudge {
        commandLive = live
        let span = live ? MeetingClock.liveSpan(spans: spans, now: now) : nil
        if span?.start != liveSpan?.start || span?.end != liveSpan?.end {
            liveSpan = span
            covered = []
            closing = nil
            nudgeShown = false
            nudgeFiredFor = nil
            nudgeDismissedFor = nil
        } else {
            liveSpan = span
        }
        guard let s = liveSpan, MeetingClock.nudgeDue(span: s, now: now) else { return .none }
        if nudgeDismissedFor != spanKey { nudgeShown = true }
        guard nudgeFiredFor != spanKey else { return .none }
        nudgeFiredFor = spanKey
        return .fire
    }

    public func toggle(_ stage: ChecklistStage) {
        if covered.contains(stage) { covered.remove(stage) } else { covered.insert(stage) }
        if closing == stage, !covered.contains(stage) { closing = nil }
    }

    /// The parking-lot pick: this stage is what the meeting closes on. It stays uncovered until
    /// the coach taps its tile.
    public func closeOn(_ stage: ChecklistStage) { closing = stage }

    /// Dismissed for this span: later ticks must not re-show it.
    public func dismissNudge() { nudgeShown = false; nudgeDismissedFor = spanKey }
}

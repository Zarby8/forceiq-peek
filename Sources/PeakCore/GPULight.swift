import Foundation

// ForceIQ Peek 5090 light (Chris 10.19.2026). A small dot: RED from 2 h before a meeting through its end (a meeting in
// progress included: Command live on this Mac, or a calendar / booking span that has started and not ended), GREEN
// otherwise. The bookings read is upcoming-only, so Command's live status AND the calendar must both be readable and
// fresh, or the light is UNKNOWN. UNKNOWN (the meeting status is missing, unreadable or STALE) is drawn red, labelled, and holds GPU work:
// it fails closed. While it isn't green, Peek refuses EVERY 5090 GPU action (the shifts / upscale drop zone, a 3PO
// proposal or a GOAT approval that would upscale) with one plain message.
// Source: GET /api/peak/next-meeting `gpu_window` (engine/peakmeeting.py: the Command bookings read Peek already makes
// every 30 s, Command live on this Mac, the calendar the 5090 meeting guard reads). Status reads only: Peek never talks
// to the 5090, its recording service, the service that guards it, or the recorder machine.

/// One time span the 5090 must hold around (a Command booking or a calendar event; times only, never a name).
public struct GPUSpan: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let source: String
    public init(start: Date, end: Date, source: String) { self.start = start; self.end = end; self.source = source }
}

/// `gpu_window` as the engine sent it. `live` nil = Command's live state wasn't read (unknown, never "not live").
/// `calendarAt`: when the calendar snapshot was fetched (judged STALE by Peek's clock); nil with `calendarIssue` = the
/// calendar couldn't be trusted (unknown, never "a clear day"). The default is unknown: fail closed.
public struct GPUWindow: Equatable, Sendable {
    public let spans: [GPUSpan]
    public let live: Bool?
    public let calendarAt: Date?
    public let calendarIssue: String?
    public init(spans: [GPUSpan], live: Bool?, calendarAt: Date? = nil, calendarIssue: String? = nil) {
        self.spans = spans; self.live = live; self.calendarAt = calendarAt; self.calendarIssue = calendarIssue
    }

    /// nil when the doc has no usable gpu_window (an old engine, an error doc): Peek then shows UNKNOWN.
    public static func parse(_ o: [String: Any]) -> GPUWindow? {
        guard (o["ok"] as? Bool) == true, let w = o["gpu_window"] as? [String: Any], let raw = w["spans"] as? [Any] else { return nil }
        var spans: [GPUSpan] = []
        for r in raw {
            guard let d = r as? [String: Any], let s = EngineParse.date(EngineParse.str(d["start"])),
                  let e = EngineParse.date(EngineParse.str(d["end"])) else { return nil }      // one bad span: don't guess
            spans.append(GPUSpan(start: s, end: max(s, e), source: EngineParse.str(d["source"])))
        }
        let calOK = ((w["sources"] as? [String: Any])?["calendar"] as? String) == "ok"
        let calAt = calOK ? EngineParse.date(EngineParse.str(w["calendar_at"])) : nil
        let issue = ((w["calendar_issue"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)   // JSON null → none
        return GPUWindow(spans: spans.sorted { $0.start < $1.start }, live: w["live"] as? Bool, calendarAt: calAt,
                         calendarIssue: calAt != nil ? nil : (issue.isEmpty ? "calendar status unavailable" : issue))
    }
}

public enum GPULightState: Equatable, Sendable {
    case green
    case red(String)          // a meeting in progress or within 2 h: the reason in plain words
    case unknown(String)      // status missing / unreadable / STALE: drawn red, labelled, holds GPU work

    public var holdsGPU: Bool { self != .green }
    /// For logs: the state only, never a time or a reason.
    public var name: String { switch self { case .green: return "green"; case .red: return "red"; case .unknown: return "unknown" } }
    /// The dot is red for both red and unknown (fail closed).
    public var dotHex: UInt32 { self == .green ? Brand.greenHex : Brand.redHex }
    /// The short label beside the dot (pure white text).
    public var label: String {
        switch self {
        case .green: return "5090 free"
        case .red(let r): return "5090 held · \(r)"
        case .unknown(let r): return "5090 held · unknown: \(r)"
        }
    }
}

public enum GPULight {
    /// A meeting that starts within this holds the 5090.
    public static let window: TimeInterval = 2 * 3600
    /// The same threshold as the engine's threepo_clock (reading_stale_after_s): older status is STALE → unknown.
    public static let staleAfter: TimeInterval = BriefClock.staleAfter
    /// The calendar snapshot (state/eventkit.json `fetched_at`) goes STALE on the same rule: older → unknown → held.
    public static let calendarStaleAfter: TimeInterval = BriefClock.staleAfter

    /// Pure: the light for a gpu_window read at `readAt`, judged at `now` (Peek's own clock, so a meeting that slides
    /// inside 2 h turns the light red without a new read).
    public static func evaluate(_ w: GPUWindow?, readAt: Date?, now: Date, tz: TimeZone = BriefClock.zone) -> GPULightState {
        guard let w, let readAt else { return .unknown("meeting status unavailable") }
        let age = now.timeIntervalSince(readAt)
        if age > staleAfter { return .unknown("meeting status \(BriefClock.staleLabel(readAt, now: now, tz: tz))") }
        // 1. A meeting in progress (a span that has started and not ended), named by when it started.
        if let s = w.spans.filter({ $0.start <= now && $0.end > now }).min(by: { $0.start < $1.start }) {
            return .red("meeting in progress (started \(BriefClock.time(s.start, tz: tz)))")
        }
        // 2. Command is live on this Mac (a session the upcoming-only bookings read can't show).
        if w.live == true { return .red("meeting in progress (Command is live on this Mac)") }
        // 3. A meeting starting within 2 h.
        if let s = w.spans.first(where: { $0.start > now && $0.start <= now.addingTimeInterval(window) }) {
            return .red("meeting at \(BriefClock.time(s.start, tz: tz))")
        }
        // 4. Nothing seen, but a source that could show a meeting in progress is unknown or STALE: held.
        if w.live == nil { return .unknown("Command's live status couldn't be read") }
        guard let cal = w.calendarAt else { return .unknown("calendar unknown: \(w.calendarIssue ?? "calendar status unavailable")") }
        if now.timeIntervalSince(cal) > calendarStaleAfter {
            return .unknown("calendar \(BriefClock.staleLabel(cal, now: now, tz: tz))")
        }
        return .green
    }
}

/// The refusal every 5090 GPU action gets while the light isn't green, and what counts as a 5090 GPU action.
public enum GPUGate {
    /// Words that mean 5090 GPU work: upscale / interpolation / the GPU retry step / the shifts drop that starts a Dagu
    /// upscale / ForceIQ Shifts add (engine/ops.py UPSCALE_STEPS + the meeting-guard callers).
    static let gpuWords = try! NSRegularExpression(
        pattern: #"(?i)(\bupscal\w*|\bgpu\w*|\b5090\b|\brife\b|\binterpolat\w*|\brealesrgan\b|shift-drop|\bfshifts\b|client-upscale|forceiq shifts add)"#)
    /// Retry / recover actions whose step decides: an empty or GPU step starts 5090 work (ops.starts_upscale).
    static let stepActions: Set<String> = ["recover", "retry_pipeline_step", "gpu_and_deliver_retry"]

    static func matches(_ s: String) -> Bool { gpuWords.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// A 3PO proposal / approval / drop is a 5090 GPU action when its action or its text names GPU work, or when it is a
    /// recover-style action with no step (or a GPU step). Fail closed: an unclear recover counts as GPU.
    public static func isGPUAction(action: String, text: String) -> Bool {
        if matches(action) || matches(text) { return true }
        let a = action.lowercased()
        guard stepActions.contains(a) else { return false }
        let step = text.range(of: #"(?i)\bstep:\s*([A-Za-z0-9_\-]+)"#, options: .regularExpression).map { String(text[$0]) } ?? ""
        return step.isEmpty || matches(step)
    }

    public static func isGPUAction(_ c: ProposalCard) -> Bool {
        isGPUAction(action: c.action, text: ([c.label, c.touches, c.reason] + c.inputs + c.outputs).joined(separator: " "))
    }

    public static func isGPUAction(_ c: PeakCard) -> Bool {
        isGPUAction(action: "", text: ([c.title, c.detail] + c.description.inputs + c.description.touches + c.description.outputs).joined(separator: " "))
    }

    /// The shifts drop clones a film into ForceIQ Shifts, whose watcher starts the Dagu upscale on the 5090.
    public static func isGPUAction(_ z: DropZone) -> Bool { z == .shift }

    /// nil when the light is green (allowed). Otherwise the one plain sentence Peek shows (and nothing runs).
    public static func refusal(_ s: GPULightState) -> String? {
        switch s {
        case .green: return nil
        case .red(let r):
            let why = r.prefix(1).uppercased() + r.dropFirst() + (r.hasPrefix("meeting at") ? ", within 2 h" : "")
            return "\(why): 5090 GPU jobs are held so the recorder isn't disturbed. Nothing ran."
        case .unknown(let r):
            return "Meeting status unknown (\(r)): 5090 GPU jobs are held until Peek can see there's no meeting within 2 h. Nothing ran."
        }
    }
}

/// The app's light: the latest gpu_window and when Peek read it. `state(now:)` re-judges against the clock, so a refusal
/// is decided at the moment of the tap, never from a cached colour.
@MainActor public final class GPULightModel: ObservableObject {
    @Published public private(set) var window: GPUWindow?
    @Published public private(set) var readAt: Date?
    @Published public private(set) var shown: GPULightState = .unknown("meeting status unavailable")
    public var clock: () -> Date = Date.init
    weak var logger: PeakLogging?
    public init(logger: PeakLogging? = nil) { self.logger = logger }

    /// A fresh next-meeting read. A failed read keeps the last window and its read time (it goes STALE on its own).
    public func update(_ w: GPUWindow?, at t: Date) {
        if let w { window = w; readAt = t }
        refresh()
    }

    public func state(now: Date? = nil) -> GPULightState { GPULight.evaluate(window, readAt: readAt, now: now ?? clock()) }

    /// Re-judge the dot (called on every 30 s feed tick and on each GPU tap).
    public func refresh() {
        let s = state()
        if s != shown { shown = s; logger?.log("gpu light=\(s.name)") }
    }

    /// The gate a GPU action calls at tap time: nil = allowed (green), else the refusal text.
    public func hold() -> String? {
        let s = state()
        if s != shown { shown = s }
        return GPUGate.refusal(s)
    }
}

/// next-meeting `recording`: is Command recording the live meeting right now (a RecordingOperation row
/// in an active status for the live booking's room, judged engine-side). Peek's recording DND follows
/// it exactly: true = recording, false = not recording, absent / not a bool = unknown (nil: no change).
public enum RecordingSignal {
    public static func parse(_ o: [String: Any]) -> Bool? {
        guard (o["ok"] as? Bool) == true else { return nil }
        return o["recording"] as? Bool
    }
}

import Foundation
import Combine

// ───────────────────────────── seams (picks drop in behind these) ─────────────────────────────
/// The global hotkey (app side: KeyboardShortcuts 3.1.0; tests: a fake).
@MainActor public protocol HotkeyRegistering: AnyObject {
    func register(_ onPress: @escaping @MainActor () -> Void)
    func unregister()
}

/// Performs a card action that Peek allowed (app side: GOAT engine on 127.0.0.1, NSWorkspace, pasteboard).
@MainActor public protocol CardActionPerforming: AnyObject {
    func perform(_ action: CardAction, on card: PeakCard) async -> String
    /// Did the last perform() actually succeed (drives the approval pop; never a guess from the text)?
    var lastOK: Bool { get }
}
extension CardActionPerforming { public var lastOK: Bool { true } }

/// Log: the action / state name only, never a URL query, client text or prompt.
@MainActor public protocol PeakLogging: AnyObject {
    func log(_ event: String)
}

// ───────────────────────────── visibility / expansion ─────────────────────────────
@MainActor public final class PeakController: ObservableObject {
    @Published public private(set) var globallyVisible: Bool
    @Published public private(set) var expanded = false
    @Published public private(set) var askText: String? = nil       // non-nil: the ask field is open, prefilled (never sent)
    /// Bumped on every ask link, so a link that arrives while the panel is already open still lands (views key off it).
    @Published public private(set) var askSeq = 0
    /// An ask link's text for 3PO's field (wireAsk). Called on every link, open or collapsed; it only prefills.
    public var onAsk: ((String) -> Void)?
    @Published public private(set) var hotkeyEnabled: Bool
    @Published public private(set) var shownDisplays: [String: Bool] = [:]
    /// The one display whose panel expands (the one under the pointer, or the one the user hovered).
    @Published public var activeDisplay: String? = nil
    public let prefs: PeakPrefs
    public let profile: CoachProfile
    let hotkey: HotkeyRegistering
    weak var logger: PeakLogging?
    public var onSwitchApp: ((String) -> Void)?
    public var onModelPick: ((ModelPick) -> Void)?
    public var onVoiceToggle: (() -> Void)?
    public enum Tab: String, Sendable { case home, threePO = "3po" }
    @Published public var tab: Tab = .home
    /// An alert peeking out of the notch (AlertPolicy decides; this only holds it for `holdSeconds`, then retracts it).
    @Published public private(set) var peek: PeakAlert? = nil
    @Published public private(set) var peekDisplay: String? = nil
    /// Recording DND: Command is recording a meeting — Peek is fully dark (no panel on any display,
    /// no peek, no expansion) until the recording stops. Driven by RecordingDNDTracker off the
    /// next-meeting feed's `recording` field; NOT persisted (a feed read re-decides it).
    @Published public private(set) var recordingDND = false
    private var recordingTracker = RecordingDNDTracker()
    /// Presenting mode: nothing client-private on screen (Presenting.swift). Persisted in settings.json.
    @Published public private(set) var presenting: Bool
    /// True while presenting only because Command is live (not turned on by hand).
    @Published public private(set) var presentingAuto = false
    private var manualPresenting: Bool
    private var commandLive = false
    private var autoSuppressed = false              // the coach turned presenting off during this meeting
    /// A tap on the peek: the app opens whatever the alert is about (a meeting alert opens the next-session card).
    public var onPeekOpen: ((PeakAlert) -> Void)?
    /// The alert's button (Start / Review): the app does the one action for that card, and gets the display it dropped on.
    public var onPeekAction: ((PeakAlert, String?) -> Void)?
    private var peekTask: Task<Void, Never>?

    public init(prefs: PeakPrefs, profile: CoachProfile, hotkey: HotkeyRegistering, logger: PeakLogging? = nil) {
        self.prefs = prefs; self.profile = profile; self.hotkey = hotkey; self.logger = logger
        globallyVisible = !prefs.globallyHidden
        manualPresenting = prefs.presenting
        presenting = prefs.presenting
        hotkeyEnabled = prefs.builtInHotkeyEnabled(default: profile.hotkey.enabled)
        if hotkeyEnabled { hotkey.register { [weak self] in self?.hotkeyPressed() } }
    }

    public func hotkeyPressed() { log("hotkey"); toggle() }

    public func toggle() { globallyVisible ? hide() : show() }
    public func show() { globallyVisible = true; prefs.globallyHidden = false; log("state visible=on") }
    public func hide() { dismissPeek(); globallyVisible = false; expanded = false; prefs.globallyHidden = true; log("state visible=off") }
    /// Expansion is refused while recording DND is on: Peek stays dark until the recording stops.
    /// (The expanded state itself is preserved across a dark period — DND only hides the panels.)
    public func expand() { guard !recordingDND else { return }; if !globallyVisible { show() }; dismissPeek(); guard !expanded else { return }; expanded = true; log("state expanded=on") }
    public func collapse() { guard expanded else { return }; expanded = false; askText = nil; log("state expanded=off") }

    /// Drop an alert out of the notch on `display`. Only a visible, collapsed Peek shows one; it retracts by itself.
    public func showPeek(_ a: PeakAlert, on display: String?) {
        guard globallyVisible, !expanded, !recordingDND else { return }
        let a = presenting ? Presenting.redact(a) : a
        peek = a; peekDisplay = display
        log("state peek=\(a.kind.rawValue)")
        schedulePeekRetract(a.holdSeconds)
    }
    /// The pointer is on the peek: give the coach a few more seconds to read it.
    public func extendPeek(seconds: Double = 3) { guard peek != nil else { return }; schedulePeekRetract(seconds) }
    public func dismissPeek() {
        peekTask?.cancel(); peekTask = nil
        guard peek != nil else { return }
        peek = nil; peekDisplay = nil; log("state peek=off")
    }
    /// A tap on the peek opens the sheet on the display it dropped on, then hands the alert to the app.
    public func openPeek() {
        guard let a = peek else { expand(); return }
        if let d = peekDisplay { activeDisplay = d }
        expand(); onPeekOpen?(a)
    }
    /// The peek's button. Only an alert that carries an action does anything; the peek retracts first.
    public func performPeekAction() {
        guard let a = peek, a.action != .none else { return }
        let display = peekDisplay
        dismissPeek()
        log("state peek-action=\(a.action.rawValue)")
        onPeekAction?(a, display)
    }
    private func schedulePeekRetract(_ seconds: Double) {
        peekTask?.cancel()
        let id = peek?.id
        peekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.peek?.id == id else { return }
            self.dismissPeek()
        }
    }

    /// Turn presenting mode on or off by hand (menu, Show details). On is sticky (persisted); off during a Command meeting stays
    /// off until that meeting ends. Turning it on clears anything client-private that is already showing.
    public func setPresenting(_ on: Bool) {
        if on { manualPresenting = true; autoSuppressed = false }
        else { manualPresenting = false; if prefs.autoPresenting && commandLive { autoSuppressed = true } }
        prefs.presenting = manualPresenting
        applyPresenting()
    }

    /// Do not disturb from the menu or Settings: alerts stop peeking until then (the cards are still on the sheet).
    public func setDoNotDisturb(_ choice: DoNotDisturbChoice, now: Date = Date(), calendar: Calendar = .current) {
        switch choice {
        case .oneHour: prefs.dndUntil = now.addingTimeInterval(3600)
        case .tomorrowMorning: prefs.dndUntil = DoNotDisturb.tomorrowMorning(after: now, calendar: calendar)
        case .off: prefs.dndUntil = nil
        }
        dismissPeek()
        log("state dnd=\(choice == .off ? "off" : "on")")
    }

    /// The next-meeting feed's `recording` from each read (nil = unknown: no change). Engaging hides
    /// every panel (panelVisible goes false) and drops any peek; the expanded state is left as it was,
    /// so when the recording stops the panel returns exactly as it was.
    public func setRecording(_ recording: Bool?, meetingEnd: Date?, now: Date = Date()) {
        let on = recordingTracker.update(recording: recording, meetingEnd: meetingEnd, now: now)
        guard on != recordingDND else { return }
        recordingDND = on
        if on { dismissPeek() }
        log("state recording-dnd=\(on ? "on" : "off")")
    }

    /// GOAT's `gpu_window.live` from each feed read: Command is live on this Mac (nil = unreadable: nothing changes).
    public func setCommandLive(_ live: Bool?) {
        guard let live, live != commandLive else { return }
        commandLive = live
        if !live { autoSuppressed = false }
        applyPresenting()
    }

    /// Re-judge presenting after a setting that feeds it changed (Settings: auto-presenting).
    public func reevaluatePresenting() { applyPresenting() }

    private func applyPresenting() {
        let p = PresentingPolicy.effective(manual: manualPresenting, autoEnabled: prefs.autoPresenting, commandLive: commandLive, suppressed: autoSuppressed)
        presentingAuto = p && !manualPresenting
        guard p != presenting else { return }
        presenting = p
        if p { dismissPeek(); closeAsk(); tab = .home }
        log("state presenting=\(p ? "on" : "off")\(p && presentingAuto ? " reason=command-live" : "")")
    }

    /// Opens the ask field prefilled (3PO's input when the 3PO module is on). Nothing is ever sent from here.
    public func openAsk(_ prefill: String?) {
        expand(); askText = prefill ?? ""; askSeq += 1
        if profile.isEnabled(.threePO) { tab = .threePO; onAsk?(prefill ?? "") }
        log("state ask=open")
    }
    /// The ask link → 3PO's field, directly on the store (not on a view's onAppear, which never re-runs while the chat is
    /// already showing). Prefill only: nothing is sent.
    public func wireAsk(to store: ThreePOStore) { onAsk = { [weak store] q in store?.prefill(q) } }
    public func closeAsk() { askText = nil }

    public func setHotkeyEnabled(_ on: Bool) {
        guard on != hotkeyEnabled else { return }
        hotkeyEnabled = on
        prefs.setBuiltInHotkeyEnabled(on)
        if on { hotkey.register { [weak self] in self?.hotkeyPressed() } } else { hotkey.unregister() }
        log("state hotkey=\(on ? "on" : "off")")
    }

    public func isDisplayShown(_ uuid: String) -> Bool { prefs.isDisplayShown(uuid) }
    public func setDisplay(_ uuid: String, shown: Bool) {
        prefs.setDisplay(uuid, shown: shown)
        shownDisplays[uuid.uppercased()] = shown
        log("state display=\(shown ? "on" : "off")")
    }
    /// Is the panel on this display visible right now? Recording DND darkens every display.
    public func panelVisible(on uuid: String) -> Bool { globallyVisible && !recordingDND && prefs.isDisplayShown(uuid) }

    public func handle(_ a: PeakURLAction) {
        guard ModuleRegistry.allows(a, profile) else { log("url \(a.name) refused=module-off"); return }
        log("url \(a.name)")
        switch a {
        case .toggle: toggle()
        case .show: show()
        case .hide: hide()
        case .expand: expand()
        case .collapse: collapse()
        case .ask(let q): openAsk(q)
        case .switchApp(let id): onSwitchApp?(id); log("state switch")
        case .display(let uuid, let on): setDisplay(uuid, shown: on)
        case .threePOModel(let p): onModelPick?(p)
        case .voice: onVoiceToggle?()
        }
    }

    func log(_ s: String) { logger?.log(s) }
}

// ───────────────────────────── cards: tap → description → explicit action ─────────────────────────────
@MainActor public final class CardStackViewModel: ObservableObject {
    public enum Phase: Equatable { case list, describing(String) }
    @Published public private(set) var cards: [PeakCard] = []
    @Published public private(set) var unnamed = 0
    @Published public private(set) var pipelineHidden = 0
    @Published public private(set) var phase: Phase = .list
    @Published public private(set) var configured = true
    @Published public private(set) var lastResult: String? = nil
    @Published public private(set) var ghost: GhostState = .idle
    // Stage 5: the needs-you faults (latched — a persistent fault never re-nags), the money line
    // (nil until an invoice is past due), tonight's games line (evening pill default), tile readouts.
    @Published public private(set) var needsYou: [NeedsYouFault] = []
    @Published public private(set) var moneyLine: String? = nil
    @Published public private(set) var tonightText: String? = nil
    /// Stage 6: "Shane is meeting with {client}" while the other coach's session is live (else nil).
    @Published public private(set) var presenceLine: String? = nil
    @Published public private(set) var tileReadouts = TileReadouts()
    private var faultLatch = FaultLatch()
    @Published public private(set) var progress = LiveProgress.idle   // the thin gold line under the notch
    @Published public private(set) var approvedPops = 0            // trigger: an approval / run went through (green check pop)
    /// "Settings file couldn't be read: using defaults" while settings.json couldn't be used (PeakPrefs.settingsNotice).
    @Published public var settingsNotice: String? = nil
    private var baseGhost: GhostState = .idle
    /// Seconds of complete inactivity before the mark sleeps (GhostState.sleeping). Complete inactivity:
    /// the snapshot says idle (no engine work, no attention, no error), no live meeting, no chat/typing
    /// or receipt on the mark, and the watcher reports no active Claude session and no held approval
    /// (agentsActive, wired by the app; false when the agents module is off). Any activity restarts the
    /// clock; the next update after activity wakes the mark back to the data state.
    public static let sleepAfter: TimeInterval = 10 * 60
    /// The wall clock, injected like AgentWatchModel's so the sleep transition is unit-testable.
    public var clock: () -> Date = Date.init
    /// Watcher activity (an agent session working/waiting, or a held approval pending).
    public var agentsActive: () -> Bool = { false }
    /// A flagged stuck agent (the watcher's stuck latch): an otherwise-idle mark escalates to
    /// attention while one is flagged. A stuck session is by definition working, so in the app's
    /// wiring this always implies agentsActive too — it is counted as activity either way.
    public var agentsAttention: () -> Bool = { false }
    /// Fired once per sleep episode when the mark wakes, carrying the sleep window (start, wake):
    /// the app assembles the while-you-were-away recap over exactly this window.
    public var onWakeFromSleep: ((Date, Date) -> Void)?
    private var sleepingSince: Date? = nil
    private var lastActivityAt: Date? = nil
    let performer: CardActionPerforming
    weak var logger: PeakLogging?

    /// "Command sign-in expired, tap to sign in" (not a card: it names no client). Its tap only asks GOAT.
    public let signIn: CommandSignInModel
    /// The 5090 light's gate (GPULightModel.hold): Run on an approval that is 5090 GPU work is refused while it isn't green.
    public var gpuHold: (() -> String?)?

    public init(performer: CardActionPerforming, logger: PeakLogging? = nil, signInTransport: CommandSignInTransport? = nil) {
        self.performer = performer; self.logger = logger
        self.signIn = CommandSignInModel(transport: signInTransport, logger: logger)
    }

    public func update(_ s: EngineSnapshot, profile: CoachProfile) {
        signIn.update(profile.configured ? s.commandSignIn : nil)
        let r = ModuleRegistry.build(s, profile)
        configured = profile.configured
        cards = r.cards; unnamed = r.unnamed; pipelineHidden = r.pipelineHidden
        baseGhost = GhostState.from(s)
        progress = LiveProgress(s)
        let now = clock()
        // Stage 5 surfaces, all from this same snapshot: faults latch through the one needs-you
        // mechanism; the money line exists only while something is past due; tonight's line only
        // once every session today has ended (the idle-evening default).
        let latched = faultLatch.update(NeedsYou.faults(from: s, now: now))
        needsYou = latched.current
        for f in latched.fresh { logger?.log("state needs-you \(f.id)") }
        moneyLine = s.money?.line
        let dayOver = (s.today ?? []).allSatisfy { $0.scheduledAt.addingTimeInterval(Double($0.durationMinutes) * 60) <= now }
        tonightText = (dayOver ? s.tonight : nil).flatMap { TonightLine.text($0, now: now) }
        tileReadouts = TileReadouts.build(from: s, now: now)
        presenceLine = s.otherCoachLive?.line
        // A meeting counts only while it is live: from 10 min before its start (Peek's own urgency
        // window) through its scheduled end. The snapshot's meeting is the NEXT one — a meeting hours
        // away must not keep the mark awake all day.
        let meetingLive = s.meeting.map {
            now >= $0.scheduledAt.addingTimeInterval(-10 * 60)
                && now <= $0.scheduledAt.addingTimeInterval(Double($0.durationMinutes) * 60)
        } ?? false
        let active = baseGhost != .idle || meetingLive || ghost == .typing || ghost == .receipt || agentsActive() || agentsAttention()
        if active || lastActivityAt == nil { lastActivityAt = now }
        if ghost != .typing && ghost != .receipt {
            var next: GhostState = (!active && now.timeIntervalSince(lastActivityAt ?? now) >= Self.sleepAfter) ? .sleeping : baseGhost
            // A flagged stuck agent escalates an otherwise-idle mark to attention (the waiting
            // pose): the stall needs the coach's eye even though the engine has nothing to say.
            if next == .idle && agentsAttention() { next = .attention }
            applyGhost(next, at: now)
        }
        if case .describing(let id) = phase, !cards.contains(where: { $0.id == id }) { phase = .list }
    }

    public var describedCard: PeakCard? {
        if case .describing(let id) = phase { return cards.first { $0.id == id } }
        return nil
    }

    /// Every sleep-overlay transition goes through here, so the sleep window is tracked exactly:
    /// entering .sleeping opens the window; leaving it fires onWakeFromSleep once with the window.
    private func applyGhost(_ next: GhostState, at now: Date) {
        if ghost == .sleeping, next != .sleeping {
            if let since = sleepingSince { onWakeFromSleep?(since, now) }
            sleepingSince = nil
        } else if next == .sleeping, ghost != .sleeping {
            sleepingSince = now
        }
        ghost = next
    }

    /// A user action: the sleep clock restarts, and a sleeping mark wakes to the data state at once
    /// rather than waiting for the next feed read.
    private func noteActivity() {
        lastActivityAt = clock()
        if ghost == .sleeping {
            applyGhost(baseGhost == .idle && agentsAttention() ? .attention : baseGhost, at: clock())
        }
    }

    /// A tap on a card ONLY shows its plain description. It never runs anything.
    public func tap(_ card: PeakCard) {
        noteActivity()
        phase = .describing(card.id)
        lastResult = nil
        logger?.log("card describe kind=\(card.kind.rawValue)")
    }

    public func back() { noteActivity(); phase = .list; lastResult = nil }

    /// The receipt one-shot finished: back to what the data says.
    public func ghostOneShotFinished() { if ghost == .receipt { ghost = baseGhost } }

    /// The only path to an action: an explicit button tap, on the card whose description is showing, and allowed by policy.
    @discardableResult
    public func choose(_ action: CardAction) async -> Bool {
        noteActivity()
        guard let card = describedCard else { return false }
        guard CardPolicy.isAllowed(action, on: card) else {
            lastResult = card.viewOnlyReason ?? "Not available from Peek."
            logger?.log("card refused kind=\(card.kind.rawValue)")
            return false
        }
        if action == .run, GPUGate.isGPUAction(card), let why = gpuHold?() {
            lastResult = why
            logger?.log("card refused=gpu-hold kind=\(card.kind.rawValue)")
            return false
        }
        logger?.log("card action kind=\(card.kind.rawValue) action=\(Self.name(action))")
        if action == .askClaude { ghost = .typing }
        lastResult = await performer.perform(action, on: card)
        if action == .run && performer.lastOK { approvedPops += 1 }
        ghost = .receipt                      // one-shot; the view hands back to the data state when it finishes
        return true
    }

    /// The peek's Start button: the meeting card's Run, once, without opening its description first (Chris approved this one
    /// exception: Run only opens Command's room page, and Join and Record stay taps inside Command). Meeting cards only, never a
    /// view-only card, never an approval or fix.
    @discardableResult
    public func quickStart(_ card: PeakCard) async -> Bool {
        noteActivity()
        guard card.kind == .meeting, CardPolicy.isAllowed(.run, on: card) else {
            logger?.log("card quick-start refused kind=\(card.kind.rawValue)")
            return false
        }
        logger?.log("card quick-start kind=meeting")
        lastResult = await performer.perform(.run, on: card)
        if performer.lastOK { approvedPops += 1 }
        return true
    }

    static func name(_ a: CardAction) -> String {
        switch a {
        case .run: return "run"
        case .askClaude: return "ask"
        case .copyPrompt: return "copy-prompt"
        case .openInGOAT: return "open-goat"
        case .openInCommand: return "open-command"
        case .openURL: return "open-url"
        case .copyLink: return "copy-link"
        }
    }
}

// ───────────────────────────── countdown ─────────────────────────────
public enum Countdown {
    public static func text(to start: Date, now: Date) -> String {
        let s = Int(start.timeIntervalSince(now).rounded())
        if s <= 0 { return s > -15 * 60 ? "Started \((-s) / 60) min ago" : "Started" }
        if s < 60 { return "in \(s)s" }
        let h = s / 3600, m = (s % 3600) / 60
        if h >= 24 { return "in \(h / 24)d \(h % 24)h" }
        return h > 0 ? "in \(h)h \(m)m" : "in \(m)m \(s % 60)s"
    }
}

// ───────────────────────────── demo data (screenshots; FORCEIQ_PEAK_DEMO=1). Sample names only. ─────────────────────────────
public enum DemoData {
    /// A fake coach for screenshots and tests. No real names, apps or paths.
    public static func profile(stateRoot: String = "~/ForceIQ/peak-demo", apps: [SwitcherApp] = []) -> CoachProfile {
        var p = CoachProfile.none
        p.configured = true; p.coachID = "demo"; p.displayName = "Demo Coach"; p.stateRoot = stateRoot
        p.roster = .init(source: "fixture", names: ["Sample Skater", "Demo Player"])
        p.modules = ["meetings": true, "approvals": true, "switcher": true, "family": true, "3po": true, "spend": true, "drops": true]
        p.spend = .init(showAccountLine: true, budgetUSD: 250)
        p.apps = apps
        return p
    }

    /// The voice smoke's fake roster: two Averys for the pick card, one full name for the boost. Invented names.
    public static let voiceRoster = ["Tobias Marchetti", "Avery Kowalczyk", "Avery Lindqvist", "Sample Skater"]
    public static func voiceMeeting(now: Date = Date()) -> MeetingRow {
        MeetingRow(client: "Tobias Marchetti", scheduledAt: now.addingTimeInterval(42 * 60), durationMinutes: 60, joinURL: nil,
                   openURL: CommandLink.room(sessionID: "demo_session"))
    }

    /// `quiet`: the everyday desk (no meeting, no fixes, no approvals) so the Ghost is .idle and its ambient glow
    /// runs, as on a real coach's Mac most of the day (FORCEIQ_PEAK_DEMO_FEED=quiet; the CPU check uses it).
    /// Sample rows for the Running section (demo mode only; sample names).
    public static func runningFeed() -> RunningFeed {
        RunningFeed(rows: [
            RunningRow(id: "demo-up", lane: .upscale, stage: "running", client: "Sample Skater", what: "Demo City Rockets · 4.17", step: "RIFE interpolation",
                       percent: 24, detail: "18386 / 76559 frames", stepsDone: 11, stepsTotal: 20),
            RunningRow(id: "demo-pack", lane: .postMeeting, stage: "running", client: "Demo Player", what: "Meeting pack 10.20", step: "Write meeting summary",
                       stepsDone: 2, stepsTotal: 6),
            RunningRow(id: "demo-pack2", lane: .postMeeting, stage: "attention", client: "Sample Skater", what: "Meeting pack 10.19", step: "Waiting for Brain",
                       detail: "Published to the portal; Brain has not acknowledged it yet.", stepsDone: 5, stepsTotal: 6),
        ])
    }

    public static func snapshot(now: Date = Date(), quiet: Bool = false, meetingInMinutes: Double = 42.3) -> EngineSnapshot {
        var s = EngineSnapshot()
        if quiet { s.familyEnabled = false; return s }
        s.meeting = MeetingRow(client: "Sample Skater", scheduledAt: now.addingTimeInterval(meetingInMinutes * 60), durationMinutes: 60,
                               joinURL: nil, openURL: CommandLink.room(sessionID: "demo_session"))
        s.fixes = [FixRow(title: "Re-render crest title slide", client: "Demo Player", state: "running", message: "step 2 of 3")]
        s.fixesRunning = 0
        s.approvals = [
            ApprovalRow(id: "a1b2c3d4e5f6", kind: "proposal", kindLabel: "Claude proposal", title: "Confirm jersey #17 from the roster",
                        why: "Roster and GHOST disagree", client: "Sample Skater", gate: "routine", touches: ["GOAT client card"],
                        outputs: ["Updated client card"], actLabel: "client_confirm", test: false),
            ApprovalRow(id: "0f9e8d7c6b5a", kind: "proposal", kindLabel: "Claude proposal", title: "Send the family the meeting link",
                        why: "Family has no link", client: "Demo Player", gate: "send", touches: ["Messages"], outputs: ["A text"],
                        actLabel: "imessage", test: false),
        ]
        s.familyEnabled = false
        return s
    }

    /// A scripted 3PO turn for screenshots / the visual proof (no tokens, no network): thinking → Opus advisor → streamed
    /// text → a describe-first proposal → done. Delays in seconds.
    /// `slow` (the avatar tour): the advisor holds ~3.6 s and words land every 0.12 s.
    /// The send-latency tour's turn: ~1 s think, ~1 s of streamed text, done (no card, no advisor). `flip`: the first
    /// token, a tool, a token, a tool, … 60 ms apart (thinking ⇄ talking faster than any transition), then the stream.
    public static func threePOQuickTurn(flip: Bool = false) -> [(TimeInterval, ThreePOEvent)] {
        let words = "Fixed: the title slide now uses the home crest for Sample Skater.".split(separator: " ").map { String($0) + " " }
        var out: [(TimeInterval, ThreePOEvent)] = [(0.05, .start(route: "claude", modelAlias: "haiku", mode: "solo", cached: true))]
        var t = 1.0
        if flip {
            for i in 0..<3 { out.append((t, .delta(i == 0 ? "Checking " : ""))); out.append((t + 0.06, .toolCall("lookup"))); t += 0.12 }
        }
        for w in words { out.append((t, .delta(w))); t += 0.09 }
        out.append((t + 0.2, .done(text: "", costUSD: 0.0011, peakMTD: 12.34, warn: false, firstTokenMs: 980)))
        return out
    }

    public static func threePOTurn(slow: Bool = false) -> [(TimeInterval, ThreePOEvent)] {
        let card = ProposalCard(id: "demo0000card", action: "rerender", label: "Re-render the title slide", client: "Sample Skater",
                                inputs: ["text: Sample Skater vs Demo Hawks 10.18.2026"], touches: "Scratch render, then the client's title folder after confirm",
                                outputs: ["title.png", "folder.png"], reason: "The crest on the title slide is the opponent's.",
                                message: "Nothing has run. Run shows GOAT's preview; confirm runs it.", status: "proposed", viewOnly: false,
                                previewBody: Data(#"{"args":{},"name":"rerender"}"#.utf8), confirmBody: Data(#"{"args":{},"confirm":true,"name":"rerender"}"#.utf8))
        let words = "The title slide used the opponent's crest because the game card listed them as home. I can re-render it with the right crest; nothing runs until you tap Run and then confirm."
            .split(separator: " ").map { String($0) + " " }
        var out: [(TimeInterval, ThreePOEvent)] = [(0.2, .start(route: "claude", modelAlias: "haiku", mode: "advisor", cached: true)),
                                                    (0.9, .advisor(consulting: true)), (slow ? 4.5 : 1.6, .advisor(consulting: false))]
        let first = slow ? 4.7 : 1.8, step = slow ? 0.12 : 0.06
        for (i, w) in words.enumerated() { out.append((first + Double(i) * step, .delta(w))) }
        let t = first + Double(words.count) * step
        out.append((t + 0.2, .proposal(card)))
        out.append((t + 0.4, .done(text: "", costUSD: 0.0042, peakMTD: 12.34, warn: false, firstTokenMs: 640)))
        return out
    }
}

import Foundation
import Combine

// ───────────────────────────── seams (picks drop in behind these) ─────────────────────────────
/// The global hotkey (app side: KeyboardShortcuts 3.1.0; tests: a fake).
@MainActor public protocol HotkeyRegistering: AnyObject {
    func register(_ onPress: @escaping @MainActor () -> Void)
    func unregister()
}

/// Performs a card action that Peak allowed (app side: GOAT engine on 127.0.0.1, NSWorkspace, pasteboard).
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

    public init(prefs: PeakPrefs, profile: CoachProfile, hotkey: HotkeyRegistering, logger: PeakLogging? = nil) {
        self.prefs = prefs; self.profile = profile; self.hotkey = hotkey; self.logger = logger
        globallyVisible = !prefs.globallyHidden
        hotkeyEnabled = prefs.builtInHotkeyEnabled(default: profile.hotkey.enabled)
        if hotkeyEnabled { hotkey.register { [weak self] in self?.hotkeyPressed() } }
    }

    public func hotkeyPressed() { log("hotkey"); toggle() }

    public func toggle() { globallyVisible ? hide() : show() }
    public func show() { globallyVisible = true; prefs.globallyHidden = false; log("state visible=on") }
    public func hide() { globallyVisible = false; expanded = false; prefs.globallyHidden = true; log("state visible=off") }
    public func expand() { if !globallyVisible { show() }; guard !expanded else { return }; expanded = true; log("state expanded=on") }
    public func collapse() { guard expanded else { return }; expanded = false; askText = nil; log("state expanded=off") }

    /// Opens the ask field prefilled (3PO's input when the 3PO module is on). Nothing is ever sent from here.
    public func openAsk(_ prefill: String?) {
        expand(); askText = prefill ?? ""
        if profile.isEnabled(.threePO) { tab = .threePO }
        log("state ask=open")
    }
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
    /// Is the panel on this display visible right now?
    public func panelVisible(on uuid: String) -> Bool { globallyVisible && prefs.isDisplayShown(uuid) }

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
    @Published public private(set) var approvedPops = 0            // trigger: an approval / run went through (green check pop)
    private var baseGhost: GhostState = .idle
    let performer: CardActionPerforming
    weak var logger: PeakLogging?

    public init(performer: CardActionPerforming, logger: PeakLogging? = nil) { self.performer = performer; self.logger = logger }

    public func update(_ s: EngineSnapshot, profile: CoachProfile) {
        let r = ModuleRegistry.build(s, profile)
        configured = profile.configured
        cards = r.cards; unnamed = r.unnamed; pipelineHidden = r.pipelineHidden
        baseGhost = GhostState.from(s)
        if ghost != .typing && ghost != .receipt { ghost = baseGhost }
        if case .describing(let id) = phase, !cards.contains(where: { $0.id == id }) { phase = .list }
    }

    public var describedCard: PeakCard? {
        if case .describing(let id) = phase { return cards.first { $0.id == id } }
        return nil
    }

    /// A tap on a card ONLY shows its plain description. It never runs anything.
    public func tap(_ card: PeakCard) {
        phase = .describing(card.id)
        lastResult = nil
        logger?.log("card describe kind=\(card.kind.rawValue)")
    }

    public func back() { phase = .list; lastResult = nil }

    /// The receipt one-shot finished: back to what the data says.
    public func ghostOneShotFinished() { if ghost == .receipt { ghost = baseGhost } }

    /// The only path to an action: an explicit button tap, on the card whose description is showing, and allowed by policy.
    @discardableResult
    public func choose(_ action: CardAction) async -> Bool {
        guard let card = describedCard else { return false }
        guard CardPolicy.isAllowed(action, on: card) else {
            lastResult = card.viewOnlyReason ?? "Not available from Peak."
            logger?.log("card refused kind=\(card.kind.rawValue)")
            return false
        }
        logger?.log("card action kind=\(card.kind.rawValue) action=\(Self.name(action))")
        if action == .askClaude { ghost = .typing }
        lastResult = await performer.perform(action, on: card)
        if action == .run && performer.lastOK { approvedPops += 1 }
        ghost = .receipt                      // one-shot; the view hands back to the data state when it finishes
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
    public static func snapshot(now: Date = Date(), quiet: Bool = false) -> EngineSnapshot {
        var s = EngineSnapshot()
        if quiet { s.familyEnabled = false; return s }
        s.meeting = MeetingRow(client: "Sample Skater", scheduledAt: now.addingTimeInterval(42 * 60 + 18), durationMinutes: 60,
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

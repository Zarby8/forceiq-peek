import AppKit
import Combine
import CoreGraphics
import KeyboardShortcuts
import PeakCore
import SwiftUI

/// Non-activating, borderless panel above the menu bar, on every Space, stationary.
final class PeakPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { true }      // the ask field needs keyboard focus (the app still doesn't activate)
    override var canBecomeMain: Bool { false }
    /// Right-click (or ctrl-click) on Peek's shell, when no view under the pointer handled it: the same menu the menu-bar item
    /// used to hold (Show, Displays, Presenting, Do not disturb, Shortcut, Quit). The wing is where the menu lives now.
    var onContextMenu: ((NSEvent) -> Void)?
    override func rightMouseDown(with event: NSEvent) {
        if let f = onContextMenu { f(event) } else { super.rightMouseDown(with: event) }
    }
}

enum Screens {
    static func uuid(_ s: NSScreen) -> String {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let u = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(n.uint32Value))?.takeRetainedValue(),
              let str = CFUUIDCreateString(nil, u) as String? else { return "UNKNOWN-\(s.localizedName)" }
        return str.uppercased()
    }
    /// Demo smoke only (FORCEIQ_PEAK_DEMO=1 + FORCEIQ_PEAK_DEMO_FAKE_NOTCH=1): the main display pretends to be a 13" MacBook Pro's
    /// 250 x 43 pt notch display, so the notch layout can be drawn and checked on a Mac whose built-in display is closed.
    static var fakeNotch: Bool {
        let e = ProcessInfo.processInfo.environment
        return e["FORCEIQ_PEAK_DEMO"] == "1" && e["FORCEIQ_PEAK_DEMO_FAKE_NOTCH"] == "1"
    }
    static func descriptor(_ s: NSScreen) -> ScreenDescriptor {
        if fakeNotch, s == NSScreen.screens.first {
            let f = s.frame, w: CGFloat = 250, h: CGFloat = 43
            let left = CGRect(x: f.minX, y: f.maxY - h, width: (f.width - w) / 2, height: h)
            let right = CGRect(x: f.midX + w / 2, y: f.maxY - h, width: (f.width - w) / 2, height: h)
            return ScreenDescriptor(uuid: uuid(s), name: s.localizedName, frame: f, safeAreaTop: h, auxiliaryTopLeft: left,
                                    auxiliaryTopRight: right, menuBarHeight: s.frame.maxY - s.visibleFrame.maxY)
        }
        return ScreenDescriptor(uuid: uuid(s), name: s.localizedName, frame: s.frame, safeAreaTop: s.safeAreaInsets.top,
                         auxiliaryTopLeft: s.auxiliaryTopLeftArea, auxiliaryTopRight: s.auxiliaryTopRightArea,
                         menuBarHeight: s.frame.maxY - s.visibleFrame.maxY)
    }
}

/// One panel per NSScreen. Its frame is the FIXED canvas (PeakLayout.canvas): set once per screen layout, never per
/// animation frame. SwiftUI morphs one shell path inside it; outside the live shell the panel ignores the mouse.
@MainActor final class PanelHost {
    let uuid: String
    let panel: PeakPanel
    let state: PanelState
    var layout: PeakLayout
    var surface: PeakLayout.Surface = .collapsed

    init(screen: ScreenDescriptor, geometry: PeakGeometryProviding, root: (PanelState) -> AnyView) {
        uuid = screen.uuid
        layout = geometry.layout(for: screen)
        state = PanelState(uuid: uuid, layout: layout)
        panel = PeakPanel(frame: layout.canvas)
        let host = NSHostingView(rootView: root(state))
        host.sizingOptions = []                    // the panel frame is ours; SwiftUI never resizes the window (no thrash)
        panel.contentView = host
        panel.ignoresMouseEvents = true            // click-through until the pointer is over the live shell
    }

    func relayout(_ screen: ScreenDescriptor, geometry: PeakGeometryProviding) {
        layout = geometry.layout(for: screen)
        state.apply(layout)
        if panel.frame != layout.canvas { panel.setFrame(layout.canvas, display: true) }
    }

    /// Is this global point over the live shell (a little slack so the edge doesn't flicker)?
    func contains(_ p: NSPoint) -> Bool { layout.hitRect(surface).insetBy(dx: -2, dy: -2).contains(p) }

    func setVisible(_ on: Bool) {
        state.visible = on
        if on { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let log = FileLog(stateRoot: Session.defaultStateRoot)
    let engine = EngineClient()
    let demo = ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO"] == "1"
    let geometry: PeakGeometryProviding = PeakGeometry()
    /// The mark Peek wears (PeakMark.resolve): FORCEIQ_PEAK_MARK wins, else settings.json `mark`, else
    /// the eyes (👀). Env-only until setUp reads prefs and resolves for real; the renderer follows.
    private(set) var markSelection: PeakMark = PeakMark.resolve(env: ProcessInfo.processInfo.environment, setting: nil)
    private(set) var mark: GhostMarkRendering = EyesMarkRenderer()
    lazy var glow: GhostGlowRendering = ShaderGlowRenderer.available ? ShaderGlowRenderer() : NativeGlowRenderer()
    var profile = CoachProfile.none
    var prefs: PeakPrefs!
    var controller: PeakController!
    var performer: Performer!
    var cards: CardStackViewModel!
    var hosts: [String: PanelHost] = [:]
    var statusItem: NSStatusItem?
    var settingsModel: SettingsModel?
    var settings: NSWindow?
    var bag = Set<AnyCancellable>()
    var poll: Timer?
    var hoverCollapse: DispatchWorkItem?
    var pendingURLs: [String] = []
    var threePO: ThreePOStore!
    var drops: DropStore?
    var dropsStore: DropStore!
    var mouseMonitors: [Any] = []
    var hoveredDisplay: String?
    var demoFeedLogged = false
    var voice: VoiceController!
    var lastMeeting: MeetingRow?
    /// Notch alerts: AlertPolicy decides, the controller peeks and retracts. Gates: do-not-disturb, quiet hours, live meeting.
    var alertPolicy = AlertPolicy()
    var lastSuppressionLogged: AlertSuppression?
    /// The 5090 light (status reads only) and the "What's my day" brief (local TTS, spoken only with Voice on).
    var gpuLight: GPULightModel!
    var brief: DayBriefController!
    let briefSpeaker = SpeechBriefSpeaker()
    var briefCache = DayBriefCache()
    /// Desktop actions: .off unless a scratch GOAT_PEAK_ROOT plus FORCEIQ_PEAK_DESKTOP_DRYRUN=1 (locate-and-report dry run),
    /// or the live env opt-in with settings.json desktopActions=true in that same scratch root (live: FLOW's Code
    /// Window press only, after Run). Decided once the state root's settings are read; desktopActions has no UI.
    var desktopMode: DesktopActionMode = .off
    /// "Start a meeting with <client>" → Command's Start sheet by deep link (Command #685). OFF unless settings.json
    /// commandMeetingLink is true or FORCEIQ_PEAK_COMMAND_MEETING_LINK=1 (CommandMeetingLinkGate); no UI toggle.
    var commandMeetingLink = false
    /// The next-session pill + gap warnings (read-only). OFF unless settings.json nextSessionPill is true; no UI toggle.
    var nextSession: NextSessionModel!
    /// The live meeting checklist + ten-minute nudge (local state only, no client name anywhere).
    var checklist: MeetingChecklistModel!
    /// The Claude watcher (agents module): the session registry + held approvals, fed by peek.sock.
    var agents: AgentWatchModel!
    var agentServer: AgentSocketServer?
    var agentsOn = false
    /// Pack ready / FLOW package ready (read-only, GET /api/peak/ready about every 10 min). On unless settings.json readyAlerts is false.
    var ready: ReadyModel!
    /// What Command is running now (upscales, meeting packs) for the sheet: read-only, GET /api/peak/running.
    var running: RunningModel!
    var wasExpanded = false
    var demoReadyReads = 0
    /// Demo only: what Ask TRON / Copy would have put on the clipboard (the coach's real clipboard is never touched).
    var demoClipboard = ""
    var dryRunPanel: DryRunPanel?

    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Task { @MainActor in
            // The coach profile: engine (this coach's overlay peak section) → cache under the state root → none.
            let (p, src) = ProfileLoader.resolve(engine: await engine.profile(), cacheRoot: Session.defaultStateRoot)
            var prof = p
            if demo {                                             // screenshots: a fake coach + sample cards; apps from the real profile
                prof = DemoData.profile(stateRoot: p.stateRoot.isEmpty ? "~/ForceIQ/peak" : p.stateRoot, apps: p.apps)
                prof.goatBundleID = p.goatBundleID
                if avatarTour { prof.modules["voice"] = true }    // the avatar tour shows 'listening' (voice stays off elsewhere)
                if isVoiceTour {
                    prof.modules["voice"] = true
                    prof.roster = CoachProfile.Roster(source: "fixture", names: DemoData.voiceRoster)
                }
            }
            setUp(prof, source: src)
        }
    }

    func setUp(_ p: CoachProfile, source: String) {
        profile = p
        Session.profile = p
        let root = p.stateRootURL()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        log.move(to: root)
        prefs = PeakPrefs(stateRoot: root)
        prefs.reportLoad(to: log)                          // a settings.json that exists but can't be used: one loud line
        desktopMode = DesktopActionGate.mode(env: ProcessInfo.processInfo.environment, desktopActions: prefs.desktopActions, stateRoot: root.path)
        commandMeetingLink = CommandMeetingLinkGate.enabled(env: ProcessInfo.processInfo.environment, setting: prefs.commandMeetingLink)
        // Cua backend for the one live action: only inside the live gates, with settings.json cuaActions (no UI) and the
        // Cua env opt-in (CuaGate.env). Off: no backend exists, so nothing imports, spawns or calls Cua.
        CuaWiring.shared.install(CuaBackend.make(env: ProcessInfo.processInfo.environment, cuaActions: prefs.cuaActions, mode: desktopMode,
                                                 config: CuaConfig.standard(resources: Bundle.main.resourcePath, env: ProcessInfo.processInfo.environment)))
        GhostAssets.format = prefs.ghostFormat
        // The mark, resolved now that prefs exist (the env var still wins). GhostAssets learns the choice
        // before anything reads the pack, so the bundled pack root matches the renderer.
        markSelection = PeakMark.resolve(env: ProcessInfo.processInfo.environment, setting: prefs.mark)
        if markSelection.isVideo { mark = VideoGhostMarkRenderer() }
        GhostAssets.markChoice = markSelection
        ThreePOAssets.log = { [weak self] e in self?.log.log(e) }
        ThreePOAssets.demoReduceMotion = demo && ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_REDUCE_MOTION"] == "1"
        controller = PeakController(prefs: prefs, profile: p, hotkey: KeyboardShortcutsHotkey(name: PeakHotkeyName.make(p)), logger: log)
        performer = Performer(engine: engine, demo: demo)
        cards = CardStackViewModel(performer: performer, logger: log, signInTransport: demo ? nil : engine)
        cards.settingsNotice = prefs.settingsNotice
        nextSession = NextSessionModel(transport: demo ? DemoThreePOTransport(knobs: demoKnobs) : engine,
                                       enabled: NextSessionGate.enabled(setting: prefs.nextSessionPill), roster: p.roster.names, logger: log)
        ready = ReadyModel(transport: engine, enabled: !demo && prefs.readyAlerts, logger: log)
        running = RunningModel(transport: engine, enabled: !demo, logger: log)
        checklist = MeetingChecklistModel()
        setUpAgents(p)
        controller.onPeekAction = { [weak self] a, display in
            guard let self else { return }
            guard let id = a.cardID, let card = self.cards.cards.first(where: { $0.id == id }) else {
                if let d = display { self.controller.activeDisplay = d }
                self.controller.expand(); return                         // the card is gone (meeting over, approval handled): just open Peek
            }
            switch a.action {
            case .startMeeting: Task { @MainActor in await self.cards.quickStart(card) }
            case .reviewApproval:
                if let d = display { self.controller.activeDisplay = d }
                self.cards.tap(card); self.controller.tab = .home; self.controller.expand()
            case .none: break
            }
        }
        controller.onPeekOpen = { [weak self] a in                           // a meeting alert lands on the next-session card
            if a.kind == .meetingSoon { self?.nextSession.openCard() }
        }
        nextSession.onCopy = { [weak self] s in                               // clipboard only; nothing is ever sent
            guard let self else { return }
            if self.demo { self.demoClipboard = s } else { self.performer.copy(s) }
        }
        threePO = ThreePOStore(transport: demo ? DemoThreePOTransport(knobs: demoKnobs) : engine, session: "peak-\(p.coachID)", logger: log)
        threePO.onCopy = { [weak self] s in self?.performer.copy(s) }
        controller.wireAsk(to: threePO)                                      // ask links prefill 3PO's field, open or collapsed
        threePO.onOpenApp = { [weak self] name in
            guard let self, let app = self.profile.apps.first(where: { $0.name.lowercased() == name.lowercased() }) else { return }
            self.controller.handle(.switchApp(app.bundleID))
        }
        dropsStore = DropStore(transport: demo ? DemoThreePOTransport(knobs: demoKnobs) : engine, logger: log)
        drops = dropsStore
        dropsStore.onCopy = { [weak self] s in self?.performer.copy(s) }
        dropsStore.onAsk = { [weak self] q in
            guard let self, self.profile.isEnabled(.threePO) else { self?.performer.copy(q); return }
            self.dropsStore.dismiss(); self.controller.tab = .threePO; self.threePO.draft = q        // prefilled; Chris sends it
        }
        controller.onModelPick = { [weak self] pick in Task { await self?.threePO.choose(pick) } }
        // 5090 light: every 5090 GPU action asks it at tap time; not green (red or unknown) = refused, nothing runs.
        gpuLight = GPULightModel(logger: log)
        let gpuHold: () -> String? = { [weak self] in
            self?.gpuLight.hold() ?? GPUGate.refusal(.unknown("meeting status unavailable"))
        }
        dropsStore.gpuHold = gpuHold
        threePO.gpuHold = gpuHold
        cards.gpuHold = gpuHold
        setUpVoice(p, root: root)
        if p.isEnabled(.threePO) { Task { await threePO.loadModels(); await threePO.refreshSpend() } }
        log.log("launch profile=\(source) configured=\(p.configured ? "yes" : "no") modules=\(PeakModuleID.allCases.filter { p.isEnabled($0) }.map(\.rawValue).joined(separator: ",")) demo=\(demo ? "on" : "off") glow=\(ShaderGlowRenderer.available ? "metal" : "native") mark=\(markSelection.isVideo ? (GhostAssets.pack.map { $0.pack.replacingOccurrences(of: " ", with: "_") } ?? "placeholder") : "peek-eyes") format=\(GhostAssets.format.rawValue)")
        controller.onSwitchApp = { [weak self] id in
            let ok = AppLauncher.activate(id)
            self?.log.log("switch \(ok ? "ok" : "refused")")
        }
        AppIcons.shared.prefetch(p.isEnabled(.switcher) ? AppSwitcher.entries(p, WorkspaceLocator()).map(\.app.bundleID) : [])
        rebuildPanels()
        buildStatusItem()
        if ProcessInfo.processInfo.environment["FORCEIQ_PEAK_NO_WARM"] != "1" { warmUp() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log.log("screens changed"); self?.rebuildPanels() }
        }
        controller.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncPanels(); self?.noteExpansion() }
        }.store(in: &bag)
        installMouseMonitors()
        refresh()
        poll = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }   // also re-judges the 5090 light
        if demo, ["pack", "flow"].contains(ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_FEED"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in MainActor.assumeIsolated { self?.refresh() } }      // the second read
        }
        let queued = pendingURLs; pendingURLs = []
        for u in queued { route(u) }
        if demo && ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_TOUR"] == "1" { tour() }
        if avatarTour { threePOAvatarTour() }
        if sendTour { threePOSendTour() }
        if idleTour { threePOIdleTour() }
        if polishTour { motionPolishTour() }
        if PeakSnapshot.dir != nil {                       // visual proof: render the memory pane + a skill card, then quit
            Task { @MainActor in
                if PeakSnapshot.signIn {
                    await PeakSnapshot.runSignIn(cards: cards, engine: engine, profile: profile) { [weak self] e in self?.log.log(e) }
                } else {
                    await PeakSnapshot.run(store: threePO) { [weak self] e in self?.log.log(e) }
                }
                NSApp.terminate(nil)
            }
        }
        if isVoiceTour { voiceTour() }
        log.log("desktop mode=\(desktopMode.rawValue)")
        log.log("desktop cua=\(CuaWiring.shared.backend == nil ? "off" : "on")")
        log.log("command meeting-link=\(commandMeetingLink ? "on" : "off")")
        log.log("next-session pill=\(nextSession.enabled ? "on" : "off")")
        if meetingLinkTour { meetingLinkTourRun() }
        if nextSessionTour { nextSessionTourRun() }
        if let t = dryRunTour { dryRunTourRun(t) }
    }

    // ── voice (toggle dictation into 3PO; opt-in) ──
    func setUpVoice(_ p: CoachProfile, root: URL) {
        voice = VoiceController(root: root, logger: log)
        voice.onListening = { [weak self] on in
            self?.threePO.micOn = on                                              // drives the droid's 'listening'
            if on { self?.controller.dismissPeek() }                              // the live words take the notch row
        }
        KeyboardShortcuts.onKeyUp(for: .dictate) { MainActor.assumeIsolated { [weak self] in self?.voice.toggle() } }   // press starts, press stops
        voice.onFinal = { [weak self] text in
            guard let self else { return }
            if !(self.controller.expanded && self.controller.tab == .threePO) {
                if self.controller.activeDisplay == nil { self.controller.activeDisplay = self.screenUnderPointer() }
                self.controller.tab = .threePO; self.controller.expand()
            }
            Task { await self.threePO.sendDictation(text) }                     // exactly like a typed message
        }
        controller.onVoiceToggle = { [weak self] in self?.voice.toggle() }
        threePO.commandContext = { [weak self] in
            guard let self else { return nil }
            return ClientCommandContext(roster: self.profile.roster.names, meeting: self.lastMeeting, desktopActions: self.prefs.desktopActions,
                                        flowApp: self.profile.apps.first { $0.name.lowercased() == "flow" }?.name, desktopMode: self.desktopMode,
                                        commandMeetingLink: self.commandMeetingLink, cua: CuaWiring.shared.backend != nil)
        }
        threePO.onCommandSignIn = { [weak self] n in self?.cards.signIn.update(n) }      // the existing sign-in row; no retry
        threePO.onCommandRun = { [weak self] c in self?.runCommand(c) ?? "Nothing ran." }
        // "What's my day": typed or dictated, composed locally; spoken (local TTS) only while Voice is on. The same voice
        // toggle interrupts it mid-speech; turning Voice off silences it.
        brief = DayBriefController(speaker: briefSpeaker, voiceOn: { [weak self] in self?.voice.enabled ?? false }, logger: log)
        voice.interrupt = { [weak self] in self?.brief.interruptIfSpeaking() ?? false }
        voice.onDisabled = { [weak self] in self?.brief.silence() }
        threePO.dayBrief = { [weak self] in await self?.composeBrief() ?? "Peek couldn't build the brief. Nothing ran." }
        threePO.onDayBrief = { [weak self] text in self?.brief.deliver(text) }
        let on = VoiceGate.enabled(p, setting: demo ? (isVoiceTour ? true : nil) : prefs.voiceEnabled)
        voice.configure(enabled: on, roster: p.roster.names)
        log.log("voice enabled=\(on ? "yes" : "no")")
    }

    func setVoice(_ on: Bool) {
        if !demo { prefs.voiceEnabled = on }
        voice.configure(enabled: VoiceGate.enabled(profile, setting: on), roster: profile.roster.names)
        log.log("voice setting=\(on ? "on" : "off")")
    }

    /// Run on a client-command card (an explicit tap). Opens Command's own UI (room page or schedule) or brings FLOW
    /// forward; nothing else. With desktop actions gated on (scratch root only), Run starts the dry run, or in live mode
    /// FLOW's Code Window press for a flow_package_code card (the meeting start stays locate-only).
    func runCommand(_ c: ProposalCard) -> String {
        if c.action == ClientCommands.meetingLinkAction { return openMeetingLink(c) }
        if desktopMode != .off { return startDryRun(c) }
        if demo { log.log("command run demo=1"); return "Demo mode: nothing opened." }
        if let l = c.link {
            guard let u = URL(string: CommandLink.safe(l)), NSWorkspace.shared.open(u) else { return "Command didn't open. Nothing ran." }
            return "Command is open for \(c.client ?? "the client"). Join and Record are yours to tap there."
        }
        if let name = c.appName, let app = profile.apps.first(where: { $0.name.lowercased() == name.lowercased() }) {
            controller.handle(.switchApp(app.bundleID))
            return "FLOW is in front. Press the code button there yourself (desktop clicks stay off)."
        }
        return "FLOW isn't in this coach's app list, so nothing opened."
    }

    /// Run on a Command meeting-link card (an explicit tap): re-validates the link (validated lower-case UUID, source=goat,
    /// nothing else) and opens it. Command shows its own Start / Cancel sheet; nothing starts until Start is tapped there.
    /// Logged: the outcome only (never the client's name or id).
    func openMeetingLink(_ c: ProposalCard) -> String {
        let who = c.client ?? "the client"
        guard commandMeetingLink, desktopMode == .off, CommandMeetingLink.isValid(c.link), let l = c.link, let u = URL(string: l) else {
            log.log("command meeting-link open refused=1")
            return "That Command link didn't pass Peek's check, so nothing opened."
        }
        if demo { log.log("command meeting-link open demo=1"); return "Demo mode: nothing opened. Run would open Command's Start sheet for \(who)." }
        guard NSWorkspace.shared.open(u) else { log.log("command meeting-link open ok=0"); return "Command didn't open. Nothing started." }
        log.log("command meeting-link open ok=1")
        return "Command's Start sheet is open for \(who). Nothing starts until you tap Start there."
    }

    var nextSessionTour: Bool { demo && ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_TOUR"] == "next-session" }

    /// Next-session smoke (demo mode + FORCEIQ_PEAK_DEMO_TOUR=next-session; the flag is read from a scratch GOAT_PEAK_ROOT's
    /// settings.json): the demo transport's mocked feed (fake clients only). Fetches once, opens the pill's card, checks
    /// every warning offers only Ask TRON / Copy, taps both (demo: an in-memory clipboard), and checks a second tick inside
    /// 5 min does not fetch. Logs counts and states only, never a client name.
    func nextSessionTourRun() {
        guard let scr = NSScreen.screens.first else { return }
        let main = Screens.uuid(scr)
        let c = controller!, m = nextSession!
        func at(_ t: Double, _ name: String, _ f: @escaping @MainActor () async -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.log.log("tour step=\(name) t=\(String(format: "%.3f", Date().timeIntervalSince1970))"); Task { @MainActor in await f() }
            }
        }
        at(1.0, "fetch") {
            let went = await m.tick()
            var raw = 0
            if case let .loaded(_, _, w) = NextSessionResult.parse(200, Data(DemoData.nextSessionJSON().utf8)) { raw = w.count }
            let named = m.session.map { self.profile.isMyClient($0.client) && (m.pillText(now: Date()) ?? "").hasPrefix($0.client) } ?? false
            self.log.log("tour next-session flag=\(m.enabled ? "on" : "off") fetched=\(went ? 1 : 0) outcome=\(m.result?.outcome ?? "none") pill=\(m.showsPill ? "shown" : "hidden") named=\(named ? 1 : 0) gold=\(m.gold ? 1 : 0) gaps=\(m.warnings.filter { $0.state == .present }.count) unknown=\(m.warnings.filter { $0.state == .unknown }.count) roster_dropped=\(m.enabled ? raw - m.warnings.count : 0) since=\(m.since?.state ?? "none") since_lines=\(m.since?.lines.count ?? 0)")
        }
        at(2.5, "open-card") {
            c.activeDisplay = main; c.tab = .home; c.expand(); m.openCard()
            let acts = Set(m.warnings.map { $0.actions.map(\.rawValue).joined(separator: ",") })
            self.log.log("tour next-session card=\(m.showingCard ? "open" : "closed") warnings=\(m.warnings.count) named_all=\(m.warnings.allSatisfy { self.profile.isMyClient($0.client) && $0.text.contains($0.client) } ? 1 : 0) actions=\(acts.sorted().joined(separator: "|"))")
        }
        at(4.0, "ask-tron") {
            guard let w = m.warnings.first(where: { $0.state == .present }) else { self.log.log("tour next-session no-gap"); return }
            let r = m.perform(.askTRON, on: w)
            self.log.log("tour next-session ask-tron copied_chars=\(self.demoClipboard.count) addressed_tron=\(self.demoClipboard.hasPrefix("TRON") ? 1 : 0) says_nothing_sent=\(r.contains("nothing was sent") ? 1 : 0) sent=0")
        }
        at(5.5, "copy") {
            guard let w = m.warnings.first else { return }
            let r = m.perform(.copy, on: w)
            self.log.log("tour next-session copy copied_chars=\(self.demoClipboard.count) says_nothing_sent=\(r.contains("Nothing was sent") ? 1 : 0) sent=0")
        }
        at(7.0, "repoll") {
            let went = await m.tick()
            self.log.log("tour next-session repoll_within_5min=\(went ? 1 : 0) fetches=\(m.fetches)")
        }
        at(8.5, "collapse") { m.closeCard(); c.collapse() }
        at(9.5, "tour-end") { self.log.log("tour next-session end fetches=\(m.fetches)") }
    }

    var meetingLinkTour: Bool { demo && commandMeetingLink && ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_TOUR"] == "meeting-link" }

    /// Meeting-link smoke (demo mode + the flag on in a scratch GOAT_PEAK_ROOT + FORCEIQ_PEAK_DEMO_TOUR=meeting-link): the
    /// demo transport's mocked directory (fake clients only). Types an exact name (unique), a partial one (ambiguous) and an
    /// unknown one (none), checks nothing opened before Run, then taps Run on the unique card (demo: nothing opens).
    /// Logs counts and outcomes only.
    func meetingLinkTourRun() {
        guard let scr = NSScreen.screens.first else { return }
        let main = Screens.uuid(scr)
        let c = controller!, store = threePO!
        func at(_ t: Double, _ name: String, _ f: @escaping @MainActor () async -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.log.log("tour step=\(name) t=\(String(format: "%.3f", Date().timeIntervalSince1970))"); Task { @MainActor in await f() }
            }
        }
        func last() -> ProposalCard? { store.transcript.messages.last?.proposals.first }
        func report(_ which: String) {
            let k = last()
            let origin = k?.origin.rawValue ?? "none", action = k?.action ?? "none", picks = k?.picks.count ?? 0
            let linkOK = CommandMeetingLink.isValid(k?.link) ? 1 : 0
            var phase = "none"
            if let k { phase = store.phases[k.id] == .described ? "described" : "other" }
            self.log.log("tour meeting-link said=\(which) card=\(origin) action=\(action) picks=\(picks) link_ok=\(linkOK) phase=\(phase) opened=0")
        }
        at(1.5, "chat") { c.activeDisplay = main; c.tab = .threePO; c.expand() }
        at(3.0, "unique") { store.draft = "start a meeting with Test Client Alpha"; await store.send(); report("unique") }
        at(6.0, "ambiguous") { store.draft = "start a meeting with test client"; await store.send(); report("ambiguous") }
        at(9.0, "none") { store.draft = "start a meeting with Nobody Fictional"; await store.send(); report("none") }
        at(12.0, "run-unique") {
            let card = store.transcript.messages.reversed().lazy.flatMap(\.proposals).first { $0.action == ClientCommands.meetingLinkAction }
            guard let card else { self.log.log("tour meeting-link no-link-card"); return }
            self.log.log("tour meeting-link before-run phase=\(store.phases[card.id] == .described ? "described" : "other")")
            await store.run(card.id)
            if case .done(let m) = store.phases[card.id] { self.log.log("tour meeting-link after-run demo_nothing_opened=\(m.hasPrefix("Demo mode: nothing opened") ? 1 : 0)") }
        }
        at(14.0, "collapse") { c.tab = .home; c.collapse() }
        at(15.0, "tour-end") {}
    }

    // ── desktop actions STOP dry run (locate and report only) ──
    func desktopApps() -> DesktopApps {
        var a = DesktopApps()
        if let f = profile.apps.first(where: { $0.name.lowercased() == "flow" }) { a.flowName = f.name; a.flowBundle = f.bundleID }
        if let c = profile.apps.first(where: { $0.name.lowercased() == "command" }) { a.commandName = c.name; a.commandBundle = c.bundleID }
        // smoke only: an isolated, non-production FLOW instance (FORCEIQ_PEAK_FLOW_TARGET_PID / _BUNDLE). Production stays refused.
        if let t = FlowSmokeTarget.from(env: ProcessInfo.processInfo.environment),
           let b = t.bundleID ?? t.pid.flatMap({ NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }) {
            if ProductionGuard.isProductionBundle(b) { log.log("desktop smoke target refused: production FLOW") } else { a.flowBundle = b }
        }
        return a
    }

    func startDryRun(_ c: ProposalCard) -> String {
        let live = desktopMode == .live && c.action == "flow_package_code"      // the meeting start stays locate-only
        guard desktopMode != .off, let steps = DryRunPlanner.plan(c, apps: desktopApps(), live: live), let client = c.client else {
            return "Nothing to dry-run for this card. Nothing ran."
        }
        if dryRunPanel != nil { return "A dry run is already on screen." }
        let model = DryRunModel(client: client, action: c.action, steps: steps, live: live)
        dryRunPanel = DryRunPanel(model: model) { [weak self] in self?.dryRunPanel?.close(); self?.dryRunPanel = nil }
        if live && CuaWiring.shared.backend != nil {          // Cua: the press waits for this panel's approval card + Run tap
            let log = self.log
            CuaWiring.shared.desk.onRequest { card in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        log.log("cua approval card shown pid=\(card.pid) path=\(card.menuPath.joined(separator: ">")) t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
                        model.showCua(card)
                    }
                }
            }
            model.onCuaDecision = { ran in log.log("cua approval \(ran ? "run tapped" : "closed") t=\(String(format: "%.3f", Date().timeIntervalSince1970))") }
        }
        let pace = Int(ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DRYRUN_PACE_MS"] ?? "") ?? 0
        let env = ProcessInfo.processInfo.environment
        let arm = Int(env["FORCEIQ_PEAK_LIVE_ARM_MS"] ?? "") ?? 1500                // the window to STOP before the press
        let runner = DryRunRunner(steps: steps, locator: AXDesktopLocator(refuseProduction: live), stop: model.stop, action: c.action, paceMs: pace,
                                  presser: live ? AXCodeWindowPresser() : nil, armMs: live ? arm : 0)
        let log = self.log
        log.log("dryrun run mode=\(live ? "live" : "dry_run") action=\(c.action) client=\(client) steps=\(steps.count) pace_ms=\(pace)\(live ? " arm_ms=\(arm)" : "") t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
        Task.detached {
            let report = await runner.run { e in
                let line = e.logLine + " t=\(String(format: "%.3f", Date().timeIntervalSince1970))"
                DispatchQueue.main.async { MainActor.assumeIsolated { log.log(line); model.apply(e) } }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    model.finish(report)
                    if let p = model.stopPressedAt { log.log(String(format: "dryrun stop pressed t=%.3f", p.timeIntervalSince1970)) }
                    log.log("dryrun summary total_ms=\(report.totalMs) \(report.summary)")
                }
            }
        }
        return live ? "Live run started for \(client): FLOW's Code Window is pressed only after the checks. STOP is on screen."
                    : "Dry run started for \(client): locate and report only. STOP is on screen."
    }

    var dryRunTour: String? {
        let t = ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_TOUR"] ?? ""
        if demo && desktopMode == .live && t == "live-flow" { return t }
        return demo && desktopMode == .dryRun && t.hasPrefix("dryrun-") ? t : nil
    }

    /// Live dry run (demo mode + scratch GOAT_PEAK_ROOT + FORCEIQ_PEAK_DESKTOP_DRYRUN=1 + FORCEIQ_PEAK_DEMO_TOUR=dryrun-flow |
    /// dryrun-meeting): types the command into 3PO (fake roster), then taps Run on the confirm card, which in dry-run mode
    /// only starts the locate-and-report run. STOP is pressed by hand (or by the proof script on Peek's own STOP button).
    func dryRunTourRun(_ which: String) {
        guard let scr = NSScreen.screens.first else { return }
        let main = Screens.uuid(scr)
        let c = controller!, store = threePO!
        let text = which == "dryrun-meeting" ? "start a meeting with Sample Skater"
                                             : "open Sample Skater's latest FLOW package and hit the code button"
        func at(_ t: Double, _ name: String, _ f: @escaping @MainActor () async -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.log.log("tour step=\(name) t=\(String(format: "%.3f", Date().timeIntervalSince1970))"); Task { @MainActor in await f() }
            }
        }
        at(1.5, "chat") { c.activeDisplay = main; c.tab = .threePO; c.expand() }
        at(3.0, "type-send") { store.draft = text; await store.send() }
        if which == "live-flow" {                       // live: the tour never taps Run; an explicit tap on the card's Run must
            at(5.0, "await-run-tap") {                  // (the proof script presses Peek's own Run button, id peak-command-run)
                let card = store.transcript.messages.reversed().lazy.flatMap(\.proposals).first(where: { $0.origin == .command })
                self.log.log("tour card client=\(card?.client ?? "none") action=\(card?.action ?? "none") waiting for an explicit Run tap")
            }
            return
        }
        at(5.0, "tap-run") {
            guard let card = store.transcript.messages.reversed().lazy.flatMap(\.proposals).first(where: { $0.origin == .command }) else {
                self.log.log("tour no-command-card"); return
            }
            self.log.log("tour card client=\(card.client ?? "none") action=\(card.action)")
            await store.run(card.id)
        }
    }

    /// First-use costs paid once, off-screen, right after launch instead of on the first tap: the multi-line text
    /// field stack 3PO uses (opening the 3PO tab the first time stalled the main thread 104-153 ms). One invisible,
    /// click-through window with a stand-in field (no app state), rendered once and closed; nothing is shown or sent.
    var warm: NSWindow?
    func warmUp() {
        guard profile.isEnabled(.threePO) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 620, height: 520), styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false; w.ignoresMouseEvents = true; w.alphaValue = 0; w.hasShadow = false
            w.contentView = NSHostingView(rootView: TextWarmUp().frame(width: 588, height: 480).background(Color.black))
            w.orderFrontRegardless()
            w.contentView?.layoutSubtreeIfNeeded(); w.displayIfNeeded()
            self.warm = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.warm?.orderOut(nil); self?.warm?.contentView = nil; self?.warm = nil }
        }
    }

    /// Visual proof only (demo mode + FORCEIQ_PEAK_DEMO_TOUR=1): drives every interaction on the main display with
    /// sample data and the scripted 3PO transport. No engine, no tokens; Demo performer/transport never run anything.
    let demoKnobs = DemoKnobs()

    func tour() {
        guard let scr = NSScreen.screens.first, let h = hosts[Screens.uuid(scr)] else { return }
        let main = Screens.uuid(scr)
        let hitch = HitchMonitor(logger: log); hitch.start(on: scr)
        func at(_ t: Double, _ name: String, _ f: @escaping @MainActor () async -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.log.log("tour step=\(name)"); hitch.mark(name); Task { @MainActor in await f() }
            }
        }
        let c = controller!, cards = cards!, store = threePO!, drops = dropsStore!
        at(2.0, "hover-in") { h.state.hovering = true; Haptic.generic() }
        at(3.2, "hover-out") { h.state.hovering = false }
        at(4.0, "expand") { c.activeDisplay = main; c.expand() }
        at(6.0, "describe") { if let card = cards.cards.first(where: { $0.kind == .approval && !$0.viewOnly }) { cards.tap(card) } }
        at(8.0, "approve") { await cards.choose(.run) }
        at(10.5, "back") { cards.back() }
        at(11.5, "drop-hover") { h.state.dropTargeted = true }
        at(13.5, "drop-accept") {
            h.state.dropTargeted = false; h.state.dropAccepted += 1; Haptic.level()
            _ = self.dropped([URL(fileURLWithPath: "/Users/demo/Films/SampleSkater_DemoHawks_10.18.2026.mp4")], uuid: main)
        }
        at(15.0, "drop-preview") { await drops.preview(.title) }
        at(17.5, "drop-run") { await drops.run() }
        at(19.0, "drop-confirm") { await drops.confirm() }
        at(21.0, "shift-drop") {
            drops.dismiss()
            _ = self.dropped([URL(fileURLWithPath: "/Users/demo/Films/SampleSkater_DemoHawks_10.18.2026.mp4")], uuid: main)
        }
        at(22.0, "shift-preview") { await drops.preview(.shift) }
        at(24.0, "shift-run") { await drops.run() }
        at(25.0, "shift-confirm") { await drops.confirm() }
        at(26.5, "shift-progress") { await drops.pollShift() }
        at(27.5, "shift-progress") { await drops.pollShift() }
        at(28.5, "shift-progress") { await drops.pollShift() }
        at(29.5, "shift-progress") { await drops.pollShift() }
        at(31.0, "chat") { drops.dismiss(); withAnimation { c.tab = .threePO } }
        at(32.5, "pick-auto") { await store.choose(.auto) }
        at(34.0, "chat-send") { store.draft = "Why is the title slide wrong?"; await store.send() }
        at(42.0, "proposal-run") { if let id = store.transcript.messages.last?.proposals.first?.id { await store.run(id) } }
        at(44.0, "proposal-confirm") { if let id = store.transcript.messages.last?.proposals.first?.id { await store.confirm(id) } }
        at(46.5, "spend-80") { self.demoKnobs.spendWarn = true; await store.refreshSpend(now: Date().addingTimeInterval(3600)) }
        at(49.0, "pick-opus") { await store.choose(.opus) }
        at(50.5, "pick-haiku") { await store.choose(.haiku) }
        at(52.0, "collapse") { c.tab = .home; c.collapse() }
        at(54.0, "tour-end") { hitch.stop() }
    }

    var polishTour: Bool { demo && ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_TOUR"] == "polish" }

    /// Motion-polish proof (demo mode + FORCEIQ_PEAK_DEMO_TOUR=polish, sample names only): hover lift, the one-spring
    /// expand with staggered cards, an approval that pops in, a card that collapses away, the chat with its sliding
    /// pills, focus ring, bubbles and streamed answer, then collapse. Nothing runs: no card is chosen, no engine.
    func motionPolishTour() {
        guard let scr = NSScreen.screens.first, let h = hosts[Screens.uuid(scr)] else { return }
        let main = Screens.uuid(scr)
        let c = controller!, cards = cards!, store = threePO!, t0 = Date()     // one clock, so the meeting card keeps its id
        func at(_ t: Double, _ name: String, _ f: @escaping @MainActor () async -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.log.log("tour step=\(name)"); Task { @MainActor in await f() }
            }
        }
        at(1.0, "feed") { cards.update(DemoData.polishSnapshot(step: 0, now: t0), profile: self.profile) }
        at(1.5, "hover-in") { h.state.hovering = true }
        at(2.7, "hover-out") { h.state.hovering = false }
        at(3.5, "expand") { c.activeDisplay = main; c.expand() }
        at(6.0, "approval-arrives") { cards.update(DemoData.polishSnapshot(step: 1, now: t0), profile: self.profile) }
        at(8.5, "card-removed") { cards.update(DemoData.polishSnapshot(step: 2, now: t0), profile: self.profile) }
        at(10.5, "chat") { withAnimation(Motion.spring(false)) { c.tab = .threePO } }
        at(12.0, "pane-memory") { withAnimation(Motion.spring(false)) { store.pane = .memory } }
        at(13.2, "pane-chat") { withAnimation(Motion.spring(false)) { store.pane = .chat } }
        at(14.2, "pick-sonnet") { await store.choose(.sonnet) }
        at(15.2, "pick-auto") { await store.choose(.auto) }
        at(16.5, "chat-send") { store.draft = "Why is the title slide wrong?"; await store.send() }
        at(27.0, "collapse") { c.tab = .home; c.collapse() }
        at(29.0, "tour-end") {}
    }

    var avatarTour: Bool { demo && ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_TOUR"] == "3po" }
    var sendTour: Bool { demo && ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_TOUR"] == "3po-send" }
    var idleTour: Bool { demo && ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_TOUR"] == "3po-idle" }
    var isVoiceTour: Bool { demo && ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_TOUR"] == "voice" }

    /// Voice live smoke (demo mode + FORCEIQ_PEAK_DEMO_TOUR=voice + FORCEIQ_PEAK_VOICE_FEED=<folder of .wav clips>): each
    /// clip is fed in real time through the mic's conversion path. Clips named *-notch-* run with Peek collapsed and are
    /// toggled through forceiq-peak://voice; the rest through the mic button's action with the 3PO chat open. Fake roster.
    func voiceTour() {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FORCEIQ_PEAK_VOICE_FEED"] ?? "")
        let clips = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let scr = NSScreen.screens.first else { return }
        let main = Screens.uuid(scr)
        let c = controller!, v = voice!, store = threePO!
        func step(_ name: String) { log.log("tour step=\(name) t=\(String(format: "%.3f", Date().timeIntervalSince1970))") }
        func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        Task { @MainActor [self] in
            await sleep(1.5); step("chat"); c.activeDisplay = main; c.tab = .threePO; c.expand()
            var waited = 0.0
            while v.phase != .ready && waited < 900 { await sleep(0.2); waited += 0.2 }
            step("voice-ready waited_s=\(Int(waited))")
            await sleep(2.0)
            for (i, clip) in clips.enumerated() {
                let notch = clip.lastPathComponent.contains("-notch-")
                if notch { c.tab = .home; c.collapse(); await sleep(1.5) }
                else if !(c.expanded && c.tab == .threePO) { c.activeDisplay = main; c.tab = .threePO; c.expand(); await sleep(1.2) }
                v.feed = clip
                step("voice-start-\(i + 1) clip=\(clip.deletingPathExtension().lastPathComponent)")
                if notch { route("forceiq-peak://voice") } else { v.toggle() }
                await sleep(0.3)
                let dur = v.lastFeed?.duration ?? 3
                await sleep(max(0.5, dur - 0.3) + 0.2)                      // end of audio + 200 ms, then the stop toggle
                step("voice-stop-\(i + 1)")
                if notch { route("forceiq-peak://voice") } else { v.toggle() }
                await sleep(1.0)
                var w = 0.0
                while store.transcript.streaming && w < 20 { await sleep(0.2); w += 0.2 }
                await sleep(2.5)
            }
            let r = v.results
            func s(_ xs: [Double]) -> String {
                guard let p50 = VoiceStats.percentile(xs, 50), let mx = xs.max() else { return "n/a" }
                return String(format: "p50=%.0f max=%.0f n=%d", p50, mx, xs.count)
            }
            log.log("voice summary first_confirmed_ms \(s(r.compactMap(\.first))) | from_onset_ms \(s(r.compactMap(\.firstFromOnset))) | final_ms \(s(r.map(\.final))) | cpu_pct \(s(r.map(\.cpu)))")
            await sleep(2.0); step("collapse"); c.tab = .home; c.collapse()
            await sleep(1.0); step("tour-end")
        }
    }

    /// Visual proof of the 3PO droid (demo mode + FORCEIQ_PEAK_DEMO_TOUR=3po): every state and transition with the
    /// scripted transport (no engine, no tokens): idle → mic (listening) → idle → send on Auto (thinking + the gold
    /// 'consulting Opus' pulse) → streamed reply (talking) → the proposal card (alert) → idle → collapse.
    func threePOAvatarTour() {
        guard let scr = NSScreen.screens.first else { return }
        let main = Screens.uuid(scr)
        let c = controller!, store = threePO!
        demoKnobs.slowTurn = true
        func at(_ t: Double, _ name: String, _ f: @escaping @MainActor () async -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.log.log("tour step=\(name) t=\(String(format: "%.3f", Date().timeIntervalSince1970))"); Task { @MainActor in await f() }
            }
        }
        at(1.5, "chat") { c.activeDisplay = main; c.tab = .threePO; c.expand() }
        at(4.0, "pick-auto") { await store.choose(.auto) }
        at(7.0, "mic-on") { store.micOn = true }
        at(12.0, "mic-off") { store.micOn = false }
        at(16.0, "chat-send") { store.draft = "Why is the title slide wrong?"; await store.send() }
        at(32.0, "collapse") { c.tab = .home; c.collapse() }
        at(34.0, "tour-end") {}
    }

    /// Send latency proof (demo mode + FORCEIQ_PEAK_DEMO_TOUR=3po-send): five sends from idle at different points of
    /// the idle loop, each through store.send() (what the Send button calls), then one turn whose thinking ⇄ talking
    /// flips land 60 ms apart. Each send flips the Send button to "…" in the same update the droid's state changes in.
    func threePOSendTour() {
        guard let scr = NSScreen.screens.first else { return }
        let main = Screens.uuid(scr)
        let c = controller!, store = threePO!
        demoKnobs.quickTurn = true
        func at(_ t: Double, _ name: String, _ f: @escaping @MainActor () async -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.log.log("tour step=\(name) t=\(String(format: "%.3f", Date().timeIntervalSince1970))"); Task { @MainActor in await f() }
            }
        }
        at(1.5, "chat") { c.activeDisplay = main; c.tab = .threePO; c.expand() }
        let sends = [7.5, 13.8, 20.2, 26.7, 33.1, 39.5]   // the first one 6 s after the chat opens (two idle passes to compare against)
        for (i, t) in sends.enumerated() {
            let last = i == sends.count - 1
            at(t - 1.2, "type-\(i + 1)") { store.draft = "Fix the title slide for Sample Skater" }
            at(t, last ? "send-flip" : "send-\(i + 1)") { if last { self.demoKnobs.flipTurn = true }; await store.send() }
        }
        at(45.5, "collapse") { c.tab = .home; c.collapse() }
        at(47.5, "tour-end") {}
    }

    /// CPU proof (demo mode + FORCEIQ_PEAK_DEMO_TOUR=3po-idle): the 3PO chat opens and stays open, idle, for 90 s; then
    /// Peek collapses.
    func threePOIdleTour() {
        guard let scr = NSScreen.screens.first else { return }
        let main = Screens.uuid(scr)
        let c = controller!
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.log.log("tour step=chat t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
            c.activeDisplay = main; c.tab = .threePO; c.expand()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 91.5) { [weak self] in
            self?.log.log("tour step=collapse t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
            c.tab = .home; c.collapse()
        }
    }

    /// The brief: one fresh read (next meeting + today, live, approvals), merged with the last good read of each source
    /// (so a source that fails now is labelled STALE, or said to be unavailable), then composed in a few sentences.
    func composeBrief() async -> String {
        if controller.presenting { log.log("brief held=presenting"); return Presenting.briefLine }
        let s = demo ? demoSnapshot() : await engine.snapshot()
        if !demo {
            cards.update(s, profile: profile); lastMeeting = s.meeting
            gpuLight.update(s.gpuWindow, at: s.takenAt ?? Date()); controller.setCommandLive(s.gpuWindow?.live)
        }
        let now = Date()
        let text = DayBriefComposer.compose(briefCache.ingest(s, now: now), now: now)
        log.log("brief composed sentences=3")
        return text
    }

    /// Demo feed (sample names only) with today's sessions and a gpu_window: the sample meeting 42 min out → red.
    func demoSnapshot(now: Date = Date()) -> EngineSnapshot {
        let quiet = ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_FEED"] == "quiet"
        let feed = ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_FEED"]
        let soon = feed == "soon"                                                               // the sample meeting 9 min out
        var s = DemoData.snapshot(now: now, quiet: quiet, meetingInMinutes: soon ? 9 : 42.3)
        s.takenAt = now; s.liveAt = now; s.approvalsAt = now
        if feed == "download" { s.downloadsRunning = 1; s.downloadPercents = [38] }              // the progress line, determinate
        if feed == "working" { s.fixesRunning = 1 }                                              // the progress line, dashed
        if feed == "pack" || feed == "flow" {                                                    // the first read is the baseline, the second has one new item
            let fresh = demoReadyReads > 0; demoReadyReads += 1
            var r = ReadyFeed(packsKnown: true, packsChecked: ["Sample Skater", "Demo Player"], packs: [ReadyItem(id: "pack:sample:old", client: "Sample Skater")],
                              flowKnown: true, flow: [ReadyItem(id: "flow:sample:old", client: "Demo Player")])
            if fresh && feed == "pack" { r.packs.append(ReadyItem(id: "pack:sample:new", client: "Sample Skater")) }
            if fresh && feed == "flow" { r.flow.append(ReadyItem(id: "flow:sample:new", client: "Demo Player")) }
            s.ready = r
        }
        let m = s.meeting
        s.today = m.map { [SessionRow(client: $0.client, scheduledAt: $0.scheduledAt, durationMinutes: $0.durationMinutes)] } ?? []
        s.gpuWindow = GPUWindow(spans: m.map { [GPUSpan(start: $0.scheduledAt, end: $0.scheduledAt.addingTimeInterval(Double($0.durationMinutes) * 60), source: "command")] } ?? [], live: feed == "live", calendarAt: now)
        return s
    }

    /// Which display an alert drops on: the one under the pointer, else the notch display, else any shown display.
    func peekDisplayID() -> String? {
        let p = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(p) }), controller.panelVisible(on: Screens.uuid(s)) { return Screens.uuid(s) }
        return hosts.first { controller.panelVisible(on: $0.key) && $0.value.layout.mode == .notch }?.key
            ?? NSScreen.screens.map(Screens.uuid).first { controller.panelVisible(on: $0) }       // the primary display first, not a random one
    }

    /// One policy call per feed read: peek an urgent alert (meeting within 10 min, a fix that just failed) unless the policy
    /// holds it back. Logs the kind or the reason only, never a client name.
    func considerAlert(_ s: EngineSnapshot) {
        guard let display = peekDisplayID() else { return }
        let listening = voice.phase.isListening || voice.phase == .finishing
        let ctx = AlertContext(now: Date(), expanded: controller.expanded, dictating: listening,
                               dndUntil: prefs.dndUntil, quietHours: prefs.quietHours)
        let profile = self.profile
        guard let a = alertPolicy.next(snapshot: s, cards: cards.cards, context: ctx, isMyClient: { profile.isMyClient($0) }) else {
            if alertPolicy.lastSuppression != lastSuppressionLogged, let why = alertPolicy.lastSuppression { log.log("alert held=\(why.rawValue)") }
            lastSuppressionLogged = alertPolicy.lastSuppression
            return
        }
        lastSuppressionLogged = nil
        log.log("alert peek=\(a.kind.rawValue)")
        controller.showPeek(a, on: display)
        Haptic.level()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: a.line, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func refresh() {
        gpuLight?.refresh()
        agents?.tick()
        if demo {
            let s = demoSnapshot(); cards.update(s, profile: profile)
            if ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_FEED"] == "running", running.feed == nil { running.setFeed(DemoData.runningFeed()) }
            considerAlert(s)
            gpuLight.update(s.gpuWindow, at: s.takenAt ?? Date()); controller.setCommandLive(s.gpuWindow?.live)
            considerChecklist(s.gpuWindow)
            let quiet = ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_FEED"] == "quiet"
            lastMeeting = isVoiceTour ? DemoData.voiceMeeting() : s.meeting
            if !demoFeedLogged { demoFeedLogged = true; log.log("feed demo=\(quiet ? "quiet" : "sample") ghost=\(cards.ghost.rawValue)") }
            if !nextSessionTour { Task { await nextSession.tick() } }          // at most every 5 min; flag off: never
            return
        }
        guard controller.globallyVisible else { return }
        Task { @MainActor in
            var s = await engine.snapshot()
            s.ready = ready.feed                                             // the last good read; a new one lands on the next refresh
            cards.update(s, profile: profile)
            considerAlert(s)
            lastMeeting = s.meeting
            gpuLight.update(s.gpuWindow, at: s.takenAt ?? Date()); controller.setCommandLive(s.gpuWindow?.live)
            applyRecording(s)
            considerChecklist(s.gpuWindow)
            _ = briefCache.ingest(s, now: Date())            // last good read per source, for a later brief
            log.log("feed meeting=\(s.meeting != nil ? "yes" : "no") fixes=\(s.fixes.count) approvals=\(s.approvals.count) family=\(s.familyEnabled ? "on" : "off") ghost=\(cards.ghost.rawValue)")
            await nextSession.tick()                                         // at most every 5 min; flag off: never
            await ready.tick()                                               // at most every 10 min, last: a slow read never delays the above
            await running.tick(expanded: controller.expanded)                // 15 s with the sheet open, 1 to 2 min closed
        }
    }

    /// Recording DND from the feed's `recording` field: the tracker's meeting end is the snapshot
    /// meeting's scheduled end when that meeting is the live one (its span contains now), else nil.
    /// Feed reads keep arriving while Peek is dark (refresh gates on globallyVisible, not panel
    /// visibility), so the release lands on the first read after the recording stops.
    func applyRecording(_ s: EngineSnapshot) {
        var end: Date? = nil
        if let m = s.meeting {
            let e = m.scheduledAt.addingTimeInterval(Double(m.durationMinutes) * 60)
            let now = Date()
            if m.scheduledAt <= now, now < e { end = e }
        }
        controller.setRecording(s.recording, meetingEnd: end)
    }

    /// The Claude watcher, when the agents module is on (the profile flag, or the settings.json
    /// agentsWatcher switch): install the relay + hooks, listen on peek.sock, expand once for a
    /// held approval, and keep the state snapshot fresh. Off: Peek's hooks are removed if present.
    func setUpAgents(_ p: CoachProfile) {
        agents = AgentWatchModel(logger: log)
        // The mark's sleep clock reads watcher activity through the card model: a session working or
        // waiting, or a held approval pending, is activity. Off (module disabled): never active.
        cards.agentsActive = { [weak self] in
            guard let self, self.agentsOn, let agents = self.agents else { return false }
            return !agents.pending.isEmpty || agents.sessions.contains { $0.state == .working || $0.state == .waiting }
        }
        // Watcher-plus: a flagged stuck agent escalates the mark to attention, and a wake from
        // sleep assembles the while-you-were-away recap over exactly that sleep window.
        cards.agentsAttention = { [weak self] in
            guard let self, self.agentsOn, let agents = self.agents else { return false }
            return agents.stuck != nil
        }
        cards.onWakeFromSleep = { [weak self] from, to in
            guard let self, self.agentsOn, let agents = self.agents else { return }
            agents.presentRecap(from: from, to: to)
        }
        agentsOn = !demo && (p.isEnabled(.agents) || prefs.agentsWatcher)
        guard agentsOn else { AgentRelayInstaller.reconcile(enabled: false, logger: log); return }
        AgentRelayInstaller.reconcile(enabled: true, logger: log)
        // Held approvals pass through to the terminal while presenting OR while recording DND has
        // Peek dark: nobody can see the notch card either way.
        agents.isPresenting = { [weak self] in (self?.controller.presenting ?? false) || (self?.controller.recordingDND ?? false) }
        // Row titles come from the Claude app's session records, resolved app-side at publish time
        // (the same read-only scan the thread deep link uses) — never through hooks or the registry.
        agents.titleResolver = { SessionJumper.title(forSessionID: $0) }
        agents.onHeldRequest = { [weak self] _ in self?.considerAgentApproval() }
        agentServer = AgentSocketServer(model: agents, path: AgentRelayInstaller.socketURL.path,
                                        log: { [weak self] line in Task { @MainActor in self?.log.log(line) } })
        agentServer?.start()
        controller.$presenting.sink { [weak self] on in if on { self?.agents.cancelAllHeld() } }.store(in: &bag)
        controller.$recordingDND.sink { [weak self] on in if on { self?.agents.cancelAllHeld() } }.store(in: &bag)
        agents.$sessions.sink { [weak self] _ in self?.writeAgentState() }.store(in: &bag)
        agents.$pending.sink { [weak self] _ in self?.writeAgentState() }.store(in: &bag)
        log.log("agents watcher=on")
    }

    /// A held Claude approval landed: expand the notch once (Peek hidden stays hidden — the guard
    /// is on globallyVisible), home tab, the approval card on top. The request is blocked on the
    /// coach and expires; everything else waits for a hover (spec §3.1/§5).
    func considerAgentApproval() {
        guard controller.globallyVisible, !controller.presenting, !controller.recordingDND else { return }
        if let d = peekDisplayID() { controller.activeDisplay = d }
        controller.tab = .home
        controller.expand()
        log.log("agents approval=expand")
    }

    /// The watcher's state snapshot (what the sheet shows, nothing more) for debugging / proof.
    func writeAgentState() {
        guard agentsOn else { return }
        AgentRelayInstaller.writeState(sessions: agents.sessions, pending: agents.pending)
    }

    /// The live checklist + ten-minute nudge, from the gpu_window spans (no client name anywhere).
    /// One refresh-tick call; expands the notch once when the nudge is due and Peek is visible.
    /// Peek hidden stays hidden — expand() would un-hide it, so the guard is on globallyVisible.
    func considerChecklist(_ w: GPUWindow?) {
        guard let c = checklist else { return }
        let fire = c.update(spans: w?.spans ?? [], live: w?.live ?? false, now: Date())
        guard fire == .fire, controller.globallyVisible else { return }
        if let d = peekDisplayID() { controller.activeDisplay = d }
        controller.tab = .home
        controller.expand()
        log.log("checklist nudge=fire")
    }

    // ── panels ──
    func rebuildPanels() {
        let screens = NSScreen.screens.map(Screens.descriptor)
        let ids = Set(screens.map(\.uuid))
        for (id, h) in hosts where !ids.contains(id) { h.panel.orderOut(nil); hosts[id] = nil }
        for s in screens {
            if let h = hosts[s.uuid] { h.relayout(s, geometry: geometry); continue }
            let entries = profile.isEnabled(.switcher) ? AppSwitcher.entries(profile, WorkspaceLocator()) : []
            let h = PanelHost(screen: s, geometry: geometry) { [unowned self] st in
                AnyView(PeakRootView(controller: controller, cards: cards, panel: st, threePO: threePO, drops: dropsStore, voice: voice, nextSession: nextSession, running: running, light: gpuLight, checklist: checklist, agents: agents, switcher: entries, mark: mark, glow: glow,
                                     onSwitch: { [weak self] id in self?.controller.handle(.switchApp(id)) },
                                     onDrop: { [weak self] urls in self?.dropped(urls, uuid: s.uuid) ?? false }))
            }
            hosts[s.uuid] = h
            h.panel.onContextMenu = { [weak self, weak h] e in
                guard let self, let v = h?.panel.contentView else { return }
                NSMenu.popUpContextMenu(self.makeMenu(), with: e, for: v)
            }
            log.log("panel mode=\(h.layout.mode.rawValue) virtual=\(h.layout.virtualNotch) collapsed=\(Int(h.layout.collapsed.width))x\(Int(h.layout.collapsed.height)) mark=\(Int(h.layout.markRect.width))x\(Int(h.layout.markRect.height))")
        }
        syncPanels()
        statusItem?.menu = makeMenu()
    }

    /// The sheet just opened: read what is running now instead of waiting out the quiet interval.
    func noteExpansion() {
        let now = controller.expanded
        defer { wasExpanded = now }
        guard now, !wasExpanded else { return }
        running.nudge()
        Task { @MainActor in await running.tick(expanded: true) }
    }

    func isExpanded(_ uuid: String) -> Bool { controller.expanded && controller.activeDisplay == uuid }

    var lastSurface: [String: PeakLayout.Surface] = [:]
    func syncPanels() {
        for (id, h) in hosts {
            h.setVisible(controller.panelVisible(on: id))
            let e = isExpanded(id)
            h.surface = e ? (controller.tab == .threePO && profile.isEnabled(.threePO) && !controller.presenting ? .chat : .home)
                : (controller.peek != nil && controller.peekDisplay == id ? .peek : .collapsed)
            if lastSurface[id] != h.surface {
                lastSurface[id] = h.surface
                if h.surface == .chat { h.panel.makeKey(); Task { await threePO.refreshSpend() } }
            }
            if e, controller.askText != nil { h.panel.makeKey() }
        }
        updatePointer(NSEvent.mouseLocation)
        if controller.globallyVisible && cards.cards.isEmpty { refresh() }
    }

    /// Mouse-moved / dragged (global + local): click-through outside the live shell, hover in, hover-out collapse.
    /// No timers: work happens only when the pointer moves.
    func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer(NSEvent.mouseLocation) }
        }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.updatePointer(NSEvent.mouseLocation) }
            return e
        }) { mouseMonitors.append(l) }
    }

    func updatePointer(_ p: NSPoint) {
        var over: String?
        for (id, h) in hosts {
            let inside = h.state.visible && h.contains(p)
            let atEdge = h.state.visible && !inside && h.surface == .collapsed && h.layout.triggers(at: p)   // never captures a click
            if h.panel.ignoresMouseEvents == inside { h.panel.ignoresMouseEvents = !inside }
            if h.state.hovering != (inside && h.surface == .collapsed) { h.state.hovering = inside && h.surface == .collapsed }
            if inside || atEdge { over = id }
        }
        if over != hoveredDisplay {
            let was = hoveredDisplay
            hoveredDisplay = over
            if let id = over { hover(true, uuid: id) } else if let w = was { hover(false, uuid: w) }
        }
    }

    func hover(_ inside: Bool, uuid: String) {
        hoverCollapse?.cancel()
        if inside, controller.peek != nil { controller.extendPeek(); return }      // reading an alert: hold it, open only on a tap
        if inside {
            Haptic.generic()                                     // paired with the 1.02 scale + brightness lift
            if !controller.expanded {
                let w = DispatchWorkItem { [weak self] in
                    guard let self, self.hoveredDisplay == uuid, !self.controller.expanded else { return }
                    Haptic.level(); self.controller.activeDisplay = uuid; self.controller.expand()
                }
                hoverCollapse = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)   // a brush past doesn't open it
            }
        } else if controller.expanded && controller.askText == nil && controller.activeDisplay == uuid
                    && !(controller.tab == .threePO && profile.isEnabled(.threePO)) {   // the chat stays open until Collapse
            let w = DispatchWorkItem { [weak self] in self?.controller.collapse() }
            hoverCollapse = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
    }

    /// A file dropped on the shell: the drops module (title-slide fix / Dagu Shifts) takes it, describe-first.
    func dropped(_ urls: [URL], uuid: String) -> Bool {
        guard !controller.presenting else { log.log("drop refused=presenting"); return false }
        guard profile.isEnabled(.drops), let u = urls.first else { log.log("drop refused=module-off"); return false }
        log.log("drop received count=\(urls.count)")
        controller.activeDisplay = uuid
        controller.expand()
        drops?.received(u)
        return true
    }

    func screenUnderPointer() -> String? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }.map(Screens.uuid) ?? NSScreen.main.map(Screens.uuid)
    }

    // ── forceiq-peak:// (kAEGetURL). Strict parse; unknown actions ignored; only the action name is logged. ──
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return }
        if controller == nil { pendingURLs.append(raw); return }     // arrived before the profile loaded
        route(raw)
    }

    func route(_ raw: String) {
        guard let action = PeakURLRouter.parse(raw, allowedBundleIDs: profile.allowedBundleIDs) else { log.log("url ignored"); return }
        switch action {
        case .expand, .ask: if controller.activeDisplay == nil || !controller.expanded { controller.activeDisplay = screenUnderPointer() }
        default: break
        }
        controller.handle(action)
        if case .display = action { statusItem?.menu = makeMenu() }
    }

    // ── menu bar ──
    /// The menu-bar item is OFF unless settings.json `menuBarItem` is true: the wing beside the notch is the always-on status
    /// and its right-click menu holds the same actions (Chris 10.19.2026: "remove the one on the right").
    func buildStatusItem() {
        guard prefs.menuBarItem else { log.log("menu-bar item=off (right-click the wing for the menu)"); return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        applyStatusBadge()
        item.menu = makeMenu()
    }

    /// The always-on menu-bar badge: "PEEK" in green on black (gold and "PEEK · PRESENTING" while presenting).
    func applyStatusBadge() {
        guard let b = statusItem?.button else { return }
        let spec = StatusBadge.spec(presenting: controller.presenting)
        b.title = ""
        b.image = StatusBadgeImage.make(spec)
        b.imagePosition = .imageOnly
        b.setAccessibilityLabel(spec.accessibilityLabel)
        b.toolTip = spec.accessibilityLabel
    }

    func makeMenu() -> NSMenu {
        let m = NSMenu(title: "ForceIQ Peek")
        m.delegate = self
        let show = NSMenuItem(title: "Show ForceIQ Peek", action: #selector(menuToggle), keyEquivalent: "")
        show.state = controller.globallyVisible ? .on : .off
        show.target = self
        m.addItem(show)
        m.addItem(.separator())
        let header = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        for s in NSScreen.screens {
            let id = Screens.uuid(s)
            let it = NSMenuItem(title: "\(s.localizedName)\(Screens.descriptor(s).hasNotch ? " (notch)" : " (pill)")",
                                action: #selector(menuDisplay(_:)), keyEquivalent: "")
            it.representedObject = id
            it.state = controller.isDisplayShown(id) ? .on : .off
            it.target = self
            m.addItem(it)
        }
        m.addItem(.separator())
        let present = NSMenuItem(title: Presenting.menuTitle, action: #selector(menuPresenting), keyEquivalent: "")
        present.state = controller.presenting ? .on : .off
        present.target = self
        m.addItem(present)
        let dnd = NSMenuItem(title: "Do not disturb", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Do not disturb")
        for (title, tag) in [("For 1 hour", 1), ("Until tomorrow morning", 2), ("Off", 0)] {
            let it = NSMenuItem(title: title, action: #selector(menuDND(_:)), keyEquivalent: "")
            it.tag = tag; it.target = self
            sub.addItem(it)
        }
        dnd.submenu = sub
        m.addItem(dnd)
        let hk = NSMenuItem(title: "Built-in hotkey", action: #selector(menuHotkey), keyEquivalent: "")
        hk.state = controller.hotkeyEnabled ? .on : .off
        hk.target = self
        m.addItem(hk)
        let st = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        st.target = self
        m.addItem(st)
        let about = NSMenuItem(title: "About ForceIQ Peek", action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        m.addItem(about)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit ForceIQ Peek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return m
    }

    func menuWillOpen(_ menu: NSMenu) {
        for it in menu.items {
            if it.action == #selector(menuToggle) { it.state = controller.globallyVisible ? .on : .off }
            if it.action == #selector(menuHotkey) { it.state = controller.hotkeyEnabled ? .on : .off }
            if it.action == #selector(menuPresenting) { it.state = controller.presenting ? .on : .off }
            if it.action == #selector(menuDisplay(_:)), let id = it.representedObject as? String { it.state = controller.isDisplayShown(id) ? .on : .off }
        }
    }

    @objc func menuToggle() { controller.toggle() }
    @objc func menuPresenting() {
        controller.setPresenting(!controller.presenting)
        applyStatusBadge()
    }
    /// Alerts stop peeking until then (the meeting and fix cards are still on the sheet). One tap, no settings window.
    @objc func menuDND(_ sender: NSMenuItem) {
        controller.setDoNotDisturb(sender.tag == 1 ? .oneHour : sender.tag == 2 ? .tomorrowMorning : .off)
        settingsModel?.refresh()
    }
    @objc func menuHotkey() { controller.setHotkeyEnabled(!controller.hotkeyEnabled) }
    @objc func menuDisplay(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        controller.setDisplay(id, shown: !controller.isDisplayShown(id))
    }
    @objc func menuAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "ForceIQ Peek"])
    }
    @objc func menuSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "ForceIQ Peek"
            w.isReleasedWhenClosed = false
            let model = SettingsModel(prefs: prefs, controller: controller)
            settingsModel = model
            w.contentView = NSHostingView(rootView: SettingsView(model: model, controller: controller, voice: voice, setVoice: { [weak self] on in self?.setVoice(on) }))
            w.center()
            settings = w
        }
        settings?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// Stand-in for the 3PO composer + transcript text, used only to warm the text system off-screen. Holds no app state.
struct TextWarmUp: View {
    @State private var t = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $t, axis: .vertical).textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
            Text("Warm").font(.system(size: 13)); Text("Warm").font(.system(size: 12, weight: .semibold))
            Text("$0").font(.system(size: 12, weight: .heavy).monospacedDigit())
            ScrollView { Text("Warm").font(.system(size: 13)) }.frame(height: 40)
        }
        .padding(16)
    }
}

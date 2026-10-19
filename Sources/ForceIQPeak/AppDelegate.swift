import AppKit
import Combine
import CoreGraphics
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
}

enum Screens {
    static func uuid(_ s: NSScreen) -> String {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let u = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(n.uint32Value))?.takeRetainedValue(),
              let str = CFUUIDCreateString(nil, u) as String? else { return "UNKNOWN-\(s.localizedName)" }
        return str.uppercased()
    }
    static func descriptor(_ s: NSScreen) -> ScreenDescriptor {
        ScreenDescriptor(uuid: uuid(s), name: s.localizedName, frame: s.frame, safeAreaTop: s.safeAreaInsets.top,
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
    let mark: GhostMarkRendering = VideoGhostMarkRenderer()
    lazy var glow: GhostGlowRendering = ShaderGlowRenderer.available ? ShaderGlowRenderer() : NativeGlowRenderer()
    var profile = CoachProfile.none
    var prefs: PeakPrefs!
    var controller: PeakController!
    var performer: Performer!
    var cards: CardStackViewModel!
    var hosts: [String: PanelHost] = [:]
    var statusItem: NSStatusItem?
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
        GhostAssets.format = prefs.ghostFormat
        controller = PeakController(prefs: prefs, profile: p, hotkey: KeyboardShortcutsHotkey(name: PeakHotkeyName.make(p)), logger: log)
        performer = Performer(engine: engine, demo: demo)
        cards = CardStackViewModel(performer: performer, logger: log)
        threePO = ThreePOStore(transport: demo ? DemoThreePOTransport(knobs: demoKnobs) : engine, session: "peak-\(p.coachID)", logger: log)
        threePO.onCopy = { [weak self] s in self?.performer.copy(s) }
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
        if p.isEnabled(.threePO) { Task { await threePO.loadModels(); await threePO.refreshSpend() } }
        log.log("launch profile=\(source) configured=\(p.configured ? "yes" : "no") modules=\(PeakModuleID.allCases.filter { p.isEnabled($0) }.map(\.rawValue).joined(separator: ",")) demo=\(demo ? "on" : "off") glow=\(ShaderGlowRenderer.available ? "metal" : "native") mark=\(GhostAssets.pack.map { $0.pack.replacingOccurrences(of: " ", with: "_") } ?? "placeholder") format=\(GhostAssets.format.rawValue)")
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
            DispatchQueue.main.async { self?.syncPanels() }
        }.store(in: &bag)
        installMouseMonitors()
        refresh()
        poll = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        let queued = pendingURLs; pendingURLs = []
        for u in queued { route(u) }
        if demo && ProcessInfo.processInfo.environment["FORCEIQ_PEAK_DEMO_TOUR"] == "1" { tour() }
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

    func refresh() {
        if demo { cards.update(DemoData.snapshot(), profile: profile); return }
        guard controller.globallyVisible else { return }
        Task { @MainActor in
            let s = await engine.snapshot()
            cards.update(s, profile: profile)
            log.log("feed meeting=\(s.meeting != nil ? "yes" : "no") fixes=\(s.fixes.count) approvals=\(s.approvals.count) family=\(s.familyEnabled ? "on" : "off") ghost=\(cards.ghost.rawValue)")
        }
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
                AnyView(PeakRootView(controller: controller, cards: cards, panel: st, threePO: threePO, drops: dropsStore, switcher: entries, mark: mark, glow: glow,
                                     onSwitch: { [weak self] id in self?.controller.handle(.switchApp(id)) },
                                     onDrop: { [weak self] urls in self?.dropped(urls, uuid: s.uuid) ?? false }))
            }
            hosts[s.uuid] = h
            log.log("panel mode=\(h.layout.mode.rawValue)")
        }
        syncPanels()
        statusItem?.menu = makeMenu()
    }

    func isExpanded(_ uuid: String) -> Bool { controller.expanded && controller.activeDisplay == uuid }

    var lastSurface: [String: PeakLayout.Surface] = [:]
    func syncPanels() {
        for (id, h) in hosts {
            h.setVisible(controller.panelVisible(on: id))
            let e = isExpanded(id)
            h.surface = e ? (controller.tab == .threePO && profile.isEnabled(.threePO) ? .chat : .home) : .collapsed
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
            if h.panel.ignoresMouseEvents == inside { h.panel.ignoresMouseEvents = !inside }
            if h.state.hovering != (inside && h.surface == .collapsed) { h.state.hovering = inside && h.surface == .collapsed }
            if inside { over = id }
        }
        if over != hoveredDisplay {
            let was = hoveredDisplay
            hoveredDisplay = over
            if let id = over { hover(true, uuid: id) } else if let w = was { hover(false, uuid: w) }
        }
    }

    func hover(_ inside: Bool, uuid: String) {
        hoverCollapse?.cancel()
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
    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Peak"
        item.button?.toolTip = "ForceIQ Peak"
        item.menu = makeMenu()
        statusItem = item
    }

    func makeMenu() -> NSMenu {
        let m = NSMenu(title: "ForceIQ Peak")
        m.delegate = self
        let show = NSMenuItem(title: "Show ForceIQ Peak", action: #selector(menuToggle), keyEquivalent: "")
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
        let hk = NSMenuItem(title: "Built-in hotkey", action: #selector(menuHotkey), keyEquivalent: "")
        hk.state = controller.hotkeyEnabled ? .on : .off
        hk.target = self
        m.addItem(hk)
        let st = NSMenuItem(title: "Shortcut…", action: #selector(menuSettings), keyEquivalent: ",")
        st.target = self
        m.addItem(st)
        let about = NSMenuItem(title: "About ForceIQ Peak", action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        m.addItem(about)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit ForceIQ Peak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return m
    }

    func menuWillOpen(_ menu: NSMenu) {
        for it in menu.items {
            if it.action == #selector(menuToggle) { it.state = controller.globallyVisible ? .on : .off }
            if it.action == #selector(menuHotkey) { it.state = controller.hotkeyEnabled ? .on : .off }
            if it.action == #selector(menuDisplay(_:)), let id = it.representedObject as? String { it.state = controller.isDisplayShown(id) ? .on : .off }
        }
    }

    @objc func menuToggle() { controller.toggle() }
    @objc func menuHotkey() { controller.setHotkeyEnabled(!controller.hotkeyEnabled) }
    @objc func menuDisplay(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        controller.setDisplay(id, shown: !controller.isDisplayShown(id))
    }
    @objc func menuAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "ForceIQ Peak"])
    }
    @objc func menuSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "ForceIQ Peak"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(controller: controller))
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

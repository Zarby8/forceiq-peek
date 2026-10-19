import AppKit
import PeakCore
import SwiftUI

// The dry-run window: the plan for one client, live step status, and a big STOP while it runs. Locate and report only.

@MainActor final class DryRunModel: ObservableObject {
    enum Status: Equatable { case pending, running, located(String), notFound(String), stopped, skipped, armed(Int), pressed(String) }
    let client: String
    let action: String
    let steps: [DryRunStep]
    let live: Bool
    let stop = StopSwitch()
    @Published var status: [Int: Status] = [:]
    @Published var running = true
    @Published var summary: String?
    /// Cua backend only: the approval card the presser is waiting on (what Cua will do, what it touches). Run approves it.
    @Published var cuaCard: CuaApprovalCard?
    var onCuaDecision: ((Bool) -> Void)?
    var stopPressedAt: Date?

    init(client: String, action: String, steps: [DryRunStep], live: Bool = false) {
        self.client = client; self.action = action; self.steps = steps; self.live = live
        for s in steps { status[s.id] = .pending }
    }

    func pressStop() {
        guard running else { return }
        stopPressedAt = Date()
        stop.press(at: stopPressedAt!)
    }

    func apply(_ e: DryRunEvent) {
        switch e {
        case .stepStarted(let i): status[i] = .running
        case .broughtForward(let i, let note): status[i] = .located(note)
        case .pressArmed(let i, let ms): status[i] = .armed(ms)
        case .pressSkipped(let i, let why): status[i] = .notFound(why)
        case .pressed(let i, let p): status[i] = p.pressed ? .pressed(p.detail) : (p.stopped ? .stopped : .notFound(p.detail))
        case .attempt(let i, let a):
            if a.found { status[i] = .located("\(a.strategy.rawValue): \(a.detail)") }
            else if a.stopped { status[i] = .stopped }
            else { status[i] = .notFound("\(a.strategy.rawValue): \(a.detail)") }
        case .stopped(let r):
            for s in steps where s.id >= r.step {
                if s.id == r.step && r.phase != .betweenSteps {
                    if case .located = status[s.id] ?? .pending { if r.phase == .duringStep { continue } }
                    if case .pressed = status[s.id] ?? .pending { continue }
                    status[s.id] = .stopped
                } else {
                    status[s.id] = .skipped
                }
            }
        default: break
        }
    }

    func finish(_ r: DryRunReport) { running = false; summary = r.summary; cuaCard = nil }

    func showCua(_ card: CuaApprovalCard) { cuaCard = card }
    /// The card's Run: an explicit tap, the only way a Cua run is approved.
    func approveCua() {
        guard let c = cuaCard else { return }
        let ok = CuaWiring.shared.desk.approve(cardID: c.id, source: .tap)
        cuaCard = nil
        onCuaDecision?(ok)
    }
    func declineCua() {
        guard let c = cuaCard else { return }
        CuaWiring.shared.desk.decline(cardID: c.id)
        cuaCard = nil
        onCuaDecision?(false)
    }
}

struct DryRunView: View {
    @ObservedObject var model: DryRunModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(model.live ? "Desktop action (live)" : "Desktop dry run") · \(model.client)").font(.system(size: 15, weight: .heavy)).foregroundStyle(.white)
                Spacer()
                if model.running {
                    Button(action: { model.pressStop() }) {
                        Text("STOP").font(.system(size: 18, weight: .black)).foregroundStyle(.white)
                            .padding(.horizontal, 22).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.red))
                    }
                    .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel("STOP").accessibilityIdentifier("peak-dryrun-stop")
                } else {
                    Button("Close", action: onClose).accessibilityIdentifier("peak-dryrun-close")
                }
            }
            Text(model.live
                 ? "Presses FLOW's 'Code Window' menu item for \(model.client)'s package after the checks. Nothing else is clicked or typed. STOP or Esc halts it."
                 : "Locate and report only. Nothing is clicked, typed, opened or booked\(model.action.hasPrefix("flow") ? "; FLOW may come forward" : "").")
                .font(.system(size: 11)).foregroundStyle(Color.white)
            ForEach(model.steps) { s in
                HStack(alignment: .top, spacing: 8) {
                    Text(icon(model.status[s.id] ?? .pending)).font(.system(size: 13, weight: .bold)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(s.id). \(s.title)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        if let d = detail(model.status[s.id] ?? .pending) {
                            Text(d).font(.system(size: 10.5)).foregroundStyle(Color.white).lineLimit(3)
                        }
                    }
                }
            }
            if let card = model.cuaCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.title).font(.system(size: 13, weight: .heavy)).foregroundStyle(.white)
                    Text("What it does: " + card.does).font(.system(size: 11)).foregroundStyle(Color.white)
                    Text("What it touches: " + card.touches).font(.system(size: 11)).foregroundStyle(Color.white)
                    HStack(spacing: 10) {
                        Button(action: { model.approveCua() }) {
                            Text("Run").font(.system(size: 14, weight: .black)).foregroundStyle(.black)
                                .padding(.horizontal, 20).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.peakGold))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Run").accessibilityIdentifier("peak-cua-run")
                        Button("Cancel", action: { model.declineCua() }).accessibilityIdentifier("peak-cua-cancel")
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).stroke(Color.peakGold, lineWidth: 1.5))
            }
            if let s = model.summary {
                Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.peakGold).lineLimit(5)
            }
        }
        .padding(16).frame(width: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(model.running ? Color.red : Color.peakGold, lineWidth: 2))
    }

    func icon(_ s: DryRunModel.Status) -> String {
        switch s { case .pending: return "·"; case .running: return "…"; case .located: return "✓"; case .notFound: return "✗"
        case .stopped: return "■"; case .skipped: return "–"; case .armed: return "⏱"; case .pressed: return "●" }
    }
    func detail(_ s: DryRunModel.Status) -> String? {
        switch s { case .located(let d), .notFound(let d), .pressed(let d): return d; case .stopped: return "stopped"; case .skipped: return "skipped (STOP)"
        case .armed(let ms): return "press armed: pressing in \(ms) ms unless STOP"
        default: return nil }
    }
}

/// A floating, non-activating panel at the top right of the main display, so STOP stays visible over FLOW / Command.
@MainActor final class DryRunPanel {
    let panel: NSPanel
    private var escMonitors: [Any] = []
    init(model: DryRunModel, onClose: @escaping () -> Void) {
        let host = NSHostingView(rootView: DryRunView(model: model, onClose: onClose))
        let size = NSSize(width: 520, height: 470)
        let scr = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel = NSPanel(contentRect: NSRect(x: scr.maxX - size.width - 24, y: scr.maxY - size.height - 24, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .statusBar; panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.title = "Peek desktop dry run"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.orderFrontRegardless()
        // Esc = STOP even while FLOW (not this non-activating panel) has the keyboard: observe key-downs only (a monitor
        // never sends or alters an event), for as long as the panel is up.
        let esc: (NSEvent) -> Void = { [weak model] e in
            guard e.keyCode == 53 else { return }
            MainActor.assumeIsolated { model?.pressStop() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: esc) { escMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in esc(e); return e }) { escMonitors.append(l) }
    }
    func close() {
        escMonitors.forEach { NSEvent.removeMonitor($0) }; escMonitors = []
        panel.orderOut(nil)
    }
}

import AppKit
import PeakCore
import SwiftUI

// The dry-run window: the plan for one client, live step status, and a big STOP while it runs. Locate and report only.

@MainActor final class DryRunModel: ObservableObject {
    enum Status: Equatable { case pending, running, located(String), notFound(String), stopped, skipped }
    let client: String
    let action: String
    let steps: [DryRunStep]
    let stop = StopSwitch()
    @Published var status: [Int: Status] = [:]
    @Published var running = true
    @Published var summary: String?
    var stopPressedAt: Date?

    init(client: String, action: String, steps: [DryRunStep]) {
        self.client = client; self.action = action; self.steps = steps
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
        case .attempt(let i, let a):
            if a.found { status[i] = .located("\(a.strategy.rawValue): \(a.detail)") }
            else if a.stopped { status[i] = .stopped }
            else { status[i] = .notFound("\(a.strategy.rawValue): \(a.detail)") }
        case .stopped(let r):
            for s in steps where s.id >= r.step {
                if s.id == r.step && r.phase == .duringStep {
                    if case .located = status[s.id] ?? .pending { continue }
                    status[s.id] = .stopped
                } else {
                    status[s.id] = .skipped
                }
            }
        default: break
        }
    }

    func finish(_ r: DryRunReport) { running = false; summary = r.summary }
}

struct DryRunView: View {
    @ObservedObject var model: DryRunModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Desktop dry run · \(model.client)").font(.system(size: 15, weight: .heavy)).foregroundStyle(.white)
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
            Text("Locate and report only. Nothing is clicked, typed, opened or booked\(model.action.hasPrefix("flow") ? "; FLOW may come forward" : "").")
                .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.8))
            ForEach(model.steps) { s in
                HStack(alignment: .top, spacing: 8) {
                    Text(icon(model.status[s.id] ?? .pending)).font(.system(size: 13, weight: .bold)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(s.id). \(s.title)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        if let d = detail(model.status[s.id] ?? .pending) {
                            Text(d).font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.75)).lineLimit(3)
                        }
                    }
                }
            }
            if let s = model.summary {
                Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(red: 0.96, green: 0.77, blue: 0.26)).lineLimit(5)
            }
        }
        .padding(16).frame(width: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(model.running ? Color.red : Color.gray, lineWidth: 2))
    }

    func icon(_ s: DryRunModel.Status) -> String {
        switch s { case .pending: return "·"; case .running: return "…"; case .located: return "✓"; case .notFound: return "✗"
        case .stopped: return "■"; case .skipped: return "–" }
    }
    func detail(_ s: DryRunModel.Status) -> String? {
        switch s { case .located(let d), .notFound(let d): return d; case .stopped: return "stopped"; case .skipped: return "skipped (STOP)"
        default: return nil }
    }
}

/// A floating, non-activating panel at the top right of the main display, so STOP stays visible over FLOW / Command.
@MainActor final class DryRunPanel {
    let panel: NSPanel
    init(model: DryRunModel, onClose: @escaping () -> Void) {
        let host = NSHostingView(rootView: DryRunView(model: model, onClose: onClose))
        let size = NSSize(width: 520, height: 330)
        let scr = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel = NSPanel(contentRect: NSRect(x: scr.maxX - size.width - 24, y: scr.maxY - size.height - 24, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .statusBar; panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.title = "Peak desktop dry run"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.orderFrontRegardless()
    }
    func close() { panel.orderOut(nil) }
}

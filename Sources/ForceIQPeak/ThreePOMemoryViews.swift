import AppKit
import PeakCore
import SwiftUI

// 3PO memory + skill cards. Bright on black: pure white text, gold #F5C542 and green #5BE37D accents, every element at
// full opacity (no gray, no dim text, no half-faded buttons; a disabled button is PeakButton's gold outline + white label).

extension Color {
    init(memory hex: UInt32) { self.init(hex: hex) }
}

/// Chat | Memory: the 3PO tab's two panes (gold pill = showing).
struct PanePills: View {
    @ObservedObject var store: ThreePOStore
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 2) {
            pill(.chat, "Chat")
            pill(.memory, "Memory")
        }
        .padding(2)
        .overlay(Capsule().stroke(Color(memory: MemoryStyle.activePillHex), lineWidth: 1))
        .animation(Motion.spring(reduceMotion), value: store.pane)
    }

    func pill(_ p: ThreePOStore.Pane, _ title: String) -> some View {
        let on = store.pane == p
        return Button {
            Haptic.tick()
            store.pane = p
            if p == .memory { Task { await store.loadMemory() } }
        } label: {
            Text(title).font(.system(size: 11, weight: .heavy))
                .foregroundStyle(on ? Color.black : Color.white)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background { if on { Capsule().fill(Color(memory: MemoryStyle.activePillHex)).matchedGeometryEffect(id: "pane", in: ns) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// This coach's memory: client sections (gold titles), General (green), and, on request, Forgotten (gold tag, still
/// white text at full brightness). Forget is a soft mark; the local file is never deleted.
struct MemoryPanel: View {
    @ObservedObject var store: ThreePOStore
    var scrolls = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(store.memory.active.count) remembered").font(.system(size: 12, weight: .heavy)).foregroundStyle(Color.white)
                if !store.memory.forgotten.isEmpty {
                    Text("\(store.memory.forgotten.count) forgotten").font(.system(size: 12, weight: .heavy)).foregroundStyle(Color.peakGold)
                }
                Spacer()
                PeakButton(title: store.showForgotten ? "Hide forgotten" : "Show forgotten", color: .peakGold, enabled: !store.memory.forgotten.isEmpty) {
                    store.showForgotten.toggle()
                }
            }
            Text("Only on this Mac, for this coach. Say \u{201C}remember …\u{201D} to 3PO to add a fact.")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white)
            Rectangle().fill(Color.peakGreen).frame(height: 1)
            if scrolls {
                ScrollView { list }.scrollIndicators(.never)
            } else {
                list
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder var list: some View {
        let sections = store.memory.sections(showForgotten: store.showForgotten)
        LazyVStack(alignment: .leading, spacing: 12) {
            switch store.memoryLoad {
            case .failed(let m): Text(m).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.peakGold)
            case .loading where store.memory.facts.isEmpty: ThinkingDots()
            default: EmptyView()
            }
            if sections.isEmpty && store.memoryLoad == .loaded {
                Text("Nothing remembered yet. Try: remember a client's games are on Saturdays.")
                    .font(.system(size: 12)).foregroundStyle(Color.white)
            }
            ForEach(sections) { sec in
                VStack(alignment: .leading, spacing: 6) {
                    Text(sec.title).font(.system(size: 13, weight: .heavy)).foregroundStyle(Color(memory: MemoryStyle.titleHex(sec.kind)))
                    ForEach(sec.facts) { f in MemoryRow(fact: f, store: store) }
                }
            }
        }
        .animation(Motion.spring(reduceMotion), value: store.memory)
    }
}

struct MemoryRow: View {
    let fact: MemoryFact
    @ObservedObject var store: ThreePOStore
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle().fill(fact.forgotten ? Color.peakGold : Color.peakGreen).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(fact.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if !fact.savedLabel.isEmpty { Text("Saved \(fact.savedLabel)").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.white) }
                    if fact.forgotten {
                        Text("Forgotten").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.black)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.peakGold))
                    }
                }
            }
            Spacer(minLength: 8)
            if !fact.forgotten {
                PeakButton(title: store.forgetting.contains(fact.id) ? "…" : "Forget", color: .peakGold, enabled: !store.forgetting.contains(fact.id)) {
                    Task { await store.forget(fact.id) }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(fact.forgotten ? Color.peakGold : Color.peakGreen, lineWidth: 1))
    }
}

/// A remember answer whose client was unclear: tap-to-pick from this coach's roster (never typed IDs).
struct MemoryPickRow: View {
    let message: ChatMessage
    let event: MemoryEvent
    @ObservedObject var store: ThreePOStore
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WHICH CLIENT?").font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.peakGreen)
            FlowRow(items: event.candidates) { c in
                PeakButton(title: c, color: .peakGold, enabled: !store.transcript.streaming) { Task { await store.pickMemoryClient(c, for: message.id) } }
            }
        }
    }
}

/// A row of buttons that wraps.
struct FlowRow<Content: View>: View {
    let items: [String]
    let content: (String) -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: items.count, by: 3)), id: \.self) { i in
                HStack(spacing: 6) { ForEach(items[i..<min(i + 3, items.count)], id: \.self) { content($0) } }
            }
        }
    }
}

/// A 3PO skill: the description first (what it is, inputs, what it touches, outputs), then Run / Ask Claude / Copy
/// prompt. Run is the only thing that runs it. A refused skill is view-only and opens in GOAT.
struct SkillCardView: View {
    let card: SkillCard
    @ObservedObject var store: ThreePOStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var phase: SkillPhase { store.skillPhases[card.id] ?? .described }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(card.name).font(.system(size: 13, weight: .heavy)).foregroundStyle(Color.white).lineLimit(1)
                Text(card.kindLabel).font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.black)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(card.kind == "prompt" ? Color.peakGold : Color.peakGreen))
                Spacer()
                Text(card.viewOnly ? (card.status == "refused" ? "View only" : "Needs input") : "Skill").font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(card.viewOnly ? Color.peakGold : Color.peakGreen)
            }
            if let c = card.client {
                Text(c).font(.system(size: 12, weight: .heavy)).foregroundStyle(Color.peakGold)
            }
            Text(card.description).font(.system(size: 12)).foregroundStyle(Color.white).fixedSize(horizontal: false, vertical: true)
            section("Inputs", card.inputs.isEmpty ? ["None"] : card.inputs.map { i in "\(i.key): \(i.value ?? i.help)" })
            section("What it touches", card.touches.isEmpty ? ["Nothing"] : card.touches)
            if !card.outputs.isEmpty { section("Outputs", card.outputs) }
            if !card.message.isEmpty {
                Text(card.message).font(.system(size: 11, weight: .semibold)).foregroundStyle(card.viewOnly ? Color.peakGold : Color.white)
            }
            if card.needsClientPick {
                Text("PICK THE CLIENT").font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.peakGreen)
                FlowRow(items: card.candidates) { c in
                    PeakButton(title: c, color: .peakGold, enabled: !store.transcript.streaming) { Task { await store.pickSkillClient(card.id, client: c) } }
                }
            }
            buttons.id(phaseKey).transition(.slideUpFull(reduceMotion))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(card.viewOnly ? Color.peakGold : Color.peakGreen, lineWidth: 1))
        .animation(Motion.spring(reduceMotion), value: phase)
    }

    var phaseKey: String {
        switch phase { case .described: return "d"; case .running: return "r"; case .done: return "ok"; case .failed: return "f" }
    }

    @ViewBuilder var buttons: some View {
        switch phase {
        case .described, .failed:
            HStack(spacing: 8) {
                if card.status == "refused" {
                    PeakButton(title: "Open in GOAT", color: .peakGold) { _ = AppLauncher.activateGOAT() }
                } else {
                    PeakButton(title: "Run", color: .peakGreen, filled: true, enabled: card.canRun && !store.transcript.streaming) {
                        Task { await store.runSkill(card.id) }
                    }
                }
                PeakButton(title: "Ask Claude", color: .peakGold, enabled: !store.transcript.streaming) { Task { await store.askSkill(card.id) } }
                PeakButton(title: "Copy prompt", color: .peakGold) { store.copySkill(card.id) }
            }
            if case .failed(let m) = phase { Text(m).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.peakGold) }
        case .running:
            HStack(spacing: 8) { ThinkingDots(); Text("Running \(card.name)…").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white) }
        case .done:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.peakGreen)
                Text("Ran. The answer is below.").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white)
            }
        }
    }

    func section(_ t: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.peakGreen)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l).font(.system(size: 11)).foregroundStyle(Color.white).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// ───────────────────────────── snapshot (visual proof; env-gated, quits itself) ─────────────────────────────
/// FORCEIQ_PEAK_SNAPSHOT=<dir>: after launch, load this coach's memory and skill cards through the normal transport,
/// render the Memory pane and the chat (with its skill cards) to PNGs with ImageRenderer, then quit. Never sends a
/// chat turn of its own beyond FORCEIQ_PEAK_SNAPSHOT_SKILL (a zero-token description card); it never taps Run.
@MainActor enum PeakSnapshot {
    static var dir: URL? {
        guard let d = ProcessInfo.processInfo.environment["FORCEIQ_PEAK_SNAPSHOT"], !d.isEmpty else { return nil }
        return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func run(store: ThreePOStore, log: (String) -> Void) async {
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await store.loadMemory()
        if let slug = ProcessInfo.processInfo.environment["FORCEIQ_PEAK_SNAPSHOT_SKILL"], !slug.isEmpty {
            await store.describeSkill(slug)
        }
        store.showForgotten = true
        write(AnyView(MemoryPanel(store: store, scrolls: false)), "3po-memory.png", dir: dir, log: log)
        let chat = VStack(alignment: .leading, spacing: 10) {
            ForEach(store.transcript.messages) { m in
                MessageRow(message: m, store: store, avatar: StaticDroidAvatar(), last: false)
            }
        }
        write(AnyView(chat), "3po-skill-card.png", dir: dir, log: log)
    }

    static func write(_ v: AnyView, _ name: String, dir: URL, log: (String) -> Void) {
        let r = ImageRenderer(content: v.frame(width: 560).padding(16).background(Color.black).environment(\.colorScheme, .dark))
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { log("snapshot failed name=\(name)"); return }
        try? png.write(to: dir.appendingPathComponent(name))
        log("snapshot wrote name=\(name)")
    }
}

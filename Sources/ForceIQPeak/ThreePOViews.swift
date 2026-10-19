import AppKit
import PeakCore
import SwiftUI

// ───────────────────────────── 3PO avatar slot ─────────────────────────────
/// The droid in the chat header (live) and beside each reply (still). Default: AnimatedThreePOAvatar (ThreePOAvatar.swift:
/// the rig, then BOB Motion's rendered loops, then this static mark). StaticDroidAvatar is the last fallback.
@MainActor protocol ThreePOAvatarRendering {
    func avatar(size: CGFloat, signals: AvatarSignals, live: Bool, reduceMotion: Bool) -> AnyView
    func still(size: CGFloat) -> AnyView
}

@MainActor struct StaticDroidAvatar: ThreePOAvatarRendering {
    func avatar(size: CGFloat, signals: AvatarSignals, live: Bool, reduceMotion: Bool) -> AnyView { still(size: size) }
    func still(size: CGFloat) -> AnyView { AnyView(DroidMark().frame(width: size, height: size)) }
}

/// Original geometric droid glyph, Brand gold on black: a rounded-square head with one wide visor slot and a single
/// lens, two side bolts and a short mast. Deliberately not humanoid (no face, no round eyes, no plating).
struct DroidMark: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let gold = GraphicsContext.Shading.color(.peakGold)
            let u = s / 24
            // mast + tip
            ctx.fill(Path(roundedRect: CGRect(x: 11.25 * u, y: 1.5 * u, width: 1.5 * u, height: 3.5 * u), cornerRadius: 0.75 * u), with: gold)
            ctx.fill(Path(ellipseIn: CGRect(x: 10.25 * u, y: 0.5 * u, width: 3.5 * u, height: 2.5 * u)), with: gold)
            // head
            let head = CGRect(x: 3.5 * u, y: 5 * u, width: 17 * u, height: 15 * u)
            ctx.fill(Path(roundedRect: head, cornerRadius: 5 * u, style: .continuous), with: gold)
            // visor slot (black) + lens (gold)
            let visor = CGRect(x: 6 * u, y: 9.5 * u, width: 12 * u, height: 4.5 * u)
            ctx.fill(Path(roundedRect: visor, cornerRadius: 2.25 * u, style: .continuous), with: .color(.black))
            ctx.fill(Path(ellipseIn: CGRect(x: 13.2 * u, y: 10.3 * u, width: 2.9 * u, height: 2.9 * u)), with: gold)
            // side bolts
            ctx.fill(Path(roundedRect: CGRect(x: 1.5 * u, y: 10.5 * u, width: 2.5 * u, height: 3.5 * u), cornerRadius: 1 * u), with: gold)
            ctx.fill(Path(roundedRect: CGRect(x: 20 * u, y: 10.5 * u, width: 2.5 * u, height: 3.5 * u), cornerRadius: 1 * u), with: gold)
            // grille: three short black bars
            for i in 0..<3 {
                ctx.fill(Path(roundedRect: CGRect(x: (9 + Double(i) * 2.4) * u, y: 16 * u, width: 1.4 * u, height: 1.8 * u), cornerRadius: 0.5 * u),
                         with: .color(.black))
            }
        }
        .accessibilityLabel("3PO")
    }
}

// ───────────────────────────── thinking / Opus ─────────────────────────────
/// Three gold dots (KeyframeAnimator). Mounted only while 3PO is thinking, so it never runs at idle.
struct ThinkingDots: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Color.peakGold).frame(width: 6, height: 6)
                    .keyframeAnimator(initialValue: Dot(), repeating: true) { v, d in
                        v.scaleEffect(d.scale).offset(y: d.y)
                    } keyframes: { _ in
                        KeyframeTrack(\.y) {
                            LinearKeyframe(0, duration: max(0.001, Double(i) * 0.14))
                            SpringKeyframe(-5, duration: 0.22, spring: .snappy)
                            SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                            LinearKeyframe(0, duration: 0.5 - Double(i) * 0.14)
                        }
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(1, duration: max(0.001, Double(i) * 0.14))
                            CubicKeyframe(1.25, duration: 0.22)
                            CubicKeyframe(1, duration: 0.3)
                            LinearKeyframe(1, duration: 0.5 - Double(i) * 0.14)
                        }
                    }
            }
        }
        .accessibilityLabel("3PO is thinking")
    }
    struct Dot { var y = 0.0; var scale = 1.0 }
}

/// 'Consulting Opus': a gold chip that breathes while the advisor works (mounted only then).
struct ConsultingOpusChip: View {
    let reduceMotion: Bool
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
            Text("Consulting Opus").font(.system(size: 11, weight: .heavy))
        }
        .foregroundStyle(Color.black)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.peakGold))
        .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.0]) { v, p in
            v.shadow(color: Color.peakGold.opacity(0.35 + 0.65 * p), radius: 3 + 7 * p)
        } animation: { _ in .easeInOut(duration: 0.6) }
    }
}

/// One gold ring bloom around the avatar each time Opus was consulted (trigger-driven; stops by itself).
struct OpusPulse: ViewModifier {
    let trigger: Int
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        content.overlay {
            Circle().stroke(Color.peakGold, lineWidth: 2)
                .keyframeAnimator(initialValue: Ring(), trigger: trigger) { v, r in
                    v.scaleEffect(r.scale).opacity(reduceMotion ? 0 : r.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) { LinearKeyframe(1.0, duration: 0.01); CubicKeyframe(1.9, duration: 0.7) }
                    KeyframeTrack(\.opacity) { LinearKeyframe(1.0, duration: 0.01); CubicKeyframe(0.0, duration: 0.7) }
                }
                .allowsHitTesting(false)
        }
    }
    struct Ring { var scale = 1.0; var opacity = 0.0 }
}

// ───────────────────────────── model pills (gold active pill; ⌘0 Auto, ⌘1 Haiku, ⌘2 Sonnet, ⌘3 Opus) ─────────────────────────────
struct ModelPills: View {
    @ObservedObject var store: ThreePOStore
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 2) {
            ForEach(store.transcript.models.rows, id: \.pick) { r in
                let on = store.pick == r.pick
                Button {
                    guard r.available else { return }
                    Haptic.tick()
                    Task { await store.choose(r.pick) }
                } label: {
                    Text(r.label).font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(on ? Color.black : (r.available ? Color.white : Color.peakGold))
                        .strikethrough(!r.available, color: .peakGold)
                        .lineLimit(1).fixedSize()                 // the taller target must never let a label wrap
                        .padding(.horizontal, 9)
                        .frame(minWidth: PeakMotion.minTapTarget, minHeight: PeakMotion.minTapTarget)
                        .background { if on { Capsule().fill(Color.peakGold).matchedGeometryEffect(id: "pick", in: ns) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(r.pick.digit), modifiers: .command)
                .allowsHitTesting(r.available)          // unavailable: gold + struck through at full opacity, never dimmed
                .help(r.available ? "\(r.label) (⌘\(r.pick.digit))" : (r.reason ?? "unavailable"))
            }
        }
        .padding(2)
        .overlay(Capsule().stroke(Color.peakGold, lineWidth: 1))
        .animation(Motion.spring(reduceMotion), value: store.pick)
    }
}

// ───────────────────────────── spend meter ─────────────────────────────
struct SpendMeter: View {
    let spend: SpendDoc
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch spend.accountState {
            case .hidden: EmptyView()
            case .hint(let h):
                Text(h).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white).lineLimit(1)
            case .shown(let a):
                line(title: "Anthropic", a, big: true)
                HStack(spacing: 10) {
                    ForEach(a.byFamily, id: \.0) { f in
                        Text("\(f.0.capitalized) \(usd(f.1))").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(Color.white)
                    }
                }
            }
            if let p = spend.peak { line(title: "Peek", p, big: false) }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: spend.peak?.totalUSD)
    }

    func line(title: String, _ l: SpendDoc.Line, big: Bool) -> some View {
        let tint: Color = l.warn ? .peakGold : .peakGreen
        return HStack(spacing: 8) {
            Text(title).font(.system(size: big ? 12 : 11, weight: .heavy)).foregroundStyle(Color.white).frame(width: 66, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().stroke(tint, lineWidth: 1)
                    Capsule().fill(tint).frame(width: max(4, g.size.width * min(1, l.fraction)))
                }
            }
            .frame(height: big ? 6 : 4)
            SwapText(text: "\(usd(l.totalUSD)) / \(usd(l.budgetUSD))", font: .system(size: big ? 12 : 11, weight: .heavy).monospacedDigit(),
                     color: l.warn ? Color.peakGold : Color.white)     // digits roll up at full opacity (numericText cross-fades them)
        }
    }

    func usd(_ v: Double) -> String { v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v) }
}

// ───────────────────────────── chat ─────────────────────────────
struct ThreePOView: View {
    @ObservedObject var store: ThreePOStore
    let profile: CoachProfile
    let askSeq: Int                                         // bumps on every ask link (the store holds the prefilled text)
    var live = true                                         // AvatarPolicy.live (expanded, visible, no Reduce Motion)
    @ObservedObject var voice: VoiceController
    var avatar: ThreePOAvatarRendering = AnimatedThreePOAvatar()
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Listening, finishing, or the final words still showing in the field.
    var dictating: Bool { voice.enabled && (voice.phase.isListening || voice.phase == .finishing || voice.handing) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                avatar.avatar(size: 32, signals: AvatarSignals.from(store.transcript, voiceEnabled: voice.enabled, micOn: store.micOn),
                              live: live, reduceMotion: reduceMotion)
                    .modifier(OpusPulse(trigger: store.transcript.opusPulses, reduceMotion: reduceMotion))
                Text("3PO").font(.system(size: 14, weight: .heavy)).foregroundStyle(Color.peakGold)
                ModelPills(store: store)
                PanePills(store: store)
                Spacer()
                if store.transcript.consultingOpus { ConsultingOpusChip(reduceMotion: reduceMotion).transition(.arrivalPop(reduceMotion)) }
            }
            .animation(Motion.quick(reduceMotion), value: store.transcript.consultingOpus)
            if profile.isEnabled(.spend) { SpendMeter(spend: store.transcript.spend) }
            Rectangle().fill(Color.peakGold).frame(height: 1)
            if store.pane == .memory {
                MemoryPanel(store: store).transition(.slideUpFull(reduceMotion))
            } else {
                chat
            }
        }
        .background {
            // ⌘K: focus the composer (switching back to Chat first). No label, no hit area: a keyboard path only.
            Button("") {
                if store.pane != .chat { withAnimation(Motion.spring(reduceMotion)) { store.pane = .chat } }
                DispatchQueue.main.async { focused = true }
            }
            .keyboardShortcut("k", modifiers: .command)
            .buttonStyle(.plain).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .onAppear { focused = true }
        .onChange(of: askSeq) { _, _ in focused = true }    // an ask link while open: focus the prefilled field, never send
    }

    @ViewBuilder var chat: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if store.transcript.messages.isEmpty {
                            Text("Ask 3PO about a client, a stuck job or a fix. Nothing runs unless you tap Run, then Confirm.")
                                .font(.system(size: 12)).foregroundStyle(Color.white)
                                .transition(.identity)          // leaves at once on the first send (never fades)
                        }
                        ForEach(store.transcript.messages) { m in
                            MessageRow(message: m, store: store, avatar: avatar, last: m.id == store.transcript.messages.last?.id)
                                .id(m.id)
                                .transition(.bubble(user: m.role == .user, reduceMotion))
                        }
                        ForEach(Array(store.transcript.notes.enumerated()), id: \.offset) { _, n in
                            Text(n).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.peakGold)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .animation(Motion.spring(reduceMotion), value: store.transcript.messages.count)
                }
                .scrollIndicators(.never)
                .onChange(of: store.transcript.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: store.transcript.messages.count) { _, _ in withAnimation(Motion.quick(reduceMotion)) { proxy.scrollTo("end", anchor: .bottom) } }
            }
            HStack(spacing: 8) {
                if voice.enabled { MicButton(voice: voice) }
                TextField("", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.white).lineLimit(1...4)
                    .modifier(GoldPlaceholder(text: voice.enabled ? "Ask 3PO… or press the mic" : "Ask 3PO…  Return sends", show: store.draft.isEmpty && !dictating))
                    .focused($focused)
                    .help("Return sends · ⌘K focuses · Esc collapses")
                    .onSubmit { Task { await store.send() } }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .overlay(alignment: .topLeading) {
                        if dictating {          // the live words sit in the field (confirmed only; pure white once final)
                            Group {
                                if voice.line.isEmpty {
                                    Text("Listening…").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white)
                                } else { LiveWordsText(line: voice.line).lineLimit(1...4) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
                            .allowsHitTesting(false)
                        }
                    }
                    .modifier(FocusRing(active: dictating || focused, reduceMotion: reduceMotion))
                PeakButton(title: store.transcript.streaming ? "…" : "Send", color: .peakGreen, filled: true, enabled: store.canSend) {
                    Task { await store.send() }
                }
            }
            if voice.enabled, let l = voice.phase.line {
                SwapText(text: l, font: .system(size: 11, weight: .semibold),
                         color: { if case .failed = voice.phase { return Color.peakGold }; return Color.white }(), lines: 2)
            }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    @ObservedObject var store: ThreePOStore
    let avatar: ThreePOAvatarRendering
    let last: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 60)
                Text(message.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.peakGreen, lineWidth: 1))
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                avatar.still(size: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    if !message.text.isEmpty {
                        Text(message.text).font(.system(size: 13)).foregroundStyle(Color.white).textSelection(.enabled)
                            .contentTransition(.identity)   // each streamed chunk lands at full white: no opacity fade on text (brand)
                    }
                    if last && store.transcript.thinking { ThinkingDots().transition(.scale(scale: 0.4)) }
                    if let e = message.error { Text(e).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.peakGold) }
                    ForEach(message.skills) { c in SkillCardView(card: c, store: store).transition(.arrivalPop(reduceMotion)) }
                    if let ev = message.memory, ev.needsPick { MemoryPickRow(message: message, event: ev, store: store) }
                    ForEach(message.proposals) { c in ProposalView(card: c, store: store).transition(.arrivalPop(reduceMotion)) }
                    if message.done { meta }
                }
            }
        }
    }

    var meta: some View {
        HStack(spacing: 6) {
            if message.local {
                chip("local · 0 tokens", .peakGreen)
            } else if let a = message.modelAlias, !a.isEmpty {
                chip(a.capitalized + (message.cached ? " · cached" : ""), .peakGreen)
            }
            if message.consultedOpus { chip("consulted Opus", .peakGold, filled: true) }
            if message.recalled > 0 { chip("used \(message.recalled) memor\(message.recalled == 1 ? "y" : "ies")", .peakGreen) }
            if let c = message.costUSD, c > 0 { chip(String(format: "$%.4f", c), .white) }
        }
    }

    func chip(_ t: String, _ c: Color, filled: Bool = false) -> some View {
        Text(t).font(.system(size: 10, weight: .heavy)).foregroundStyle(filled ? Color.black : Color.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(filled ? c : Color.black))
            .overlay(Capsule().stroke(c, lineWidth: 1))
    }
}

/// A 3PO proposal: the description first (client, why, inputs, touches, outputs), then Run / Ask Claude / Copy prompt.
/// Run shows GOAT's preview; only a second tap (Confirm) runs it. View-only proposals open in GOAT.
struct ProposalView: View {
    let card: ProposalCard
    @ObservedObject var store: ThreePOStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var phase: ProposalPhase { store.phases[card.id] ?? .described }
    var phaseKey: String {
        switch phase {
        case .described: return "described"; case .failed: return "failed"; case .previewing: return "previewing"
        case .previewed: return "previewed"; case .confirming: return "confirming"; case .done: return "done"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if case .done = phase {
                    ApprovalCheck(trigger: store.approvedPops, size: 15, reduceMotion: reduceMotion)
                        .transition(reduceMotion ? .identity : .scale(scale: 0.2))
                }
                Text(card.client ?? (card.origin == .pick ? "Which client?" : "No client named")).font(.system(size: 13, weight: .heavy)).foregroundStyle(Color.white)
                Text(card.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white).lineLimit(1)
                Spacer()
                Text(card.viewOnly ? "View only" : (card.origin == .pick ? "Pick a client" : (card.origin == .command ? "Confirm" : "Proposal"))).font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(card.viewOnly ? Color.peakGold : Color.peakGreen)
            }
            if !card.reason.isEmpty { Text(card.reason).font(.system(size: 12)).foregroundStyle(Color.white) }
            section("Inputs", card.inputs.isEmpty ? ["None"] : card.inputs)
            section("What it touches", [card.touches.isEmpty ? "Unknown" : card.touches])
            if !card.outputs.isEmpty { section("Outputs", card.outputs) }
            if !card.message.isEmpty { Text(card.message).font(.system(size: 11, weight: .semibold)).foregroundStyle(card.viewOnly ? Color.peakGold : Color.white) }
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) { buttons }
                    .id(phaseKey)
                    .transition(.slideUpFull(reduceMotion))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(card.viewOnly ? Color.peakGold : Color.peakGreen, lineWidth: 1))
        .animation(Motion.spring(reduceMotion), value: phase)
    }

    @ViewBuilder var buttons: some View {
        switch phase {
        case .described where card.origin == .pick:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(card.picks, id: \.self) { name in
                    PeakButton(title: name, color: .peakGold) { store.pickClient(card.id, name) }
                }
                PeakButton(title: "Copy prompt", color: .peakGold) { store.copy(card.id) }
            }
        case .described, .failed:
            HStack(spacing: 8) {
                if card.viewOnly {
                    PeakButton(title: "Open in GOAT", color: .peakGold) { _ = AppLauncher.activateGOAT() }
                } else {
                    PeakButton(title: "Run", color: .peakGreen, filled: true) { Task { await store.run(card.id) } }
                        .accessibilityIdentifier(card.origin == .command ? "peak-command-run" : "peak-card-run")
                }
                PeakButton(title: "Ask Claude", color: .peakGold) { Task { await store.ask(card.id) } }
                PeakButton(title: "Copy prompt", color: .peakGold) { store.copy(card.id) }
            }
            if case .failed(let m) = phase { Text(m).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.peakGold) }
        case .previewing, .confirming:
            HStack(spacing: 8) { ThinkingDots(); Text(phase == .previewing ? "Asking GOAT for its preview…" : "GOAT is running it…").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white) }
        case .previewed(let m):
            Text(m).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(4)
            HStack(spacing: 8) {
                PeakButton(title: "Confirm", color: .peakGold, filled: true) { Task { await store.confirm(card.id) } }
                PeakButton(title: "Cancel", color: .white) { store.cancel(card.id) }
            }
        case .done(let m):
            Text(m).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white).lineLimit(3)
        }
    }

    func section(_ t: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.peakGreen)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in Text(l).font(.system(size: 11)).foregroundStyle(Color.white).lineLimit(2) }
        }
    }
}

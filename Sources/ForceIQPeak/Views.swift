import AppKit
import PeakCore
import SwiftUI

/// Per-display view state the panel host drives (mode + rects come from PeakGeometry; the panel frame is the fixed canvas).
@MainActor final class PanelState: ObservableObject {
    let uuid: String
    @Published var mode: PeakMode
    @Published var layout: PeakLayout
    @Published var visible = true
    @Published var hovering = false
    @Published var dropTargeted = false
    @Published var dropAccepted = 0
    init(uuid: String, layout: PeakLayout) { self.uuid = uuid; self.layout = layout; mode = layout.mode }
    func apply(_ l: PeakLayout) { layout = l; mode = l.mode }
    var notchWidth: CGFloat { layout.notchRect?.width ?? 0 }
    var collapsedSize: CGSize { layout.collapsed.size }
    /// A state's rect in the canvas's SwiftUI coordinates (origin top-left).
    func local(_ r: CGRect) -> CGRect {
        let c = layout.canvas
        return CGRect(x: r.minX - c.minX, y: c.maxY - r.maxY, width: r.width, height: r.height)
    }
}

struct Haptic {
    /// Always paired with a visual cue at the call site (scale / brightness / glow).
    static func tick() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func level() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    static func generic() { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
}

enum Motion {
    /// One spring for every morph (response 0.4, damping 0.8); Reduce Motion: a short crossfade instead.
    static func spring(_ reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.16) : .spring(response: 0.4, dampingFraction: 0.8) }
    static func quick(_ reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.72) }
    static func sheet(_ reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)).animation(.spring(response: 0.42, dampingFraction: 0.82).delay(0.06)),
                                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)).animation(.easeOut(duration: 0.12)))
    }
}

/// The ONE shell: a notch (concave top ears, flush with the screen edge) or a pill / sheet (rounded), whose rect and
/// corner radii are animatable. Collapsed, home and chat are three sets of values for the same shape, so open/close is
/// one continuous spring of a path inside a fixed-size panel (no window resize, no relayout of the content).
struct PeakShellShape: Shape {
    var rect: CGRect
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var notch: Bool

    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(.init(rect.minX, rect.minY), .init(rect.width, rect.height)), .init(topRadius, bottomRadius)) }
        set {
            rect = CGRect(x: newValue.first.first.first, y: newValue.first.first.second,
                          width: newValue.first.second.first, height: newValue.first.second.second)
            topRadius = newValue.second.first; bottomRadius = newValue.second.second
        }
    }

    func path(in _: CGRect) -> Path {
        let r = rect.standardized
        let b = max(0, min(bottomRadius, r.height / 2, r.width / 2))
        guard notch else {
            let t = max(0, min(topRadius, r.height / 2, r.width / 2))
            return UnevenRoundedRectangle(topLeadingRadius: t, bottomLeadingRadius: b, bottomTrailingRadius: b, topTrailingRadius: t,
                                          style: .continuous).path(in: r)
        }
        let t = max(0, min(topRadius, r.width / 4, r.height / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct PeakRootView: View {
    @ObservedObject var controller: PeakController
    @ObservedObject var cards: CardStackViewModel
    @ObservedObject var panel: PanelState
    @ObservedObject var threePO: ThreePOStore
    @ObservedObject var drops: DropStore
    let switcher: [SwitcherEntry]
    let mark: GhostMarkRendering
    let glow: GhostGlowRendering
    let onSwitch: (String) -> Void
    let onDrop: ([URL]) -> Bool
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isExpanded: Bool { controller.expanded && controller.activeDisplay == panel.uuid }
    var showChat: Bool { isExpanded && controller.tab == .threePO && controller.profile.isEnabled(.threePO) }
    var surface: PeakLayout.Surface { isExpanded ? (showChat ? .chat : .home) : .collapsed }
    var shellRect: CGRect {
        var r = panel.local(panel.layout.hitRect(surface))
        if panel.mode == .notch && isExpanded { r = r.insetBy(dx: -earRadius, dy: 0) }   // ears sit outside the sheet
        return r
    }
    var earRadius: CGFloat { panel.mode == .notch ? (isExpanded ? 14 : 8) : 0 }
    var topRadius: CGFloat { panel.mode == .notch ? earRadius : (isExpanded ? 22 : panel.collapsedSize.height / 2) }
    var bottomRadius: CGFloat { isExpanded ? 24 : (panel.mode == .notch ? 12 : panel.collapsedSize.height / 2) }
    var shape: PeakShellShape { PeakShellShape(rect: shellRect, topRadius: topRadius, bottomRadius: bottomRadius, notch: panel.mode == .notch) }
    var hoverLift: Bool { panel.hovering && !isExpanded && !reduceMotion }

    var body: some View {
        ZStack(alignment: .topLeading) {
            shell
            content
                .frame(width: panel.layout.canvas.width, height: panel.layout.canvas.height, alignment: .topLeading)
                .mask(shape)
        }
        .contentShape(shape)
        .onTapGesture { if !isExpanded { Haptic.level(); controller.activeDisplay = panel.uuid; controller.expand() } }
        .scaleEffect(hoverLift ? 1.02 : 1, anchor: UnitPoint(x: (shellRect.midX) / max(1, panel.layout.canvas.width), y: 0))
        .frame(width: panel.layout.canvas.width, height: panel.layout.canvas.height, alignment: .topLeading)
        .animation(Motion.spring(reduceMotion), value: surface)
        .animation(Motion.quick(reduceMotion), value: panel.hovering)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { panel.dropTargeted }, set: { on in
            if on != panel.dropTargeted { panel.dropTargeted = on; if on { Haptic.tick() } }
        })) { providers in
            Task { @MainActor in
                let urls = await DropLoader.urls(providers)
                if !urls.isEmpty, onDrop(urls) { panel.dropAccepted += 1; Haptic.level() }
            }
            return true
        }
        .preferredColorScheme(.dark)
        .onAppear { wake() }
        .onChange(of: cards.ghost) { _, _ in wake() }
        .onChange(of: isExpanded) { _, e in if !e { wake() } }
        .onChange(of: panel.hovering) { _, h in if !h { wake() } }
    }

    // The shell: black (notch / sheet), liquid glass on the collapsed pill. Rim glow while a file hovers; green on accept.
    @ViewBuilder var shell: some View {
        let fill = shape.fill(Color.black)
        Group {
            if panel.mode == .pill, #available(macOS 26.0, *) {
                // Liquid glass on the floating pill only; the expanded sheet is pure black (bright text on black).
                GlassEffectContainer {
                    ZStack {
                        if !isExpanded {
                            shape.fill(Color.black.opacity(0.62))
                                .glassEffect(.regular.tint(.black), in: shape)
                                .glassEffectID("shell", in: ns)
                                .transition(.opacity)
                        }
                        fill.opacity(isExpanded ? 1 : 0)
                    }
                }
            } else {
                fill
            }
        }
        .brightness(hoverLift ? 0.07 : 0)
        .overlay { DropRim(shape: shape, targeted: panel.dropTargeted, accepted: panel.dropAccepted, reduceMotion: reduceMotion) }
    }

    /// Each state's content sits at its own rect inside the canvas (fixed size per state: the spring moves the path, not
    /// the layout).
    @ViewBuilder var content: some View {
        ZStack(alignment: .topLeading) {
            if isExpanded {
                let r = panel.local(panel.layout.hitRect(surface))
                expanded.frame(width: r.width, height: r.height, alignment: .top)
                    .padding(.leading, r.minX).padding(.top, r.minY)
                    .transition(Motion.sheet(reduceMotion))
            } else {
                let r = panel.local(panel.layout.collapsed)
                collapsed.padding(.leading, r.minX).padding(.top, r.minY)
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
    }

    /// Collapsed + idle pills hold a still frame; hover, expand or a state change wake the mark (MarkPolicy).
    @State private var awake = true
    @State private var wakeTask: Task<Void, Never>?
    var markLive: Bool {
        MarkPolicy.live(visible: panel.visible, globallyVisible: controller.globallyVisible, reduceMotion: reduceMotion,
                        expanded: isExpanded, hovering: panel.hovering, awake: awake)
    }
    func wake() {
        awake = true
        wakeTask?.cancel()
        wakeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(PeakTokens.markWakeSeconds * 1_000_000_000))
            if !Task.isCancelled { awake = false }
        }
    }

    func ghost(_ size: CGFloat) -> some View {
        ZStack {
            glow.glow(state: cards.ghost, reduceMotion: reduceMotion, active: markLive).frame(width: size + 6, height: size + 6)
            mark.mark(state: cards.ghost, points: size, playing: markLive, onOneShotDone: { cards.ghostOneShotFinished() })
                .frame(width: size, height: size)
        }
        .matchedGeometryEffect(id: "ghost", in: ns)
    }

    var badgeCount: Int { cards.cards.filter { $0.kind != .meeting }.count }

    var collapsed: some View {
        HStack(spacing: 6) {
            ghost(panel.collapsedSize.height - 10)
            if panel.mode == .notch {
                Spacer().frame(width: panel.notchWidth)
            } else {
                Text("ForceIQ Peak").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white).lineLimit(1)
                    .matchedGeometryEffect(id: "title", in: ns)
                Spacer(minLength: 0)
            }
            if badgeCount > 0 {
                Text("\(badgeCount)").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color.black)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.peakGold).matchedGeometryEffect(id: "badge", in: ns))
                    .frame(minWidth: 18)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 6)
        .frame(width: panel.collapsedSize.width, height: panel.collapsedSize.height)
    }

    var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ghost(30)
                Text("ForceIQ Peak").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.white)
                    .matchedGeometryEffect(id: "title", in: ns)
                if controller.profile.isEnabled(.threePO) { TabPills(controller: controller, current: controller.tab) }
                Spacer()
                if badgeCount > 0 {
                    Text("\(badgeCount) waiting").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.peakGold).matchedGeometryEffect(id: "badge", in: ns))
                }
                PeakButton(title: "Collapse", color: .white) { controller.collapse() }
            }
            .padding(.top, panel.mode == .notch ? (panel.layout.notchRect?.height ?? 32) + 4 : 12)
            Group {
                if drops.active {
                    DropsView(drops: drops).transition(reduceMotion ? .identity : .asymmetric(insertion: .scale(scale: 0.94, anchor: .top), removal: .identity))
                } else if showChat {
                    ThreePOView(store: threePO, profile: controller.profile, prefill: controller.askText)
                        .transition(.slideUpFull(reduceMotion))
                } else if let ask = controller.askText {
                    AskView(initial: ask, close: { controller.closeAsk() }).transition(.slideUpFull(reduceMotion))
                } else if let card = cards.describedCard {
                    DescriptionView(card: card, cards: cards)
                        .transition(reduceMotion ? .identity : .asymmetric(insertion: .move(edge: .trailing), removal: .identity))
                } else {
                    CardList(cards: cards).transition(.slideUpFull(reduceMotion))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(Motion.spring(reduceMotion), value: cards.describedCard?.id)
            if !showChat && !drops.active { SwitcherRow(entries: switcher, onSwitch: onSwitch) }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }
}

/// Peak | 3PO, a gold pill under the active tab (matched geometry, so it slides).
struct TabPills: View {
    @ObservedObject var controller: PeakController
    /// The active tab, passed by value from the panel so the pill always redraws with the sheet it labels.
    let current: PeakController.Tab
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 2) {
            tab(.home, "Peak")
            tab(.threePO, "3PO")
        }
        .padding(2)
        .overlay(Capsule().stroke(Color.peakGold, lineWidth: 1))
    }
    func tab(_ t: PeakController.Tab, _ title: String) -> some View {
        let on = current == t
        return Text(title).font(.system(size: 11, weight: .heavy)).foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background { if on { Capsule().fill(Color.peakGold).matchedGeometryEffect(id: "tab", in: ns) } }
            .contentShape(Capsule())
            .onTapGesture { Haptic.tick(); withAnimation(Motion.spring(reduceMotion)) { controller.tab = t } }
    }
}

/// Drop target: a gold rim glow that breathes while a file hovers; a green flash + haptic when the drop is taken.
struct DropRim: View {
    let shape: PeakShellShape
    let targeted: Bool
    let accepted: Int
    let reduceMotion: Bool
    var body: some View {
        ZStack {
            if targeted {
                if reduceMotion {
                    shape.stroke(Color.peakGold, lineWidth: 2)
                } else {
                    shape.stroke(Color.peakGold, lineWidth: 2)
                        .phaseAnimator([0.0, 1.0]) { v, p in
                            v.shadow(color: Color.peakGold.opacity(0.5 + 0.5 * p), radius: 6 + 8 * p)
                        } animation: { _ in .easeInOut(duration: 0.7) }
                }
            }
            shape.stroke(Color.peakGreen, lineWidth: 2)
                .keyframeAnimator(initialValue: 0.0, trigger: accepted) { v, o in
                    v.opacity(o).shadow(color: Color.peakGreen.opacity(o), radius: 10 * o)
                } keyframes: { _ in
                    KeyframeTrack(\.self) {
                        LinearKeyframe(0.0, duration: 0.01)
                        CubicKeyframe(1.0, duration: 0.12)
                        CubicKeyframe(0.0, duration: 0.55)
                    }
                }
        }
        .allowsHitTesting(false)
    }
}

/// Approval check: a green check that springs in inside its OWN layout slot (leading the title / the result line), with
/// a tiny sparkle that stays inside that slot. It never overlays text. Keyframes run once per trigger, then stop.
struct ApprovalCheck: View {
    let trigger: Int
    var size: CGFloat = 18
    let reduceMotion: Bool
    var body: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<6, id: \.self) { i in
                    Circle().fill(i % 2 == 0 ? Color.peakGold : Color.peakGreen).frame(width: 3, height: 3)
                        .keyframeAnimator(initialValue: 0.0, trigger: trigger) { v, k in
                            let a = Double(i) / 6 * 2 * .pi
                            return v.offset(x: cos(a) * size * 0.62 * k, y: sin(a) * size * 0.62 * k).opacity(k > 0 && k < 1 ? 1 : 0)
                        } keyframes: { _ in
                            KeyframeTrack(\.self) { LinearKeyframe(0.0, duration: 0.05); CubicKeyframe(0.9, duration: 0.28); LinearKeyframe(1.0, duration: 0.1) }
                        }
                }
            }
            Image(systemName: "checkmark.circle.fill").font(.system(size: size, weight: .bold)).foregroundStyle(Color.peakGreen)
                .keyframeAnimator(initialValue: 1.0, trigger: trigger) { v, k in v.scaleEffect(k) } keyframes: { _ in
                    KeyframeTrack(\.self) {
                        LinearKeyframe(reduceMotion ? 1.0 : 0.2, duration: 0.01)
                        SpringKeyframe(1.18, duration: 0.2, spring: .snappy)
                        SpringKeyframe(1.0, duration: 0.3, spring: .bouncy)
                    }
                }
        }
        .frame(width: size + 6, height: size + 6)
        .allowsHitTesting(false)
    }
}

enum DropLoader {
    @MainActor static func urls(_ providers: [NSItemProvider]) async -> [URL] {
        var out: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier("public.file-url") {
            let u: URL? = await withCheckedContinuation { c in
                _ = p.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
            }
            if let u, u.isFileURL { out.append(u) }
        }
        return out
    }
}

struct PeakButton: View {
    let title: String
    var color: Color = .peakGreen
    var filled = false
    /// Disabled = a gold outline with a pure white label at full opacity; it just stops taking taps (never dimmed).
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    var fill: Color { enabled && filled ? color : Color.black }
    var stroke: Color { enabled ? color : Color(hex: PeakTokens.disabledStrokeHex) }
    var label: Color { enabled ? (filled ? Color.black : Color.white) : Color(hex: PeakTokens.disabledLabelHex) }
    var body: some View {
        Button(action: { guard enabled else { return }; Haptic.tick(); action() }) {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(label)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(stroke, lineWidth: hover && enabled ? 2 : 1))
                .scaleEffect(hover && enabled ? 1.04 : 1)
                .brightness(hover && filled && enabled ? 0.06 : 0)
                .opacity(PeakTokens.disabledOpacity)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(enabled)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: enabled)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hover = h }; if h && enabled { Haptic.tick() } }
    }
}

extension Color {
    init(hex: UInt32) { let c = Brand.rgb(hex); self.init(red: c.r, green: c.g, blue: c.b) }
}

/// A gold placeholder drawn by Peak (the system prompt renders gray on macOS whatever its style).
struct GoldPlaceholder: ViewModifier {
    let text: String
    let show: Bool
    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if show {
                Text(text).foregroundStyle(Color(hex: PeakTokens.placeholderHex)).allowsHitTesting(false)
            }
        }
    }
}

struct CardList: View {
    @ObservedObject var cards: CardStackViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !cards.configured {
                    Text("No coach profile on this Mac yet (overlay peak section). Peak shows nothing until it has one.")
                        .font(.system(size: 13)).foregroundStyle(Color.peakGold)
                } else if cards.cards.isEmpty {
                    Text("All clear. Nothing waiting for you.").font(.system(size: 13)).foregroundStyle(Color.white)
                }
                ForEach(cards.cards) { c in CardRow(card: c).onTapGesture { Haptic.tick(); cards.tap(c) } }
                if cards.pipelineHidden > 0 {
                    HStack {
                        Text("Pipeline progress lives in Command.").font(.system(size: 12)).foregroundStyle(Color.white)
                        Spacer()
                        PeakButton(title: "Open in Command", color: .peakGreen) { _ = AppLauncher.openCommand() }
                    }
                }
                if cards.unnamed > 0 {
                    HStack {
                        Text("\(cards.unnamed) more in GOAT (no client named).").font(.system(size: 12)).foregroundStyle(Color.white)
                        Spacer()
                        PeakButton(title: "Open in GOAT", color: .peakGold) { _ = AppLauncher.activateGOAT() }
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }
}

struct CardRow: View {
    let card: PeakCard
    @State private var hover = false
    var accent: Color { card.kind == .meeting ? .peakGreen : (card.viewOnly ? .peakGold : .peakGreen) }
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.client).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.white)
                Text(card.title).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(1)
            }
            Spacer()
            if let start = card.startsAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Countdown.text(to: start, now: ctx.date)).font(.system(size: 12, weight: .heavy).monospacedDigit())
                        .foregroundStyle(Color.peakGreen)
                }
            } else {
                Text(card.viewOnly ? "View only" : card.detail).font(.system(size: 11, weight: .bold))
                    .foregroundStyle(card.viewOnly ? Color.peakGold : Color.peakGreen)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(hover ? accent : Color.white.opacity(0.25), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

struct DescriptionView: View {
    let card: PeakCard
    @ObservedObject var cards: CardStackViewModel
    @State private var base: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var approved: Bool { base.map { cards.approvedPops > $0 } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if approved {
                    ApprovalCheck(trigger: cards.approvedPops, size: 16, reduceMotion: reduceMotion)
                        .transition(reduceMotion ? .identity : .scale(scale: 0.2).animation(.spring(response: 0.3, dampingFraction: 0.6)))
                }
                Text(card.client).font(.system(size: 15, weight: .bold)).foregroundStyle(Color.white)
                Text(card.title).font(.system(size: 13)).foregroundStyle(Color.white).lineLimit(1)
                Spacer()
                PeakButton(title: "Back", color: .white) { cards.back() }
            }
            section("Inputs", card.description.inputs)
            section("What it touches", card.description.touches)
            section("Outputs", card.description.outputs)
            if let why = card.viewOnlyReason {
                Text(why).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.peakGold)
            }
            HStack(spacing: 8) {
                ForEach(card.actions, id: \.self) { a in
                    PeakButton(title: a.label, color: a == .run ? .peakGreen : .peakGold, filled: a == .run) {
                        Task { await cards.choose(a) }
                    }
                }
            }
            if let r = cards.lastResult {
                Text(r).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(3).transition(.slideUpFull(reduceMotion))
            }
        }
        .animation(Motion.spring(reduceMotion), value: approved)
        .animation(Motion.spring(reduceMotion), value: cards.lastResult)
        .onAppear { base = cards.approvedPops }
    }
    func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.peakGreen)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(2)
            }
        }
    }
}

/// The ask field: prefilled from forceiq-peak://ask?q=… and NEVER sent. Copy or open GOAT, that's all.
struct AskView: View {
    @State var text: String
    let close: () -> Void
    init(initial: String, close: @escaping () -> Void) { _text = State(initialValue: initial); self.close = close }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ASK").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.peakGreen)
            TextField("", text: $text)
                .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(Color.white)
                .modifier(GoldPlaceholder(text: "Ask GOAT…", show: text.isEmpty))
                .padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.peakGreen, lineWidth: 1))
            Text("Nothing is sent from here.").font(.system(size: 11)).foregroundStyle(Color.white)
            HStack {
                PeakButton(title: "Copy", color: .peakGold) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                }
                PeakButton(title: "Open GOAT", color: .peakGold) { _ = AppLauncher.activateGOAT() }
                PeakButton(title: "Close", color: .white) { close() }
            }
        }
    }
}

struct SwitcherRow: View {
    let entries: [SwitcherEntry]
    let onSwitch: (String) -> Void
    var body: some View {
        HStack(spacing: 8) {
            ForEach(entries) { e in
                SwitcherTile(entry: e) { if e.installed { onSwitch(e.app.bundleID) } }
            }
        }
    }
}

struct SwitcherTile: View {
    let entry: SwitcherEntry
    let action: () -> Void
    @State private var hover = false
    var style: SwitcherTileStyle { .of(installed: entry.installed) }
    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let icon = AppIcons.shared.icon(entry.app.bundleID) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.peakGold)
                }
            }
            .frame(width: 30, height: 30)
            .padding(3)
            .overlay { if let o = style.outlineHex { RoundedRectangle(cornerRadius: 9).stroke(Color(hex: o), lineWidth: 1.5) } }
            .saturation(style.saturation).opacity(style.opacity)           // full color, full opacity, installed or not
            .scaleEffect(hover && style.tappable ? 1.12 : 1)
            Text(entry.app.name).font(.system(size: 10, weight: .bold)).foregroundStyle(Color(hex: style.labelHex))
            if let note = style.note { Text(note).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(hex: style.noteHex)) }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { if entry.installed { Haptic.tick(); action() } }
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) { hover = h }; if h && entry.installed { Haptic.tick() } }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: PeakController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ForceIQ Peak").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.white)
            Toggle(isOn: Binding(get: { controller.hotkeyEnabled }, set: { controller.setHotkeyEnabled($0) })) {
                Text("Built-in hotkey").foregroundStyle(Color.white)
            }
            HStack {
                Text("Show / hide shortcut").foregroundStyle(Color.white)
                HotkeyRecorder()
            }
            Text("Raycast and anything else on this Mac can also use forceiq-peak:// links.").font(.system(size: 11)).foregroundStyle(Color.white)
        }
        .padding(18).frame(width: 380).background(Color.black)
    }
}

/// App icons for the switcher, resolved once (at launch, prefetch) instead of on every body evaluation: expanding the
/// sheet used to hit LaunchServices + IconServices six times on the main thread.
@MainActor final class AppIcons {
    static let shared = AppIcons()
    private var cache: [String: NSImage?] = [:]
    func icon(_ bundleID: String) -> NSImage? {
        if let hit = cache[bundleID] { return hit }
        let img = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = img
        return img
    }
    func prefetch(_ ids: [String]) { for id in ids { _ = icon(id) } }
}

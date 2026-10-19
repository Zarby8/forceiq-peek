import AppKit
import PeakCore
import SwiftUI

/// Full-opacity slide-up for a block that replaces another in place: the old block leaves at once, the new one rises
/// 10 pt into its slot, so two texts are never both readable and nothing is ever shown dimmed.
struct SlideUp: ViewModifier {
    let y: CGFloat
    func body(content: Content) -> some View { content.offset(y: y) }
}
extension AnyTransition {
    static func slideUpFull(_ reduce: Bool) -> AnyTransition {
        reduce ? .identity : .asymmetric(insertion: .modifier(active: SlideUp(y: 10), identity: SlideUp(y: 0)), removal: .identity)
    }
}

/// The drop sheet: the file, the two zones (each describes itself), then the engine's description first, then
/// Run / Ask Claude / Copy prompt, then Confirm. One headline view with a stable identity (its text interpolates),
/// one body slot keyed by the step; the buttons slide up at full opacity once the preview is ready.
struct DropsView: View {
    @ObservedObject var drops: DropStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var busy: Bool { switch drops.phase { case .previewing, .applying: return true; default: return false } }

    var headline: (text: String, tag: String) {
        switch drops.phase {
        case .idle: return ("", "")
        case .pending(let url, _): return (url.lastPathComponent, "")
        case .choosing(_, let client, _, let message): return (client.isEmpty ? message : "\(client): \(message)", "")
        case .previewing(let z): return ("GOAT is previewing…", z.title)
        case .described(let p), .confirming(let p, _), .undoConfirm(let p, _): return (p.client ?? "No client resolved", p.zone.title)
        case .applying(let p): return ("\(p.client ?? "No client resolved"): applying…", p.zone.title)
        case .applied(let p, _): return (p.client ?? "No client resolved", p.zone.title)
        case .failed: return ("Nothing changed", "")
        case .note: return ("Done", "")
        }
    }

    /// The body slot's identity: described / confirming / applying share one key per preview, so the description
    /// never re-enters; only the step-specific rows below it change.
    var bodyKey: String {
        switch drops.phase {
        case .idle: return "idle"
        case .pending: return "pending"
        case .choosing: return "choosing"
        case .previewing: return "previewing"
        case .described(let p), .confirming(let p, _), .applying(let p): return "p-\(p.token)"
        case .applied(let p, _): return "applied-\(p.token)"
        case .undoConfirm(let p, _): return "undo-\(p.token)"
        case .failed: return "failed"
        case .note: return "note"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DROP").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.peakGreen)
                Spacer()
                PeakButton(title: "Close", color: .white) { drops.dismiss() }
            }
            HStack(spacing: 8) {
                if busy { ThinkingDots().transition(.scale(scale: 0.4)) }
                SwapText(text: headline.text, font: .system(size: 14, weight: .heavy), color: .white)
                SwapText(text: headline.tag, font: .system(size: 12, weight: .semibold), color: .peakGreen)
            }
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) { slot }
                    .id(bodyKey)
                    .transition(.slideUpFull(reduceMotion))
            }
        }
        .animation(Motion.spring(reduceMotion), value: drops.phase)
        .animation(Motion.spring(reduceMotion), value: drops.shiftState)
        .task(id: drops.phase) {
            // Shift-download progress: one status read every 10 s, only while this sheet shows a placed shift.
            while !Task.isCancelled, case .applied(let p, _) = drops.phase, p.zone == .shift, !(drops.shiftState?.isFinal ?? false) {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await drops.pollShift()
            }
        }
    }

    @ViewBuilder var slot: some View {
        switch drops.phase {
        case .idle: EmptyView()
        case .pending(_, let suggested):
            HStack(spacing: 10) {
                ForEach(DropZone.allCases, id: \.self) { z in ZoneTile(zone: z, suggested: z == suggested) { Task { await drops.preview(z) } } }
            }
            Text("Nothing is read until you pick a zone. Preview never changes a file.").font(.system(size: 11)).foregroundStyle(Color.white)
        case .choosing(_, _, let choices, _):
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(choices, id: \.self) { g in
                    PeakButton(title: g, color: .peakGreen) { Task { await drops.preview(.title, game: g) } }
                }
            }
            Text("Pick the game; the preview still changes nothing.").font(.system(size: 11)).foregroundStyle(Color.white)
        case .previewing:
            Text("Reading the file. Nothing changes until you confirm.").font(.system(size: 12)).foregroundStyle(Color.white)
        case .described(let p), .confirming(let p, _), .applying(let p):
            described(p)
            actions.id(actionKey).transition(.slideUpFull(reduceMotion))
        case .applied(let p, let msg):
            HStack(spacing: 8) {
                ApprovalCheck(trigger: drops.pops, size: 18, reduceMotion: reduceMotion)
                Text(msg).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white)
            }
            HStack(spacing: 8) {
                PeakButton(title: "Undo", color: .peakGold) { Task { await drops.undo() } }
                if p.zone == .shift { PeakButton(title: "Open in Command", color: .peakGreen) { _ = AppLauncher.openCommand() } }
            }
            if p.zone == .shift, let st = drops.shiftState { ShiftProgressView(client: p.client, progress: st) }
        case .undoConfirm(_, let text):
            Text(text).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.peakGold)
            HStack(spacing: 8) {
                PeakButton(title: "Confirm undo", color: .peakGold, filled: true) { Task { await drops.confirmUndo() } }
                PeakButton(title: "Cancel", color: .white) { drops.cancel() }
            }
        case .failed(let m):
            Text(m).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.peakGold)
        case .note(let m):
            Text(m).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.white)
        }
    }

    var actionKey: String {
        switch drops.phase { case .confirming: return "confirm"; case .applying: return "applying"; default: return "run" }
    }

    @ViewBuilder var actions: some View {
        switch drops.phase {
        case .described(let p):
            HStack(spacing: 8) {
                if p.canApply { PeakButton(title: "Run", color: .peakGreen, filled: true) { Task { await drops.run() } } }
                PeakButton(title: "Ask Claude", color: .peakGold) { drops.ask() }
                PeakButton(title: "Copy prompt", color: .peakGold) { drops.copy() }
            }
        case .confirming(_, let text):
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.peakGold)
                HStack(spacing: 8) {
                    PeakButton(title: "Confirm", color: .peakGold, filled: true) { Task { await drops.confirm() } }
                    PeakButton(title: "Cancel", color: .white) { drops.cancel() }
                }
            }
        default:
            Text("Applying; every replaced file is backed up first.").font(.system(size: 12)).foregroundStyle(Color.white)
        }
    }

    @ViewBuilder func described(_ p: DropPreview) -> some View {
        Text(p.description).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(5)
        ForEach(p.details, id: \.self) { d in
            Text(d).font(.system(size: 11, weight: .semibold)).foregroundStyle(d.hasPrefix("Problem") || d.hasPrefix("Already") ? Color.peakGold : Color.white)
        }
        if let f = p.fixName { Text("Name fix on Confirm: \(f)").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.peakGold) }
        if let pr = p.problem { Text(pr).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.peakGold) }
        if !p.before.isEmpty || !p.after.isEmpty {
            HStack(spacing: 8) {
                thumbs("Before", p.before)
                thumbs("After", p.after)
            }
        }
    }

    func thumbs(_ label: String, _ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.peakGreen)
            HStack(spacing: 4) {
                ForEach(paths.prefix(2), id: \.self) { path in AsyncThumb(path: path) }
            }
        }
    }
}

/// Before/after thumbnails decode off the main thread (never NSImage(contentsOfFile:) inside body).
struct AsyncThumb: View {
    let path: String
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).transition(.scale(scale: 0.96)) }
            else { RoundedRectangle(cornerRadius: 6).stroke(Color.peakGreen, lineWidth: 1).frame(width: 96) }
        }
        .frame(height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: path) {
            let p = path
            let img = await Task.detached(priority: .userInitiated) { NSImage(contentsOfFile: p) }.value
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { image = img }
        }
    }
}

struct ZoneTile: View {
    let zone: DropZone
    let suggested: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: zone == .title ? "photo.on.rectangle" : "film.stack").foregroundStyle(Color.peakGold)
                Text(zone.title).font(.system(size: 13, weight: .heavy)).foregroundStyle(Color.white)
                if suggested { Text("suggested").font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.peakGreen) }
            }
            Text(zone.blurb).font(.system(size: 11)).foregroundStyle(Color.white).lineLimit(3)
            Text("Preview").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color.black)
                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.peakGreen))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(hover ? Color.peakGold : (suggested ? Color.peakGreen : Color.peakGold), lineWidth: hover ? 2 : 1))
        .shadow(color: hover ? Color.peakGold.opacity(0.6) : .clear, radius: hover ? 8 : 0)
        .scaleEffect(hover && !reduceMotion ? 1.02 : 1)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.quick(reduceMotion)) { hover = h }; if h { Haptic.tick() } }
        .onTapGesture { Haptic.level(); action() }
    }
}

/// Shift download: the steps light up green as the watcher / Dagu move it along; gold when it needs you. The label
/// and message are single views whose text interpolates (never two overlapping strings).
struct ShiftProgressView: View {
    let client: String?
    let progress: ShiftProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SwapText(text: "\(client ?? "Client") · shift download: \(progress.label)", font: .system(size: 12, weight: .heavy),
                     color: progress.isProblem ? .peakGold : .white)
            HStack(spacing: 4) {
                ForEach(Array(ShiftProgress.steps.enumerated()), id: \.offset) { i, _ in
                    Capsule().fill(i <= progress.step && !progress.isProblem ? Color.peakGreen : Color.black)
                        .overlay(Capsule().stroke(progress.isProblem ? Color.peakGold : Color.peakGreen, lineWidth: 1))
                        .frame(height: 5)
                }
            }
            SwapText(text: progress.message, font: .system(size: 11), color: .white, lines: 2)
        }
    }
}

/// One label slot whose text changes without a crossfade: the old string leaves at once (identity removal) and the
/// new one slides up 6 pt with a brief blur-to-sharp at full opacity, so two strings are never on screen together.
struct SwapText: View {
    let text: String
    let font: Font
    let color: Color
    var lines = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack(alignment: .leading) {
            Text(text).font(font).foregroundStyle(color).lineLimit(lines)
                .id(text)
                .transition(reduceMotion ? .identity : .asymmetric(insertion: .modifier(active: BlurUp(on: true), identity: BlurUp(on: false)), removal: .identity))
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: text)
    }
}

struct BlurUp: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { content.offset(y: on ? 6 : 0).blur(radius: on ? 3 : 0) }
}

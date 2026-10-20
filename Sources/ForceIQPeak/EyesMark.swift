import PeakCore
import SwiftUI

/// Peek's mark: two eyes (👀), vectors on black. Default mark; FORCEIQ_PEAK_MARK=bob brings back the BOB Motion loops.
/// While the mark sleeps (a collapsed idle pill) or Reduce Motion is on, no frame is scheduled at all: a still pose is held.
@MainActor struct EyesMarkRenderer: GhostMarkRendering {
    func mark(state: GhostState, points: CGFloat, playing: Bool, onOneShotDone: @escaping @MainActor () -> Void) -> AnyView {
        AnyView(EyesMarkView(state: state, playing: playing, onOneShotDone: onOneShotDone).frame(width: points, height: points))
    }
}

struct EyesMarkView: View {
    let state: GhostState
    let playing: Bool
    let onOneShotDone: @MainActor () -> Void
    @State private var started = Date()
    @State private var shot = EyesOneShot()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { ctx in          // paused = no frames scheduled
            EyesShape(pose: playing ? EyesPose.at(state, t: ctx.date.timeIntervalSince(started)) : EyesPose.rest(state))
        }
        .task(id: state) {
            started = Date()
            shot.schedule(for: state, done: onOneShotDone)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Peek")
    }
}

struct EyesShape: View {
    let pose: EyesPose
    var body: some View {
        Canvas { ctx, size in
            let w = min(size.width, size.height)
            let cx = size.width / 2, cy = size.height / 2
            ctx.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(.black))
            if pose.halo {
                let lw = max(1.5, w * 0.07)
                ctx.stroke(Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: lw / 2, dy: lw / 2)), with: .color(Color(hex: Brand.goldHex)), lineWidth: lw)
            }
            let fullH = w * 0.52 * pose.scale
            let eyeW = w * 0.33 * pose.scale, eyeH = fullH * pose.open
            let pr = w * 0.085 * pose.pupil
            let tint = Color(hex: pose.pupilHex)
            for side in [-1.0, 1.0] {
                let c = CGPoint(x: cx + side * w * 0.19, y: cy)
                let eye = Path(ellipseIn: CGRect(x: c.x - eyeW / 2, y: c.y - eyeH / 2, width: eyeW, height: eyeH))
                ctx.fill(eye, with: .color(.white))
                var inner = ctx
                inner.clip(to: eye)
                let px = c.x + pose.lookX * (eyeW / 2 - pr) * 0.9, py = c.y + pose.lookY * (fullH / 2 - pr) * 0.8
                inner.fill(Path(ellipseIn: CGRect(x: px - pr, y: py - pr, width: pr * 2, height: pr * 2)), with: .color(tint))
                if pose.ring { ctx.stroke(eye, with: .color(tint), lineWidth: max(1, w * 0.04)) }
            }
        }
    }
}

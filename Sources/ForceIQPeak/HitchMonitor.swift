import AppKit
import PeakCore
import QuartzCore
import os

/// Visual-proof only (demo tour): a display link on the main display logs every main-thread frame gap > 25 ms with the
/// tour step it happened in, plus an os_signpost per step (Instruments: subsystem com.forceiq.peak, category tour).
/// Started by the tour and invalidated when it ends, so it never runs at idle or in normal use.
@MainActor final class HitchMonitor: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private(set) var step = "start"
    private var worst: [String: Double] = [:]
    private let logger: PeakLogging
    static let signposter = OSSignposter(subsystem: "com.forceiq.peak", category: "tour")
    private var interval: OSSignpostIntervalState?

    init(logger: PeakLogging) { self.logger = logger }

    func start(on screen: NSScreen) {
        let l = screen.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func mark(_ s: String) {
        if let i = interval { Self.signposter.endInterval("step", i) }
        interval = Self.signposter.beginInterval("step", id: Self.signposter.makeSignpostID(), "\(s, privacy: .public)")
        step = s
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        defer { last = now }
        guard last > 0 else { return }
        let gap = (now - last) * 1000
        if gap > 25 {
            logger.log(String(format: "hitch ms=%.0f step=%@", gap, step))
            worst[step] = max(worst[step] ?? 0, gap)
        }
    }

    func stop() {
        link?.invalidate(); link = nil
        if let i = interval { Self.signposter.endInterval("step", i); interval = nil }
        let w = worst.sorted { $0.value > $1.value }.map { String(format: "%@=%.0f", $0.key, $0.value) }.joined(separator: " ")
        logger.log("hitch summary worst_ms_by_step: \(w.isEmpty ? "none>25ms" : w)")
    }
}

import AppKit

// ForceIQ Peak: a Ghost-branded strip around the notch (or a floating pill on a display without one).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}

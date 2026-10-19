import Foundation

/// Hard rules: pure white text on pure black, green and gold accents, never dim gray text.
public enum Brand {
    public static let blackHex: UInt32 = 0x000000
    public static let whiteHex: UInt32 = 0xFFFFFF
    public static let greenHex: UInt32 = 0x5BE37D
    public static let goldHex: UInt32 = 0xF5C542
    /// Every text color Peak may use. Tests assert nothing else is ever offered.
    public static let allowedTextHex: Set<UInt32> = [whiteHex, greenHex, goldHex, blackHex]

    public static func rgb(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}

/// UI tokens the views read, so the no-gray rule is testable: placeholders are gold, a disabled control is a gold
/// outline with a pure white label at full opacity (disabled through hit-testing, never by dimming).
public enum PeakTokens {
    public static let placeholderHex = Brand.goldHex
    public static let disabledStrokeHex = Brand.goldHex
    public static let disabledLabelHex = Brand.whiteHex
    public static let disabledOpacity: Double = 1.0
    /// A collapsed pill plays the Ghost mark this long after a state change, then holds a still first frame.
    public static let markWakeSeconds: Double = 6
    /// The Metal glow (only when the bundle has default.metallib) re-renders via SwiftUI, so it ticks at this rate.
    public static let ambientShaderFPS: Double = 15
}

/// Switcher tile look. A listed app that isn't installed is never dimmed or desaturated: it gets a gold outline, its
/// white name and a small gold 'Not installed' line, all at full opacity, and it just doesn't take taps.
public struct SwitcherTileStyle: Equatable, Sendable {
    public let outlineHex: UInt32?
    public let labelHex: UInt32
    public let note: String?
    public let noteHex: UInt32
    public let opacity: Double
    public let saturation: Double
    public let tappable: Bool
    public static func of(installed: Bool) -> SwitcherTileStyle {
        installed
            ? .init(outlineHex: nil, labelHex: Brand.whiteHex, note: nil, noteHex: Brand.goldHex, opacity: 1, saturation: 1, tappable: true)
            : .init(outlineHex: Brand.goldHex, labelHex: Brand.whiteHex, note: "Not installed", noteHex: Brand.goldHex, opacity: 1, saturation: 1, tappable: false)
    }
}

/// When the Ghost-mark video plays. Collapsed + idle pills hold a still frame (near-zero CPU on every display);
/// hover, expand or a fresh state change wake it.
public enum MarkPolicy {
    public static func live(visible: Bool, globallyVisible: Bool, reduceMotion: Bool, expanded: Bool, hovering: Bool, awake: Bool) -> Bool {
        visible && globallyVisible && !reduceMotion && (expanded || hovering || awake)
    }
}

/// Peak's shape per display. Clamshell (lid closed) or a desk of external displays: no screen has a notch, so every
/// panel is a pill. A notch is used only when that very screen reports one.
public enum DisplayPlan {
    public static func modes(_ screens: [ScreenDescriptor], geometry: PeakGeometryProviding = PeakGeometry()) -> [String: PeakMode] {
        Dictionary(screens.map { ($0.uuid, geometry.layout(for: $0).mode) }, uniquingKeysWith: { a, _ in a })
    }
}

/// The Ghost glow's breath (the look approved on the native SwiftUI ring): phase = (sin(t * 1.6) + 1) / 2, a thin ring
/// at 0.55…1.0 opacity and a soft ring (4 pt stroke) whose blur breathes 4…7 pt at strength × 0.35…0.75 opacity.
/// It runs as a Core Animation layer animation (render server; no SwiftUI update per frame), so these are the
/// animation's endpoints and half-period. See GhostMark.swift (CAGlowView).
public struct GlowBreath: Equatable, Sendable {
    public static let angularSpeed = 1.6
    /// Trough → crest (one autoreverse leg): half of 2π / 1.6 ≈ 1.963 s.
    public static var halfPeriod: Double { Double.pi / angularSpeed }
    public let innerOpacity: ClosedRange<Double>
    public let outerOpacity: ClosedRange<Double>
    public let outerBlur: ClosedRange<Double>
    public let innerWidth: Double = 1.5
    public let outerWidth: Double = 4
    public init(strength: Double) {
        innerOpacity = 0.55...1.0
        outerOpacity = (strength * 0.35)...(strength * 0.75)
        outerBlur = 4...7
    }
    /// The SwiftUI formula at a phase in 0…1 (what the old TimelineView drew), for tests and the still frame.
    public func at(phase p: Double) -> (inner: Double, outer: Double, blur: Double) {
        func lerp(_ r: ClosedRange<Double>) -> Double { r.lowerBound + (r.upperBound - r.lowerBound) * p }
        return (lerp(innerOpacity), lerp(outerOpacity), lerp(outerBlur))
    }
    public static func phase(at t: Double) -> Double { (sin(t * angularSpeed) + 1) / 2 }
    public static func strength(_ s: GhostState) -> Double { s == .working ? 0.7 : 0.45 }
}

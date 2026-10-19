import AppKit
import PeakCore

/// Draws the menu-bar badge (StatusBadgeSpec) as a non-template image: a black capsule with the text in its brand color.
enum StatusBadgeImage {
    static func color(_ hex: UInt32) -> NSColor {
        let c = Brand.rgb(hex)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    static func make(_ s: StatusBadgeSpec) -> NSImage {
        let text = NSAttributedString(string: s.text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: color(s.textHex), .kern: 0.9])
        let size = text.size()
        let h: CGFloat = 18, pad: CGFloat = 8
        let img = NSImage(size: NSSize(width: ceil(size.width) + 2 * pad, height: h), flipped: false) { r in
            color(s.backgroundHex).setFill()
            NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
            text.draw(at: NSPoint(x: pad, y: (h - size.height) / 2))
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = s.accessibilityLabel
        return img
    }
}

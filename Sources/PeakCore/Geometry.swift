import CoreGraphics
import Foundation

/// What Peek needs to know about one display (AppKit fills it from NSScreen; tests use mocks).
public struct ScreenDescriptor: Equatable, Sendable {
    public let uuid: String
    public let name: String
    public let frame: CGRect               // global AppKit coordinates (origin bottom-left)
    public let safeAreaTop: CGFloat        // NSScreen.safeAreaInsets.top (> 0 on a notch display)
    public let auxiliaryTopLeft: CGRect?   // NSScreen.auxiliaryTopLeftArea
    public let auxiliaryTopRight: CGRect?  // NSScreen.auxiliaryTopRightArea
    public let menuBarHeight: CGFloat
    public init(uuid: String, name: String, frame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeft: CGRect?,
                auxiliaryTopRight: CGRect?, menuBarHeight: CGFloat = 24) {
        self.uuid = uuid; self.name = name; self.frame = frame; self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft; self.auxiliaryTopRight = auxiliaryTopRight; self.menuBarHeight = menuBarHeight
    }
    public var hasNotch: Bool { safeAreaTop > 0 && auxiliaryTopLeft != nil && auxiliaryTopRight != nil }
}

public enum PeakMode: String, Sendable { case notch, pill }

public struct PeakLayout: Equatable, Sendable {
    public let mode: PeakMode
    public let notchRect: CGRect?          // the notch cut-out (hardware, or the virtual notch on a plain external display)
    /// True when `notchRect` is a VIRTUAL notch: the display has no hardware notch (no safe-area top, no
    /// auxiliary areas), so Peek draws its own notch-shaped row at the top-center of the screen.
    public var virtualNotch: Bool = false
    /// The mark square (screen coords): the selected mark (ghost / BOB / eyes) always renders here, in
    /// every mode. In notch mode the collapsed assembly lives inside the menu-bar band: on a virtual
    /// notch the mark sits at the assembly's center; on the hardware notch it sits in the right ear
    /// hard against the camera housing, because the housing's own rect has no display pixels and can
    /// never show the mark.
    public var markRect: CGRect = .zero
    public let collapsed: CGRect           // panel frame when collapsed
    public let expanded: CGRect            // the expanded sheet (home: cards + switcher)
    public var chat: CGRect = .zero        // the expanded sheet on the 3PO tab (taller)
    public var canvas: CGRect = .zero      // the ONE fixed panel frame: every state draws inside it (no per-frame setFrame)
    /// The alert shell: the collapsed shape widened INLINE in the menu bar row (exactly the notch's height, centered on the
    /// notch) for a few seconds, the way Boring Notch's sneak peek works: the client on the left of the notch, what happened
    /// on the right. Then it retracts.
    public var peek: CGRect = .zero
    /// Notch mode: the status-text zone of the collapsed assembly — right of the mark square, inside
    /// the band, so [dots][mark][text] reads as one notch. It is part of `collapsed`, so hover and
    /// click on it open Peek.
    public var wing: CGRect = .zero
    /// Notch mode: the status-dots zone of the collapsed assembly — the band-height strip at the
    /// assembly's left end (the left ear segment on a hardware notch). Part of `collapsed`.
    public var dotsRect: CGRect = .zero
    /// Notch mode: a 2 pt line hanging just under the notch (the notch itself has no pixels), for live progress.
    /// Not a hit rect: it never takes a click.
    public var progressLine: CGRect = .zero
    /// Notch mode: a thin strip along the very top screen edge, a little wider than the notch. The pointer pinned there
    /// opens Peek, but this strip never takes a click (it is not part of any hit rect), so the menu bar stays usable.
    public var edgeTrigger: CGRect = .zero

    public enum Surface: Sendable { case collapsed, peek, home, chat }
    /// The live, clickable area for a state (global coordinates). Outside it the panel ignores the mouse (click-through).
    public func hitRect(_ s: Surface) -> CGRect {
        switch s {
        case .collapsed: return collapsed
        case .peek: return peek == .zero ? collapsed : peek
        case .home: return expanded
        case .chat: return chat == .zero ? expanded : chat
        }
    }
    /// Is a global point on the edge-trigger strip? (Collapsed notch only; nothing here ever captures the mouse.)
    public func triggers(at p: CGPoint) -> Bool { edgeTrigger != .zero && edgeTrigger.contains(p) }

    /// A collapsed-state rect scaled by `k` about the collapsed assembly's top-center — the
    /// hover-grown state's geometry. The view grows via a scale effect on the same anchor; this
    /// pure version serves hit-testing (the grown rect is the shell while grown — the hysteresis
    /// that keeps the growth from strobing at its edge) and the canvas union.
    public func grown(_ r: CGRect, by k: CGFloat) -> CGRect {
        let ax = collapsed.midX, ay = collapsed.maxY
        return CGRect(x: ax + (r.minX - ax) * k, y: ay + (r.minY - ay) * k, width: r.width * k, height: r.height * k)
    }
}

/// A seam: a pinned notch-geometry pick can replace this without touching the panel code.
public protocol PeakGeometryProviding: Sendable {
    func layout(for screen: ScreenDescriptor) -> PeakLayout
}

public struct PeakGeometry: PeakGeometryProviding {
    public var expandedSize = CGSize(width: 620, height: 360)
    public var chatSize = CGSize(width: 620, height: 520)
    public var glowMargin: CGFloat = 28                  // room for the rim glow / shadow / pop outside the shell
    public var pillSize = CGSize(width: 232, height: 32)       // 32 pt mark square + the status text (was 196 before the mark)
    public var pillTopGap: CGFloat = 4
    public var peekWidth: CGFloat = 540                        // notch mode: ~145 pt of text each side of the 250 pt notch
    public var pillPeekWidth: CGFloat = 440
    public var edgeTriggerSlack: CGFloat = 40                  // how far past each notch edge the top-edge trigger reaches
    public var edgeTriggerHeight: CGFloat = 3
    public var wingWidth: CGFloat = 96                          // fits "PRESENTING"
    /// The collapsed notch assembly (Christopher's spec, Nov 17, 2026): the assembly stays inside
    /// the notch silhouette / menu-bar band — never dipping below it — as [dots][mark][status
    /// text]. The dots zone at the assembly's left end; the status-text zone right of the mark.
    public var dotsZoneWidth: CGFloat = 30
    public var textWingBand: CGFloat = 184
    /// A plain external display's virtual notch: centered at the top of the screen, a bit bigger than a
    /// hardware notch so it reads as a notch on a big display (Studio Display menu-bar band is ~25 pt).
    public var virtualNotchSize = CGSize(width: 230, height: 46)
    public init() {}

    public func layout(for s: ScreenDescriptor) -> PeakLayout {
        let top = s.frame.maxY
        if s.hasNotch, let l = s.auxiliaryTopLeft, let r = s.auxiliaryTopRight {
            let notch = CGRect(x: l.maxX, y: top - s.safeAreaTop, width: max(0, r.minX - l.maxX), height: s.safeAreaTop)
            return notchLayout(for: s, notch: notch, virtual: false)
        }
        // No safe-area top and no auxiliary areas: a normal external display. It gets a VIRTUAL notch —
        // Peek's own notch-shaped row at the top-center — instead of a pill hanging below the menu bar.
        // (The odd fallback — safeAreaTop > 0 but no auxiliary areas — stays a pill: it claims a notch
        // geometry we cannot see, so we do not invent one.)
        if s.safeAreaTop == 0, s.auxiliaryTopLeft == nil, s.auxiliaryTopRight == nil {
            let notch = CGRect(x: s.frame.midX - virtualNotchSize.width / 2, y: top - virtualNotchSize.height,
                               width: virtualNotchSize.width, height: virtualNotchSize.height)
            return notchLayout(for: s, notch: notch, virtual: true)
        }
        let collapsed = CGRect(x: s.frame.midX - pillSize.width / 2, y: top - pillTopGap - pillSize.height,
                               width: pillSize.width, height: pillSize.height)
        let expanded = CGRect(x: s.frame.midX - expandedSize.width / 2, y: top - pillTopGap - expandedSize.height,
                              width: expandedSize.width, height: expandedSize.height)
        let chat = CGRect(x: s.frame.midX - chatSize.width / 2, y: top - pillTopGap - chatSize.height,
                          width: chatSize.width, height: chatSize.height)
        let peek = CGRect(x: s.frame.midX - pillPeekWidth / 2, y: collapsed.minY, width: pillPeekWidth, height: pillSize.height)
        var l = PeakLayout(mode: .pill, notchRect: nil, collapsed: collapsed, expanded: clamp(expanded, s.frame))
        l.markRect = CGRect(x: collapsed.minX, y: collapsed.minY, width: pillSize.height, height: pillSize.height)
        return finish(l, chat: clamp(chat, s.frame), peek: clamp(peek, s.frame), edge: .zero, s)
    }

    /// The notch-mode layout, shared by the hardware notch and the virtual notch.
    /// Christopher's spec (Nov 17, 2026): the collapsed assembly stays INSIDE the notch silhouette /
    /// menu-bar band — never dipping below it — with the colored status dots at the left and the
    /// mark centered: [dots][mark][status text], every zone inside the band's height.
    /// Virtual notch: Peek draws the silhouette, so the mark sits at its exact center, the dots in
    /// the zone to its left, the text to its right; the band is the display's own menu-bar height.
    /// Hardware notch: the notch rect is the camera housing — a hole in the display with no pixels —
    /// so the mark cannot sit at the notch's center (it would be invisible, the original bug). The
    /// closest faithful arrangement: the dots take the left ear, the mark the right ear hard against
    /// the housing, the text after it — the dots/mark pair straddles the housing symmetrically,
    /// all inside the band (the notch's own height). Expanded / peek / chat stay centered on the
    /// notch's midX.
    private func notchLayout(for s: ScreenDescriptor, notch: CGRect, virtual: Bool) -> PeakLayout {
        let top = s.frame.maxY
        let bandH = virtual ? (s.menuBarHeight > 0 ? s.menuBarHeight : 30) : notch.height
        let bandY = top - bandH
        let side = max(20, bandH - 4)                    // the mark square, inside the band
        let markY = bandY + (bandH - side) / 2
        let collapsed: CGRect
        let markRect: CGRect
        let dotsRect: CGRect
        let wingRect: CGRect
        if virtual {
            let total = dotsZoneWidth + side + textWingBand
            collapsed = CGRect(x: s.frame.midX - total / 2, y: bandY, width: total, height: bandH)
            dotsRect = CGRect(x: collapsed.minX, y: bandY, width: dotsZoneWidth, height: bandH)
            markRect = CGRect(x: s.frame.midX - side / 2, y: markY, width: side, height: side)
            wingRect = CGRect(x: markRect.maxX, y: bandY, width: textWingBand, height: bandH)
        } else {
            collapsed = CGRect(x: notch.minX - dotsZoneWidth, y: bandY,
                               width: dotsZoneWidth + notch.width + side + textWingBand, height: bandH)
            dotsRect = CGRect(x: collapsed.minX, y: bandY, width: dotsZoneWidth, height: bandH)
            markRect = CGRect(x: notch.maxX, y: markY, width: side, height: side)
            wingRect = CGRect(x: markRect.maxX, y: bandY, width: textWingBand, height: bandH)
        }
        let w = max(expandedSize.width, collapsed.width)
        let expanded = CGRect(x: notch.midX - w / 2, y: top - expandedSize.height, width: w, height: expandedSize.height)
        let cw = max(chatSize.width, collapsed.width)
        let chat = CGRect(x: notch.midX - cw / 2, y: top - chatSize.height, width: cw, height: chatSize.height)
        let pw = max(peekWidth, collapsed.width)
        let peek = CGRect(x: notch.midX - pw / 2, y: bandY, width: pw, height: bandH)
        let edge = CGRect(x: collapsed.minX - edgeTriggerSlack, y: top - edgeTriggerHeight,
                          width: collapsed.width + 2 * edgeTriggerSlack, height: edgeTriggerHeight)
        var l = PeakLayout(mode: .notch, notchRect: notch, collapsed: collapsed, expanded: clamp(expanded, s.frame))
        l.virtualNotch = virtual
        l.markRect = markRect
        l.dotsRect = dotsRect
        var out = finish(l, chat: clamp(chat, s.frame), peek: clamp(peek, s.frame), edge: edge, s)
        out.wing = wingRect
        out.progressLine = CGRect(x: notch.minX + 12, y: bandY - 5, width: max(0, notch.width - 24), height: 2)
        return out
    }

    /// The fixed canvas: the union of every state plus the glow margin, pinned to the screen's top edge.
    func finish(_ l: PeakLayout, chat: CGRect, peek: CGRect, edge: CGRect, _ s: ScreenDescriptor) -> PeakLayout {
        var out = l
        out.chat = chat; out.peek = peek; out.edgeTrigger = edge
        if let n = l.notchRect {
            // The wing is now the status-text part of the collapsed row: everything right of the mark square.
            out.wing = l.markRect != .zero
                ? CGRect(x: l.markRect.maxX, y: l.collapsed.minY, width: max(0, l.collapsed.width - l.markRect.width), height: l.collapsed.height)
                : CGRect(x: n.minX - wingWidth, y: n.minY, width: wingWidth, height: n.height)
            out.progressLine = CGRect(x: l.collapsed.minX + 12, y: n.minY - 5, width: max(0, l.collapsed.width - 24), height: 2)
        }
        var u = l.collapsed.union(l.expanded).union(chat).union(peek)
        if l.mode == .notch { u = u.union(l.grown(l.collapsed, by: PeakMotion.hoverGrowScale)) }   // room for the hover-grown assembly
        var c = CGRect(x: u.minX - glowMargin, y: u.minY - glowMargin, width: u.width + 2 * glowMargin, height: s.frame.maxY - (u.minY - glowMargin))
        c.origin.x = max(c.minX, s.frame.minX); if c.maxX > s.frame.maxX { c.size.width = s.frame.maxX - c.minX }
        out.canvas = c
        return out
    }

    func clamp(_ r: CGRect, _ f: CGRect) -> CGRect {
        var r = r
        r.origin.x = min(max(r.minX, f.minX), f.maxX - r.width)
        return r
    }
}

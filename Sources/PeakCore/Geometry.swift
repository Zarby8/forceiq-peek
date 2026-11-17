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
    /// every mode. In notch mode it is the content row's left square — on a virtual notch that row is
    /// the drawn notch itself; on the hardware notch the row is the CHIN below the camera housing,
    /// because the housing's own rect has no display pixels and can never show the mark.
    public var markRect: CGRect = .zero
    public let collapsed: CGRect           // panel frame when collapsed
    public let expanded: CGRect            // the expanded sheet (home: cards + switcher)
    public var chat: CGRect = .zero        // the expanded sheet on the 3PO tab (taller)
    public var canvas: CGRect = .zero      // the ONE fixed panel frame: every state draws inside it (no per-frame setFrame)
    /// The alert shell: the collapsed shape widened INLINE in the menu bar row (exactly the notch's height, centered on the
    /// notch) for a few seconds, the way Boring Notch's sneak peek works: the client on the left of the notch, what happened
    /// on the right. Then it retracts.
    public var peek: CGRect = .zero
    /// Notch mode: the status-text part of the collapsed content row — right of the mark square, in
    /// the same visible strip (the drawn virtual notch, or the chin below the hardware housing), so
    /// [mark][text] reads as one notch. It is part of `collapsed`, so hover and click on it open Peek.
    public var wing: CGRect = .zero
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
    /// Collapsed notch row: the status text wing beside the mark square (the mark itself is one row-height square).
    public var textWingVirtual: CGFloat = 184
    /// Hardware notch: the visible content lives in a chin below the camera housing (the housing's
    /// rect has no pixels): the chin's height — also the mark's side — and its status-text width.
    public var chinHeight: CGFloat = 36
    public var textWingChin: CGFloat = 184
    /// Hardware notch: how far the black housing reaches into each ear beside the camera housing,
    /// so the drawn shape and the hardware read as one piece.
    public var earShoulder: CGFloat = 8
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
    /// Virtual: the notch rect IS the collapsed row — [mark square][status text] — because Peek draws
    /// the whole notch and every point of it is real display.
    /// Hardware: the notch rect is the camera housing — a hole in the display with no pixels, so
    /// content placed there is invisible at any window level (the bug this replaces: the row started
    /// at the notch's left edge, inside the housing, and could not be seen). The recipe the working
    /// notch apps use: a black housing covers the notch plus a slim shoulder of each ear, and the
    /// visible content — [mark square][status text] — sits in a CHIN below the housing, on real
    /// display. Expanded / peek / chat stay centered on the notch's midX.
    private func notchLayout(for s: ScreenDescriptor, notch: CGRect, virtual: Bool) -> PeakLayout {
        let top = s.frame.maxY
        let collapsed: CGRect
        let markRect: CGRect
        var wingOverride: CGRect? = nil
        var progressOverride: CGRect? = nil
        if virtual {
            collapsed = notch
            markRect = CGRect(x: notch.minX, y: notch.minY, width: notch.height, height: notch.height)
        } else {
            let contentW = chinHeight + textWingChin
            let housingW = max(notch.width, contentW) + 2 * earShoulder
            collapsed = CGRect(x: notch.midX - housingW / 2, y: notch.minY - chinHeight,
                               width: housingW, height: notch.height + chinHeight)
            let rowX = notch.midX - contentW / 2
            let rowY = notch.minY - chinHeight
            markRect = CGRect(x: rowX, y: rowY, width: chinHeight, height: chinHeight)
            wingOverride = CGRect(x: rowX + chinHeight, y: rowY, width: textWingChin, height: chinHeight)
            progressOverride = CGRect(x: rowX + 12, y: rowY - 5, width: max(0, contentW - 24), height: 2)
        }
        let w = max(expandedSize.width, collapsed.width)
        let expanded = CGRect(x: notch.midX - w / 2, y: top - expandedSize.height, width: w, height: expandedSize.height)
        let cw = max(chatSize.width, collapsed.width)
        let chat = CGRect(x: notch.midX - cw / 2, y: top - chatSize.height, width: cw, height: chatSize.height)
        let pw = max(peekWidth, collapsed.width)
        let peek = CGRect(x: notch.midX - pw / 2, y: notch.minY, width: pw, height: notch.height)
        let edge = CGRect(x: collapsed.minX - edgeTriggerSlack, y: top - edgeTriggerHeight,
                          width: collapsed.width + 2 * edgeTriggerSlack, height: edgeTriggerHeight)
        var l = PeakLayout(mode: .notch, notchRect: notch, collapsed: collapsed, expanded: clamp(expanded, s.frame))
        l.virtualNotch = virtual
        l.markRect = markRect
        var out = finish(l, chat: clamp(chat, s.frame), peek: clamp(peek, s.frame), edge: edge, s)
        if let wingOverride { out.wing = wingOverride }
        if let progressOverride { out.progressLine = progressOverride }
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
        let u = l.collapsed.union(l.expanded).union(chat).union(peek)
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

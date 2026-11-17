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
    public let notchRect: CGRect?          // the notch cut-out (hardware), or the virtual notch silhouette on a plain external display
    /// True when `notchRect` is a VIRTUAL notch: the display has no hardware notch (no safe-area top, no
    /// auxiliary areas), so Peek draws its own notch-shaped silhouette at the top-center of the screen.
    public var virtualNotch: Bool = false
    /// The mark square (screen coords): the selected mark (ghost / BOB / eyes) always renders here, in
    /// every mode. In notch mode it sits at the notch's horizontal CENTER: on a virtual notch, centered
    /// inside the silhouette in the band; on the hardware notch, centered in the chin of Peek's own
    /// silhouette directly below the camera housing — the housing's rect has no display pixels, so
    /// nothing can render inside it, and the centered mark lives in the silhouette's chin instead of
    /// being pushed into an ear.
    public var markRect: CGRect = .zero
    public let collapsed: CGRect           // panel frame when collapsed: in notch mode, the silhouette itself
    public let expanded: CGRect            // the expanded sheet's LAYOUT frame (it renders at PeakMotion.sheetScale — see grown)
    public var chat: CGRect = .zero        // the expanded sheet on the 3PO tab (taller; same scale rule)
    public var canvas: CGRect = .zero      // the ONE fixed panel frame: every state draws inside it (no per-frame setFrame)
    /// The alert shell: the collapsed shape widened INLINE in the menu bar row (exactly the notch's height, centered on the
    /// notch) for a few seconds, the way Boring Notch's sneak peek works: the client on the left of the notch, what happened
    /// on the right. Then it retracts.
    public var peek: CGRect = .zero
    /// Legacy text zone. The collapsed notch carries NO text at all (Christopher, Nov 17, 2026: no
    /// "PEEK" wordmark, no status line — text lives in the sheet only), so this is always .zero in
    /// notch mode. Kept for the pill fallback's bookkeeping.
    public var wing: CGRect = .zero
    /// Notch mode: the status-dots zone. On the hardware notch it is the left-ear strip immediately
    /// left of the notch (visible pixels, vertically centered in the menu bar) — deliberately NOT
    /// part of `collapsed`, whose width is exactly the notch's. On a virtual notch it is the
    /// silhouette's left end, inside it. Drawn as an overlay, never inside the silhouette mask.
    public var dotsRect: CGRect = .zero
    /// Notch mode: a 2 pt line hanging just under the silhouette, for live progress.
    /// Not a hit rect: it never takes a click.
    public var progressLine: CGRect = .zero
    /// Notch mode: a thin strip along the very top screen edge, a little wider than the notch. The pointer pinned there
    /// opens Peek, but this strip never takes a click (it is not part of any hit rect), so the menu bar stays usable.
    public var edgeTrigger: CGRect = .zero

    public enum Surface: Sendable { case collapsed, peek, home, chat }
    /// The live, clickable area for a state (global coordinates, LAYOUT size — the sheet's on-screen
    /// rect is `grown(hitRect, by: PeakMotion.sheetScale)`; PanelHost tests against that). Outside
    /// it the panel ignores the mouse (click-through).
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

    /// A rect scaled by `k` about the notch assembly's top-center — the EXPANDED sheet's on-screen
    /// geometry (Christopher's 25% belongs to the expanded window: the sheet renders at
    /// PeakMotion.sheetScale, anchored at the notch's top-center, expanding downward). The collapsed
    /// rect is the anchor because the collapsed silhouette and the sheet share that exact point:
    /// both are centered on the notch and flush with the screen's top edge. The collapsed state
    /// itself is NEVER scaled.
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
    public var wingWidth: CGFloat = 96                          // retained status-text measure (fits "PRESENTING"); the collapsed notch shows no text
    /// The collapsed notch assembly (Christopher's spec, Nov 17, 2026): the footprint IS the notch's
    /// dimensions — on the hardware notch the panel is exactly the notch's width, centered on it,
    /// with the ghost at the notch's horizontal center in the silhouette's chin below the housing,
    /// and the dots in the left ear. No text, ever, in the collapsed state.
    public var dotsZoneWidth: CGFloat = 30
    /// The chin of the hardware-notch silhouette: how far the centered ghost sits below the housing,
    /// and the breathing room under it. The silhouette is notch.height + chinTopGap + mark + chinBottomGap
    /// tall — as small as the ghost allows.
    public var chinTopGap: CGFloat = 1
    public var chinBottomGap: CGFloat = 2
    /// A virtual notch's side gap between the dots zone / silhouette edge and the centered mark.
    public var silhouetteGap: CGFloat = 4
    public init() {}

    public func layout(for s: ScreenDescriptor) -> PeakLayout {
        let top = s.frame.maxY
        if s.hasNotch, let l = s.auxiliaryTopLeft, let r = s.auxiliaryTopRight {
            let notch = CGRect(x: l.maxX, y: top - s.safeAreaTop, width: max(0, r.minX - l.maxX), height: s.safeAreaTop)
            return notchLayout(for: s, notch: notch, virtual: false)
        }
        // No safe-area top and no auxiliary areas: a normal external display. It gets a VIRTUAL notch —
        // Peek's own notch-shaped silhouette at the top-center — instead of a pill hanging below the menu bar.
        // (The odd fallback — safeAreaTop > 0 but no auxiliary areas — stays a pill: it claims a notch
        // geometry we cannot see, so we do not invent one.)
        if s.safeAreaTop == 0, s.auxiliaryTopLeft == nil, s.auxiliaryTopRight == nil {
            return notchLayout(for: s, notch: nil, virtual: true)
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
    /// Christopher's spec (Nov 17, 2026, third statement of it): the collapsed app lives INSIDE the
    /// notch's dimensions. Hardware notch: `collapsed` is exactly the notch's width, centered on
    /// the notch; the black silhouette extends below the camera housing only as far as the
    /// centered ghost needs (the housing itself has no pixels — a ghost at the notch's center can
    /// only be visible in the chin), the ghost horizontally CENTERED on the notch; the status dots
    /// sit in the left ear, the visible strip beside the housing. Virtual notch: the silhouette is
    /// drawn by Peek, contained in the display's menu-bar band, ghost + dots + small margins only,
    /// ghost centered, dots at its left end. NO text in either collapsed state — the wordmark and
    /// the status line live in the expanded sheet only. The sheet (expanded / chat) keeps its
    /// layout size and renders 25% bigger (PeakMotion.sheetScale) about the same top-center.
    private func notchLayout(for s: ScreenDescriptor, notch: CGRect?, virtual: Bool) -> PeakLayout {
        let top = s.frame.maxY
        let centerX = virtual ? s.frame.midX : notch!.midX
        let collapsed: CGRect
        let markRect: CGRect
        let dotsRect: CGRect
        let bandH: CGFloat          // the menu-bar row the peek shell shares
        let bandY: CGFloat
        if virtual {
            bandH = s.menuBarHeight > 0 ? s.menuBarHeight : 30
            bandY = top - bandH
            let side = max(20, bandH - 4)                    // the mark square, inside the band
            let width = side + 2 * (dotsZoneWidth + silhouetteGap)
            collapsed = CGRect(x: centerX - width / 2, y: bandY, width: width, height: bandH)
            markRect = CGRect(x: centerX - side / 2, y: bandY + (bandH - side) / 2, width: side, height: side)
            dotsRect = CGRect(x: collapsed.minX, y: bandY, width: dotsZoneWidth, height: bandH)
        } else {
            let n = notch!
            bandH = n.height
            bandY = top - bandH
            let side = max(20, n.height - 4)                 // the mark square: sized to fit the band
            let height = n.height + chinTopGap + side + chinBottomGap
            collapsed = CGRect(x: n.minX, y: top - height, width: n.width, height: height)
            markRect = CGRect(x: n.midX - side / 2, y: top - n.height - chinTopGap - side, width: side, height: side)
            let earH = max(s.menuBarHeight, n.height)        // the ear strip is as tall as the menu bar itself
            dotsRect = CGRect(x: n.minX - dotsZoneWidth, y: top - earH, width: dotsZoneWidth, height: earH)
        }
        let expanded = CGRect(x: centerX - expandedSize.width / 2, y: top - expandedSize.height, width: expandedSize.width, height: expandedSize.height)
        let chat = CGRect(x: centerX - chatSize.width / 2, y: top - chatSize.height, width: chatSize.width, height: chatSize.height)
        let pw = max(peekWidth, collapsed.width)
        let peek = CGRect(x: centerX - pw / 2, y: bandY, width: pw, height: bandH)
        let edge = CGRect(x: dotsRect.minX - edgeTriggerSlack, y: top - edgeTriggerHeight,
                          width: (collapsed.maxX - dotsRect.minX) + 2 * edgeTriggerSlack, height: edgeTriggerHeight)
        var l = PeakLayout(mode: .notch, notchRect: virtual ? collapsed : notch, collapsed: collapsed, expanded: clamp(expanded, s.frame))
        l.virtualNotch = virtual
        l.markRect = markRect
        l.dotsRect = dotsRect
        var out = finish(l, chat: clamp(chat, s.frame), peek: clamp(peek, s.frame), edge: edge, s)
        out.progressLine = CGRect(x: collapsed.minX + 12, y: collapsed.minY - 5, width: max(0, collapsed.width - 24), height: 2)
        return out
    }

    /// The fixed canvas: the union of every state plus the glow margin, pinned to the screen's top edge.
    func finish(_ l: PeakLayout, chat: CGRect, peek: CGRect, edge: CGRect, _ s: ScreenDescriptor) -> PeakLayout {
        var out = l
        out.chat = chat; out.peek = peek; out.edgeTrigger = edge
        var u = l.collapsed.union(l.expanded).union(chat).union(peek).union(l.dotsRect).union(l.markRect)
        if l.mode == .notch {   // the sheet renders at sheetScale: the canvas must hold its on-screen rect
            u = u.union(l.grown(l.expanded, by: PeakMotion.sheetScale)).union(l.grown(chat, by: PeakMotion.sheetScale))
        }
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

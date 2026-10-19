import CoreGraphics
import Foundation

/// What Peak needs to know about one display (AppKit fills it from NSScreen; tests use mocks).
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
    public let notchRect: CGRect?          // the hardware notch cut-out (notch mode only)
    public let collapsed: CGRect           // panel frame when collapsed
    public let expanded: CGRect            // the expanded sheet (home: cards + switcher)
    public var chat: CGRect = .zero        // the expanded sheet on the 3PO tab (taller)
    public var canvas: CGRect = .zero      // the ONE fixed panel frame: every state draws inside it (no per-frame setFrame)

    public enum Surface: Sendable { case collapsed, home, chat }
    /// The live, clickable area for a state (global coordinates). Outside it the panel ignores the mouse (click-through).
    public func hitRect(_ s: Surface) -> CGRect {
        switch s { case .collapsed: return collapsed; case .home: return expanded; case .chat: return chat == .zero ? expanded : chat }
    }
}

/// A seam: a pinned notch-geometry pick can replace this without touching the panel code.
public protocol PeakGeometryProviding: Sendable {
    func layout(for screen: ScreenDescriptor) -> PeakLayout
}

public struct PeakGeometry: PeakGeometryProviding {
    public var ear: CGFloat = 44                         // room either side of the notch for the Ghost mark / badge
    public var expandedSize = CGSize(width: 620, height: 360)
    public var chatSize = CGSize(width: 620, height: 520)
    public var glowMargin: CGFloat = 28                  // room for the rim glow / shadow / pop outside the shell
    public var pillSize = CGSize(width: 196, height: 32)
    public var pillTopGap: CGFloat = 4
    public init() {}

    public func layout(for s: ScreenDescriptor) -> PeakLayout {
        let top = s.frame.maxY
        if s.hasNotch, let l = s.auxiliaryTopLeft, let r = s.auxiliaryTopRight {
            let notch = CGRect(x: l.maxX, y: top - s.safeAreaTop, width: max(0, r.minX - l.maxX), height: s.safeAreaTop)
            let collapsed = CGRect(x: notch.minX - ear, y: top - s.safeAreaTop, width: notch.width + 2 * ear, height: s.safeAreaTop)
            let w = max(expandedSize.width, collapsed.width)
            let expanded = CGRect(x: notch.midX - w / 2, y: top - expandedSize.height, width: w, height: expandedSize.height)
            let cw = max(chatSize.width, collapsed.width)
            let chat = CGRect(x: notch.midX - cw / 2, y: top - chatSize.height, width: cw, height: chatSize.height)
            return finish(PeakLayout(mode: .notch, notchRect: notch, collapsed: collapsed, expanded: clamp(expanded, s.frame)), chat: clamp(chat, s.frame), s)
        }
        let collapsed = CGRect(x: s.frame.midX - pillSize.width / 2, y: top - pillTopGap - pillSize.height,
                               width: pillSize.width, height: pillSize.height)
        let expanded = CGRect(x: s.frame.midX - expandedSize.width / 2, y: top - pillTopGap - expandedSize.height,
                              width: expandedSize.width, height: expandedSize.height)
        let chat = CGRect(x: s.frame.midX - chatSize.width / 2, y: top - pillTopGap - chatSize.height,
                          width: chatSize.width, height: chatSize.height)
        return finish(PeakLayout(mode: .pill, notchRect: nil, collapsed: collapsed, expanded: clamp(expanded, s.frame)), chat: clamp(chat, s.frame), s)
    }

    /// The fixed canvas: the union of every state plus the glow margin, pinned to the screen's top edge.
    func finish(_ l: PeakLayout, chat: CGRect, _ s: ScreenDescriptor) -> PeakLayout {
        var out = l
        out.chat = chat
        let u = l.collapsed.union(l.expanded).union(chat)
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

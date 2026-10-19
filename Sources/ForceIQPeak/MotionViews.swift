import PeakCore
import SwiftUI

// Motion polish (PeakMotion tokens). Every effect here is a one-shot on an event (a card appears, a card leaves, a
// bubble arrives, the composer takes focus) and settles; none repeats. Text is never faded: the moves are offset,
// scale and a light blur-to-sharp at full opacity. Under Reduce Motion each one is skipped (no motion).

extension Motion {
    /// Approval arrival pop: a touch bouncier than the main spring.
    static func pop(_ reduce: Bool) -> Animation {
        reduce ? .easeInOut(duration: PeakMotion.reduceCrossfade) : .spring(response: PeakMotion.popResponse, dampingFraction: PeakMotion.popDamping)
    }
    /// Removal: a quick, non-bouncy squeeze so the list closes up without wobble.
    static func collapse(_ reduce: Bool) -> Animation {
        reduce ? .easeInOut(duration: PeakMotion.reduceCrossfade) : .spring(response: PeakMotion.collapseResponse, dampingFraction: PeakMotion.collapseDamping)
    }
}

/// Staggered rise + sharpen when a card first appears (sheet opens, or a new card lands). `pop` (approvals) also
/// scales up from PeakMotion.popScale on the pop spring. Runs once per appearance; Reduce Motion: shown at once.
struct StaggeredEntry: ViewModifier {
    let index: Int
    var pop = false
    let reduceMotion: Bool
    @State private var shown = false
    func body(content: Content) -> some View {
        let on = shown || reduceMotion
        content
            .offset(y: on ? 0 : PeakMotion.entryRise)
            .blur(radius: on ? 0 : PeakMotion.entryBlur)
            .scaleEffect(on || !pop ? 1 : PeakMotion.popScale, anchor: .top)
            .onAppear {
                guard !reduceMotion, !shown else { return }
                let a = pop ? Motion.pop(false) : Motion.spring(false)
                withAnimation(a.delay(PeakMotion.staggerDelay(index))) { shown = true }
            }
    }
}

/// A removed card squeezes its height to its top edge (the cards below slide up into the slot as the stack relayouts).
struct CollapseOut: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.scaleEffect(x: 1, y: on ? 0.02 : 1, anchor: .top).blur(radius: on ? PeakMotion.entryBlur : 0)
    }
}

/// A chat bubble arriving from its own side: user from the trailing edge, 3PO from the leading edge, rising a little.
struct BubbleIn: ViewModifier {
    let dx: CGFloat
    let on: Bool
    func body(content: Content) -> some View {
        content.offset(x: on ? dx : 0, y: on ? PeakMotion.bubbleRise : 0).blur(radius: on ? PeakMotion.entryBlur : 0)
    }
}

/// An approval / proposal card arriving inside a reply: a small pop from the top edge, sharp by the end.
struct PopIn: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.scaleEffect(on ? PeakMotion.popScale : 1, anchor: .top).blur(radius: on ? PeakMotion.entryBlur : 0)
    }
}

/// Blur-to-sharp at full opacity: how text "fades in" in Peek (white stays pure white the whole way).
struct Sharpen: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { content.blur(radius: on ? PeakMotion.entryBlur : 0) }
}

extension AnyTransition {
    /// Text that appears in place (the collapsed pill's title, the voice strip): sharpens in, leaves at once.
    static func sharpen(_ reduce: Bool) -> AnyTransition {
        reduce ? .identity : .asymmetric(insertion: .modifier(active: Sharpen(on: true), identity: Sharpen(on: false)), removal: .identity)
    }
    /// Card list removal: the height collapse; insertion is handled by StaggeredEntry (so the first open staggers too).
    static func cardCollapse(_ reduce: Bool) -> AnyTransition {
        reduce ? .identity : .asymmetric(insertion: .identity,
                                         removal: .modifier(active: CollapseOut(on: true), identity: CollapseOut(on: false)))
    }
    /// A chat bubble's entry (no exit: the transcript only grows).
    static func bubble(user: Bool, _ reduce: Bool) -> AnyTransition {
        let dx = CGFloat(user ? PeakMotion.bubbleSlide : -PeakMotion.bubbleSlide)
        return reduce ? .identity : .asymmetric(insertion: .modifier(active: BubbleIn(dx: dx, on: true), identity: BubbleIn(dx: dx, on: false)),
                                                removal: .identity)
    }
    /// An approval / proposal / skill card's arrival pop.
    static func arrivalPop(_ reduce: Bool) -> AnyTransition {
        reduce ? .identity : .asymmetric(insertion: .modifier(active: PopIn(on: true), identity: PopIn(on: false)).animation(Motion.pop(false)),
                                         removal: .identity)
    }
}

/// The composer's ring: gold at rest, green and 2 pt with a soft green halo while focused (or dictating), eased in
/// over PeakMotion.focusRing. One change per focus event; Reduce Motion: the colour and width switch at once.
struct FocusRing: ViewModifier {
    let active: Bool
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? Color.peakGreen : Color.peakGold, lineWidth: active ? 2 : 1))
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black)
                .shadow(color: Color.peakGreen.opacity(active ? 0.55 : 0), radius: active ? PeakMotion.focusHaloRadius : 0))
            .animation(reduceMotion ? nil : .easeOut(duration: PeakMotion.focusRing), value: active)
    }
}

/// A tap target at least PeakMotion.minTapTarget square around a smaller visual (the hit area grows, the look doesn't).
struct TapTarget: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(minWidth: PeakMotion.minTapTarget, minHeight: PeakMotion.minTapTarget).contentShape(Rectangle())
    }
}

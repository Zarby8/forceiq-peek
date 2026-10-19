import Foundation

/// Peak's motion tokens (the "easy UX, beautiful with motion" polish). Every value is a finite, event-triggered move:
/// nothing here repeats, and each view falls back to a short crossfade of the shell or no motion at all under Reduce
/// Motion. Text is never faded: entries rise and sharpen from a light blur at full opacity (white stays pure white).
/// MotionPolishGuardTests pins every number below.
public enum PeakMotion {
    /// The ONE spring for expand / collapse and every morph (shell path, matched-geometry ghost, title, badge, pills).
    public static let springResponse = 0.38
    public static let springDamping = 0.82
    /// Hover lift on the collapsed pill: critically-ish damped, so it never overshoots or wobbles under the pointer.
    public static let hoverResponse = 0.24
    public static let hoverDamping = 0.9
    public static let hoverScale = 1.02
    /// Reduce Motion: a short crossfade of the shell (never of text) instead of a spring.
    public static let reduceCrossfade = 0.16

    /// Card entry: each card rises `entryRise` pt and sharpens from `entryBlur` pt, `staggerStep` s after the one above;
    /// cards past `staggerMaxIndex` start together, so a long list is still fully in within `maxEntryDelay`.
    public static let entryRise = 8.0
    public static let entryBlur = 2.5
    public static let staggerStep = 0.04
    public static let staggerMaxIndex = 6
    public static var maxEntryDelay: Double { Double(staggerMaxIndex) * staggerStep }
    public static func staggerDelay(_ index: Int) -> Double { Double(min(max(index, 0), staggerMaxIndex)) * staggerStep }

    /// Approval cards pop on arrival: from `popScale`, on a slightly bouncier spring.
    public static let popScale = 0.94
    public static let popResponse = 0.34
    public static let popDamping = 0.62
    /// A removed card squeezes its height to the top edge while the cards below slide up into its slot.
    public static let collapseResponse = 0.3
    public static let collapseDamping = 0.9

    /// Chat bubbles slide in from their own side (user: trailing, 3PO: leading) and rise a little.
    public static let bubbleSlide = 14.0
    public static let bubbleRise = 6.0
    /// The streaming answer: each new chunk lands at full white (no opacity fade on text, brand rule); the stream's
    /// own cadence is the motion.
    /// Composer focus ring: stroke 1 → 2 pt and a soft green halo, eased in this long.
    public static let focusRing = 0.18
    public static let focusHaloRadius = 5.0

    /// Every duration-like value above, for the finite-and-short guard.
    public static var allDurations: [Double] {
        [springResponse, hoverResponse, reduceCrossfade, staggerStep, maxEntryDelay, popResponse, collapseResponse, focusRing]
    }

    /// Smallest tap target (pt) for any control Peak draws: buttons, segmented pills, chips that take taps.
    public static let minTapTarget = 28.0
}

// ───────────────────────────── polish tour feed (FORCEIQ_PEAK_DEMO_TOUR=polish). Sample names only. ─────────────────────────────
extension DemoData {
    /// The motion-polish proof's desk: step 0 is the sample feed, step 1 adds one approval (it pops in), step 2 drops
    /// the family-link approval (its card collapses). Every row names a sample client.
    public static func polishSnapshot(step: Int, now: Date = Date()) -> EngineSnapshot {
        var s = snapshot(now: now)
        if step >= 1 {
            s.approvals.insert(ApprovalRow(id: "c0ffee000001", kind: "proposal", kindLabel: "Claude proposal",
                                           title: "Approve the Demo Hawks crest", why: "New crest found for the opponent",
                                           client: "Sample Skater", gate: "routine", touches: ["GOAT crest cache"],
                                           outputs: ["Crest on the title slide"], actLabel: "crest_approve", test: false), at: 0)
        }
        if step >= 2 { s.approvals.removeAll { $0.id == "0f9e8d7c6b5a" } }
        return s
    }
}

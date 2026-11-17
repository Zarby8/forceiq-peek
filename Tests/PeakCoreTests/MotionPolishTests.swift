import Foundation
import XCTest
@testable import PeakCore

// Motion polish guard: the new motion is one spring, finite, event-triggered, honours Reduce Motion, never fades text,
// and every control is a ≥ 28 pt target with the keyboard paths wired (Esc collapses, Return sends, ⌘K focuses).
final class MotionPolishTokenTests: XCTestCase {
    func testOneSpringForExpandAndCollapse() {
        XCTAssertEqual(PeakMotion.springResponse, 0.38)
        XCTAssertEqual(PeakMotion.springDamping, 0.82)
        XCTAssertGreaterThanOrEqual(PeakMotion.hoverDamping, 0.85, "the hover lift must not overshoot")
        XCTAssertLessThanOrEqual(PeakMotion.hoverScale, 1.03)
    }

    func testEveryDurationIsFiniteAndShort() {
        for d in PeakMotion.allDurations {
            XCTAssertTrue(d.isFinite && d > 0 && d <= 0.5, "motion value \(d) must be finite, positive and ≤ 0.5 s")
        }
    }

    func testStaggerIsCapped() {
        XCTAssertEqual(PeakMotion.staggerDelay(0), 0)
        XCTAssertEqual(PeakMotion.staggerDelay(-3), 0)
        XCTAssertEqual(PeakMotion.staggerDelay(2), 2 * PeakMotion.staggerStep, accuracy: 1e-12)
        XCTAssertEqual(PeakMotion.staggerDelay(500), PeakMotion.maxEntryDelay, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(PeakMotion.maxEntryDelay, 0.3, "a long list is fully in quickly")
    }

    func testEntriesAreSubtle() {
        XCTAssertLessThanOrEqual(PeakMotion.entryRise, 12)
        XCTAssertLessThanOrEqual(PeakMotion.entryBlur, 4)
        XCTAssertTrue((0.9..<1).contains(PeakMotion.popScale), "the approval pop is subtle")
        XCTAssertLessThanOrEqual(PeakMotion.bubbleSlide, 20)
    }

    func testTapTarget() { XCTAssertGreaterThanOrEqual(PeakMotion.minTapTarget, 28) }

    func testPolishTourFeedNamesEveryClient() {
        let base = DemoData.polishSnapshot(step: 0), more = DemoData.polishSnapshot(step: 1), less = DemoData.polishSnapshot(step: 2)
        XCTAssertEqual(more.approvals.count, base.approvals.count + 1)
        XCTAssertEqual(less.approvals.count, base.approvals.count)
        for s in [base, more, less] { for a in s.approvals { XCTAssertFalse(a.client.isEmpty); XCTAssertTrue(["Sample Skater", "Demo Player"].contains(a.client)) } }
    }
}

final class MotionPolishGuardTests: XCTestCase {
    func source(_ name: String) throws -> String {
        try XCTUnwrap(appSourceFiles().first { $0.name == name }, "\(name) not found").text
    }
    func code(_ name: String) throws -> String { codeLines(try source(name)).joined(separator: "\n") }
    func body(_ s: String, from a: String, to b: String) throws -> String {
        let r0 = try XCTUnwrap(s.range(of: a), a), r1 = try XCTUnwrap(s.range(of: b, range: r0.upperBound..<s.endIndex), b)
        return String(s[r0.lowerBound..<r1.lowerBound])
    }

    /// The polish modifiers never fade (opacity), never repeat, never tick a clock.
    func testPolishMotionIsFiniteAndNeverFadesText() throws {
        let m = try code("MotionViews.swift")
        for bad in ["repeatForever", "repeating:", "repeatCount", "TimelineView", "displayLink", "Timer.", "phaseAnimator"] {
            XCTAssertFalse(m.contains(bad), "MotionViews.swift uses \(bad): every polish move is a one-shot")
        }
        for s in ["struct StaggeredEntry", "struct CollapseOut", "struct BubbleIn", "struct PopIn", "struct Sharpen"] {
            let b = try body(m, from: s, to: "\n}\n")
            XCTAssertFalse(b.contains(".opacity("), "\(s) fades its content; text stays at full opacity (rise + sharpen instead)")
        }
    }

    /// Reduce Motion: every polish effect has a no-motion (or crossfade) branch.
    func testReduceMotionHonoured() throws {
        let m = try code("MotionViews.swift")
        for s in ["static func pop(", "static func collapse(", "static func cardCollapse(", "static func bubble(", "static func arrivalPop(", "static func sharpen("] {
            let b = try body(m, from: s, to: "\n    }\n")
            XCTAssertTrue(b.contains("reduce ?"), "\(s) has no Reduce Motion branch")
        }
        let entry = try body(m, from: "struct StaggeredEntry", to: "\n}\n")
        XCTAssertTrue(entry.contains("shown || reduceMotion") && entry.contains("guard !reduceMotion"), "the stagger is skipped under Reduce Motion")
        let ring = try body(m, from: "struct FocusRing", to: "\n}\n")
        XCTAssertTrue(ring.contains("reduceMotion ? nil"), "the focus ring switches at once under Reduce Motion")
        let v = try code("Views.swift")
        XCTAssertTrue(v.contains("PeakMotion.springResponse, dampingFraction: PeakMotion.springDamping"), "Motion.spring is the one spring")
        XCTAssertTrue(v.contains(".animation(Motion.hover(reduceMotion), value: hoverScale)"), "hover animates the scale (the pill lift / the notch growth) only")
        XCTAssertFalse(v.contains("value: panel.hovering)"), "an animation keyed to every hover flip re-animates the whole shell")
        let t = try code("ThreePOViews.swift")
        XCTAssertTrue(t.contains(".contentTransition(.identity)"), "the streamed text lands at full white")
        XCTAssertTrue(t.contains(".transition(.bubble(user: m.role == .user, reduceMotion))"))
    }

    /// The polish lands where it was asked for.
    func testWired() throws {
        let v = try code("Views.swift")
        XCTAssertTrue(v.contains("StaggeredEntry(index: i, pop: c.kind == .approval, reduceMotion: reduceMotion)"), "cards stagger; approvals pop")
        XCTAssertTrue(v.contains(".transition(.cardCollapse(reduceMotion))"), "a removed card collapses its height")
        XCTAssertTrue(v.contains(#"matchedGeometryEffect(id: "ghost", in: ns)"#) && v.contains(#"matchedGeometryEffect(id: "title", in: ns)"#))
        let t = try code("ThreePOViews.swift")
        XCTAssertTrue(t.contains(#"matchedGeometryEffect(id: "pick", in: ns)"#), "the model pill slides")
        XCTAssertTrue(try code("ThreePOMemoryViews.swift").contains(#"matchedGeometryEffect(id: "pane", in: ns)"#), "Chat / Memory slides")
        XCTAssertTrue(t.contains("FocusRing(active: dictating || focused"), "the composer ring animates")
        XCTAssertTrue(t.contains("if last && store.transcript.thinking { ThinkingDots()"), "the thinking dots stay, mounted only while thinking")
        XCTAssertEqual(t.components(separatedBy: ".transition(.arrivalPop(reduceMotion))").count - 1, 3, "skill and proposal cards and the Consulting Opus chip pop in")
    }

    func testKeyboardPaths() throws {
        let v = try code("Views.swift"), t = try code("ThreePOViews.swift")
        XCTAssertTrue(v.contains(#"PeakButton(title: "Collapse", color: .white, shortcut: .cancelAction"#), "Esc collapses")
        XCTAssertTrue(v.contains(".keyboardShortcut(shortcut)"))
        XCTAssertTrue(t.contains(#".keyboardShortcut("k", modifiers: .command)"#) && t.contains("focused = true"), "⌘K focuses the composer")
        XCTAssertTrue(t.contains(".onSubmit { Task { await store.send() } }"), "Return sends")
    }

    /// Every control Peek draws for a tap is at least 28 pt in both directions.
    func testTapTargetsAtLeast28() throws {
        let v = try code("Views.swift")
        let button = try body(v, from: "struct PeakButton", to: "\n}\n")
        XCTAssertTrue(button.contains("minHeight: PeakMotion.minTapTarget"), "PeakButton")
        let tabs = try body(v, from: "struct TabPills", to: "\n}\n")
        XCTAssertTrue(tabs.contains("minHeight: PeakMotion.minTapTarget"), "Peek | 3PO pills")
        let pills = try body(try code("ThreePOViews.swift"), from: "struct ModelPills", to: "\n}\n")
        XCTAssertTrue(pills.contains("minHeight: PeakMotion.minTapTarget"), "model pills")
        let panes = try body(try code("ThreePOMemoryViews.swift"), from: "struct PanePills", to: "\n}\n")
        XCTAssertTrue(panes.contains("minHeight: PeakMotion.minTapTarget"), "Chat / Memory pills")
        for (n, b) in [("tabs", tabs), ("model pills", pills), ("panes", panes)] {
            XCTAssertTrue(b.contains(".lineLimit(1).fixedSize()"), "\(n): a 28 pt target must not let its label wrap")
        }
        for (i, l) in v.components(separatedBy: "\n").enumerated() where l.contains(".padding(.vertical, 3)") || l.contains(".padding(.vertical, 5)") {
            XCTAssertFalse(l.contains("Button"), "Views.swift:\(i + 1): a short button")
        }
    }

    /// Brand: no opacity fade on text. No view transition or content transition in the panel views may use .opacity
    /// (the one exception is the pill's glass fill, a shape with no text).
    func testNoOpacityFadeOnText() throws {
        for (name, text) in appSourceFiles() {         // every app view file, voice included
            let lines = codeLines(text)
            for (i, l) in lines.enumerated() where (l.contains(".transition(") || l.contains("contentTransition(") || l.contains("AnyTransition"))
                && l.range(of: #"[ (:]\.opacity\b"#, options: .regularExpression) != nil {
                let ctx = lines[max(0, i - 3)...i].joined(separator: " ")
                XCTAssertTrue(ctx.contains("glassEffect"), "\(name):\(i + 1): an opacity transition fades text; rise / sharpen at full opacity instead")
            }
        }
    }

    /// No dimmed or gray text anywhere: every text colour is a brand colour at full opacity, no system grays, no
    /// muted hierarchical styles, no opacity on a Text.
    func testNoDimmedOrGrayTextAnywhere() throws {
        let banned = [#"\.opacity\("#, #"\bgray\b"#, #"\.secondary\b"#, #"\.tertiary\b"#, #"\.quaternary\b"#, #"Color\(white:"#, #"Color\(red:"#, #"\.placeholder\b"#]
        for (name, text) in appSourceFiles() {
            for (i, l) in codeLines(text).enumerated() {
                for r in l.components(separatedBy: "foregroundStyle(").dropFirst() {
                    let arg = String(r.prefix { $0 != "\n" })
                    for b in banned where arg.range(of: b, options: .regularExpression) != nil {
                        XCTFail("\(name):\(i + 1): text colour \(b) dims or grays text; pure white, green or gold at full opacity")
                    }
                }
                if l.contains("Text(") && l.contains(".opacity(") { XCTFail("\(name):\(i + 1): opacity on a Text line") }
                XCTAssertNil(l.range(of: #"(Color\.gray|\.gray\b|NSColor\.(secondary|tertiary|disabled)|secondaryLabel)"#, options: .regularExpression),
                             "\(name):\(i + 1): gray in a panel view")
            }
        }
    }

    /// Voice: 'Listening…' and pending words are pure white at full opacity; pending is cued by a gold caret only,
    /// and the mic button never half-fades.
    func testVoiceTextIsFullWhite() throws {
        let core = codeLines(try String(contentsOf: appSources.deletingLastPathComponent().appendingPathComponent("PeakCore/Voice.swift"), encoding: .utf8)).joined(separator: "\n")
        XCTAssertFalse(core.contains("pendingOpacity"), "no pending opacity token: pending words are not dimmed")
        let v = try code("Voice.swift")
        let live = try body(v, from: "struct LiveWordsText", to: "\n}\n")
        XCTAssertTrue(live.contains("Text(s.text).foregroundStyle(Color.white)"), "every live word is pure white")
        XCTAssertTrue(live.contains("VoiceLine.pendingCaret).foregroundStyle(Color.peakGold)"), "pending is a gold caret")
        XCTAssertFalse(live.contains("opacity"))
        let mic = try body(v, from: "struct MicButton", to: "\n}\n")
        let fades = codeLines(mic).filter { $0.contains(".opacity(") }
        XCTAssertEqual(fades.count, 1, "only the listening pulse ring (a shape) fades: \(fades)")
        XCTAssertTrue(fades.allSatisfy { $0.contains("Circle().stroke") || $0.contains("phaseAnimator") }, "the mic glyph is never half-faded")
        let strip = try body(v, from: "struct VoiceCaptionInline", to: "\n}\n")
        XCTAssertFalse(strip.contains("opacity"))
        let t = try code("ThreePOViews.swift")
        XCTAssertTrue(t.contains(#"Text("Listening…").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white)"#), "'Listening…' is pure white")
    }

    /// Number rolls (spend total, voice status line) never fade digits: SwapText rolls at full opacity; numericText
    /// (which cross-fades the changing digits) and every other non-identity content transition are banned.
    func testNumberRollNeverFadesDigits() throws {
        for (name, text) in appSourceFiles() {
            for (i, l) in codeLines(text).enumerated() where l.contains("contentTransition(") {
                XCTAssertTrue(l.contains("contentTransition(.identity)"), "\(name):\(i + 1): a content transition fades text; use SwapText (full-opacity roll)")
            }
        }
        let d = try code("DropViews.swift")
        let swap = try body(d, from: "struct SwapText", to: "\n}\n")
        XCTAssertFalse(swap.contains("opacity"), "SwapText rolls at full opacity")
        XCTAssertTrue(swap.contains("removal: .identity") && swap.contains("reduceMotion ? .identity"), "old value leaves at once; Reduce Motion swaps in place")
        let blur = try body(d, from: "struct BlurUp", to: "\n}\n")
        XCTAssertFalse(blur.contains("opacity"))
        let t = try code("ThreePOViews.swift")
        XCTAssertTrue(t.contains(#"SwapText(text: "\(usd(l.totalUSD)) / \(usd(l.budgetUSD))""#), "spend total rolls via SwapText")
        XCTAssertTrue(t.contains("SwapText(text: l, font: .system(size: 11, weight: .semibold)"), "voice status line rolls via SwapText")
    }

    /// The tour is demo-only and taps nothing that runs.
    func testPolishTourRunsNothing() throws {
        let a = try code("AppDelegate.swift")
        let tour = try body(a, from: "func motionPolishTour()", to: "var avatarTour")
        for bad in ["choose(.run)", ".run(", ".confirm(", "perform("] { XCTAssertFalse(tour.contains(bad), "polish tour calls \(bad)") }
        XCTAssertTrue(a.contains(#"var polishTour: Bool { demo && "#))
    }
}


// Hover growth (Christopher, Nov 17, 2026): the collapsed notch grows 25% while the pointer is
// inside it — a middle state, not the sheet. Policy, token, and the grown-rect geometry.
final class HoverGrowTests: XCTestCase {
    func testGrowAppliesOnlyToTheCollapsedNotchUnderThePointer() {
        XCTAssertTrue(HoverGrow.applies(mode: .notch, hovering: true, expanded: false))
        XCTAssertFalse(HoverGrow.applies(mode: .pill, hovering: true, expanded: false), "the pill keeps its 1.02 lift")
        XCTAssertFalse(HoverGrow.applies(mode: .notch, hovering: true, expanded: true), "never over the sheet")
        XCTAssertFalse(HoverGrow.applies(mode: .notch, hovering: false, expanded: false))
    }

    func testGrowScaleIsHisTwentyFivePercent() {
        XCTAssertEqual(PeakMotion.hoverGrowScale, 1.25)
    }

    func testGrownRectKeepsTheTopEdgeAndCenter() {
        let m5 = ScreenDescriptor(uuid: "M5", name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 2048, height: 1330),
                                  safeAreaTop: 43, auxiliaryTopLeft: CGRect(x: 0, y: 1287, width: 899, height: 43),
                                  auxiliaryTopRight: CGRect(x: 1149, y: 1287, width: 899, height: 43))
        let l = PeakGeometry().layout(for: m5)
        let g = l.grown(l.collapsed, by: PeakMotion.hoverGrowScale)
        XCTAssertEqual(g.maxY, l.collapsed.maxY, "the grown assembly stays flush with the top edge")
        XCTAssertEqual(g.midX, l.collapsed.midX, accuracy: 0.5, "growth is anchored on the assembly's center")
        XCTAssertEqual(g.width, l.collapsed.width * 1.25, accuracy: 0.5)
        XCTAssertEqual(g.height, l.collapsed.height * 1.25, accuracy: 0.5)
        XCTAssertTrue(l.canvas.contains(g), "the canvas has room for the grown assembly: it never clips")
        let gm = l.grown(l.markRect, by: PeakMotion.hoverGrowScale)
        XCTAssertEqual(gm.width, l.markRect.width * 1.25, accuracy: 0.5, "the mark grows with the assembly")
    }
}

import Foundation
import XCTest
@testable import PeakCore

/// The always-on menu-bar badge: "PEEK" in brand green on black; gold while presenting; brand tokens only.
final class StatusBadgeTests: XCTestCase {
    func testTheBadgeIsPeakInBrandGreenOnBlack() {
        let s = StatusBadge.spec(presenting: false)
        XCTAssertEqual(s.text, "PEEK"); XCTAssertEqual(s.textHex, Brand.greenHex); XCTAssertEqual(s.backgroundHex, Brand.blackHex)
        XCTAssertEqual(Brand.greenHex, 0x4FFF4F)
        XCTAssertEqual(s.accessibilityLabel, "ForceIQ Peek")
    }

    func testPresentingTurnsItGoldAndSaysSo() {
        let s = StatusBadge.spec(presenting: true)
        XCTAssertEqual(s.text, "PEEK · PRESENTING"); XCTAssertEqual(s.textHex, Brand.goldHex); XCTAssertEqual(s.backgroundHex, Brand.blackHex)
        XCTAssertTrue(s.accessibilityLabel.contains("presenting"))
    }

    func testOnlyBrandColorsAndEveryTextColorIsAllowed() {
        for p in [false, true] {
            let s = StatusBadge.spec(presenting: p)
            XCTAssertTrue(Brand.allowedTextHex.contains(s.textHex)); XCTAssertTrue(Brand.allowedTextHex.contains(s.backgroundHex))
            XCTAssertNotEqual(s.textHex, s.backgroundHex)
        }
    }

    // ── the status wing: the text zone of the band assembly, right of the mark ──
    let m5 = ScreenDescriptor(uuid: "M5", name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 2048, height: 1330),
                              safeAreaTop: 43, auxiliaryTopLeft: CGRect(x: 0, y: 1287, width: 899, height: 43),
                              auxiliaryTopRight: CGRect(x: 1149, y: 1287, width: 899, height: 43))

    func testTheCollapsedNotchHasNoTextWing() {
        // Christopher's rule (Nov 17, 2026): the collapsed notch shows the silhouette, the
        // centered ghost, and the dots — NO text. The wing is always .zero; the panel is
        // exactly the notch's width with the ghost at its center.
        let l = PeakGeometry().layout(for: m5)
        let n = l.notchRect!
        XCTAssertEqual(l.wing, .zero, "no text zone exists in the collapsed layout")
        XCTAssertEqual(l.collapsed.width, n.width, "the panel is the notch's width")
        XCTAssertEqual(l.collapsed.minX, n.minX)
        XCTAssertEqual(l.markRect.midX, n.midX, accuracy: 0.5, "the ghost is centered on the notch")
        XCTAssertTrue(l.collapsed.contains(l.markRect), "the ghost lives inside the silhouette")
        XCTAssertTrue(l.canvas.contains(l.collapsed))
        XCTAssertEqual(l.hitRect(.collapsed), l.collapsed)
    }

    func testTheWingFitsTheEmptyGapAndTheLongestWord() {
        let g = PeakGeometry()
        XCTAssertLessThanOrEqual(g.wingWidth, 104, "the wing stays small enough to leave the app menus alone")
        let longest = max(StatusBadge.spec(presenting: false).wingText.count, StatusBadge.spec(presenting: true).wingText.count)
        XCTAssertGreaterThanOrEqual(g.wingWidth, CGFloat(longest) * 8 + 16, "11 pt heavy caps with tracking, plus padding")
    }

    func testTheWingTextIsShortAndTheProgressLineHangsUnderTheWholeShape() {
        XCTAssertEqual(StatusBadge.spec(presenting: false).wingText, "PEEK"); XCTAssertEqual(StatusBadge.spec(presenting: true).wingText, "PRESENTING")
        let l = PeakGeometry().layout(for: m5)
        XCTAssertLessThan(l.progressLine.maxY, l.collapsed.minY)
        XCTAssertGreaterThanOrEqual(l.progressLine.minX, l.collapsed.minX); XCTAssertLessThanOrEqual(l.progressLine.maxX, l.collapsed.maxX)
    }

    func testTheStudioDisplayVirtualNotchHasNoTextWing() {
        let studio = ScreenDescriptor(uuid: "S", name: "Studio Display", frame: CGRect(x: 2048, y: 0, width: 2560, height: 1440),
                                      safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        let l = PeakGeometry().layout(for: studio)
        XCTAssertTrue(l.virtualNotch)
        XCTAssertEqual(l.wing, .zero); XCTAssertEqual(l.collapsed.size, CGSize(width: 88, height: 24), "band-height silhouette at the mock menu-bar height of 24: ghost + dots + small margins")
    }

    func testTheCollapsedNotchDrawsNoTextView() throws {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/StatusBadgeTests.swift", with: "Sources/ForceIQPeak/Views.swift")
        let v = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(v.contains("struct NotchWing"), "the in-notch text wing is gone: the collapsed notch shows no text")
        let collapsed = v.components(separatedBy: "@ViewBuilder var collapsed").last?.components(separatedBy: "var collapsedPill").first ?? ""
        XCTAssertFalse(collapsed.contains("Text("), "the collapsed notch view renders no text at all — silhouette, ghost, dots only")
        XCTAssertFalse(v.contains("struct NotchTag"), "the under-notch tab is gone")
    }

    func testTheAppDrawsItFromTheSpecAndNeverSetsAPlainTitle() throws {
        let base = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/StatusBadgeTests.swift", with: "Sources/ForceIQPeak/")
        let app = try String(contentsOfFile: base + "AppDelegate.swift", encoding: .utf8)
        XCTAssertTrue(app.contains("StatusBadge.spec(presenting: controller.presenting)"))
        XCTAssertFalse(app.contains("button?.title = "), "the status item is the badge image, not a plain 'Peek' title")
        let draw = try String(contentsOfFile: base + "StatusBadge.swift", encoding: .utf8)
        XCTAssertTrue(draw.contains("isTemplate = false"), "a template image would be tinted by the menu bar and lose the green")
        XCTAssertFalse(draw.contains("0x") || draw.contains("NSColor.gray") || draw.contains("secondaryLabel"))
    }
}

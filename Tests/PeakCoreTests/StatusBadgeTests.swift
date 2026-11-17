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

    // ── the status wing: merged into the notch, in the menu bar row, exactly the notch's height ──
    let m5 = ScreenDescriptor(uuid: "M5", name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 2048, height: 1330),
                              safeAreaTop: 43, auxiliaryTopLeft: CGRect(x: 0, y: 1287, width: 899, height: 43),
                              auxiliaryTopRight: CGRect(x: 1149, y: 1287, width: 899, height: 43))

    func testTheWingIsFlushWithTheNotchAndExactlyAsTall() {
        // New design (in-notch): the wing is the status text right of the mark square, inside the
        // collapsed row that starts at the notch's left edge — no longer a wing off the left side.
        let l = PeakGeometry().layout(for: m5)
        let n = l.notchRect!
        XCTAssertEqual(l.wing.minX, l.markRect.maxX, "the text starts where the mark square ends")
        XCTAssertEqual(l.wing.minY, n.minY); XCTAssertEqual(l.wing.height, n.height); XCTAssertEqual(l.wing.maxY, 1330)
        XCTAssertEqual(l.collapsed.minX, n.minX, "the row starts at the notch's left edge")
        XCTAssertEqual(l.collapsed, l.markRect.union(l.wing), "one shape: mark square + status text")
        XCTAssertTrue(l.canvas.contains(l.collapsed))
        XCTAssertEqual(l.hitRect(.collapsed), l.collapsed, "hover and click on the wing open Peek")
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

    func testTheStudioDisplayVirtualNotchHasTheTextWing() {
        let studio = ScreenDescriptor(uuid: "S", name: "Studio Display", frame: CGRect(x: 2048, y: 0, width: 2560, height: 1440),
                                      safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        let l = PeakGeometry().layout(for: studio)
        XCTAssertTrue(l.virtualNotch)
        XCTAssertEqual(l.wing.width, PeakGeometry().textWingVirtual); XCTAssertEqual(l.collapsed.size, CGSize(width: 230, height: 46))
    }

    func testTheWingViewIsBrandTextOnBlackAndNothingElseDrawsBesideTheNotch() throws {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/StatusBadgeTests.swift", with: "Sources/ForceIQPeak/Views.swift")
        let v = try String(contentsOfFile: path, encoding: .utf8)
        let wing = v.components(separatedBy: "struct NotchWing").last?.components(separatedBy: "/// Live progress under the notch").first ?? ""
        XCTAssertTrue(wing.contains("Color.peakGreen") && wing.contains("Color.peakGold") && wing.contains("spec.text"))
        XCTAssertFalse(wing.contains("opacity") || wing.contains("gray") || wing.contains(".secondary"))
        XCTAssertFalse(v.contains("struct NotchTag"), "the under-notch tab is gone: the wing replaced it")
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

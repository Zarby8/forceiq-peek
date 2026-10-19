import Foundation
import XCTest
@testable import PeakCore

/// The always-on menu-bar badge: "PEAK" in brand green on black; gold while presenting; brand tokens only.
final class StatusBadgeTests: XCTestCase {
    func testTheBadgeIsPeakInBrandGreenOnBlack() {
        let s = StatusBadge.spec(presenting: false)
        XCTAssertEqual(s.text, "PEAK"); XCTAssertEqual(s.textHex, Brand.greenHex); XCTAssertEqual(s.backgroundHex, Brand.blackHex)
        XCTAssertEqual(Brand.greenHex, 0x4FFF4F)
        XCTAssertEqual(s.accessibilityLabel, "ForceIQ Peak")
    }

    func testPresentingTurnsItGoldAndSaysSo() {
        let s = StatusBadge.spec(presenting: true)
        XCTAssertEqual(s.text, "PEAK · PRESENTING"); XCTAssertEqual(s.textHex, Brand.goldHex); XCTAssertEqual(s.backgroundHex, Brand.blackHex)
        XCTAssertTrue(s.accessibilityLabel.contains("presenting"))
    }

    func testOnlyBrandColorsAndEveryTextColorIsAllowed() {
        for p in [false, true] {
            let s = StatusBadge.spec(presenting: p)
            XCTAssertTrue(Brand.allowedTextHex.contains(s.textHex)); XCTAssertTrue(Brand.allowedTextHex.contains(s.backgroundHex))
            XCTAssertNotEqual(s.textHex, s.backgroundHex)
        }
    }

    // ── the tab under the notch (a crowded menu bar hides status items, so this is the always-visible one) ──
    let m5 = ScreenDescriptor(uuid: "M5", name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 2048, height: 1330),
                              safeAreaTop: 43, auxiliaryTopLeft: CGRect(x: 0, y: 1287, width: 899, height: 43),
                              auxiliaryTopRight: CGRect(x: 1149, y: 1287, width: 899, height: 43))

    func testTheTagHangsFromTheNotchBelowTheMenuBarAndLeavesTheNotchAlone() {
        let l = PeakGeometry().layout(for: m5)
        let n = l.notchRect!
        XCTAssertEqual(l.collapsed, n, "collapsed is still exactly the notch")
        XCTAssertEqual(l.tag.maxY, n.minY, accuracy: 0.5, "flush under the notch, never beside it in the menu bar row")
        XCTAssertEqual(l.tag.midX, n.midX, accuracy: 0.5)
        XCTAssertTrue(l.canvas.contains(l.tag))
        XCTAssertLessThan(l.progressLine.maxY, l.tag.minY, "the progress line moved under the tag, not over it")
        XCTAssertEqual(l.hitRect(.collapsed), n, "the notch hit rect did not grow")
    }

    func testTheTagTakesThePointerOnlyWhileCollapsed() {
        let l = PeakGeometry().layout(for: m5)
        let onTag = CGPoint(x: l.tag.midX, y: l.tag.midY), onNotch = CGPoint(x: l.collapsed.midX, y: l.collapsed.midY)
        XCTAssertTrue(l.pointerHit(.collapsed, at: onTag)); XCTAssertTrue(l.pointerHit(.collapsed, at: onNotch))
        XCTAssertFalse(l.pointerHit(.collapsed, at: CGPoint(x: l.tag.minX - 30, y: l.tag.midY)), "beside the tag is the app underneath")
        XCTAssertFalse(l.pointerHit(.collapsed, at: CGPoint(x: l.tag.midX, y: l.tag.minY - 20)), "so is below it")
        XCTAssertFalse(l.pointerHit(.home, at: CGPoint(x: l.tag.midX, y: l.expanded.minY - 40)), "an open sheet has its own rect")
    }

    func testTheStudioDisplayPillHasNoTag() {
        let studio = ScreenDescriptor(uuid: "S", name: "Studio Display", frame: CGRect(x: 2048, y: 0, width: 2560, height: 1440),
                                      safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        let l = PeakGeometry().layout(for: studio)
        XCTAssertEqual(l.tag, .zero)
        XCTAssertFalse(l.pointerHit(.collapsed, at: CGPoint(x: l.collapsed.midX, y: l.collapsed.minY - 30)), "nothing hangs below the pill")
    }

    func testTheTagViewIsBrandTextOnBlackAndTapsOpenPeak() throws {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/StatusBadgeTests.swift", with: "Sources/ForceIQPeak/Views.swift")
        let v = try String(contentsOfFile: path, encoding: .utf8)
        let tag = v.components(separatedBy: "struct NotchTag").last?.components(separatedBy: "/// Live progress under the notch").first ?? ""
        XCTAssertTrue(tag.contains("Color.peakGreen") && tag.contains("Color.peakGold") && tag.contains("Color.black"))
        XCTAssertFalse(tag.contains("opacity") || tag.contains("gray") || tag.contains(".secondary"))
        XCTAssertTrue(v.contains("if tagShowing {") && v.contains("var tagShowing: Bool { panel.mode == .notch && panel.visible && !isExpanded && !peekShowing }"))
    }

    func testTheAppDrawsItFromTheSpecAndNeverSetsAPlainTitle() throws {
        let base = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/StatusBadgeTests.swift", with: "Sources/ForceIQPeak/")
        let app = try String(contentsOfFile: base + "AppDelegate.swift", encoding: .utf8)
        XCTAssertTrue(app.contains("StatusBadge.spec(presenting: controller.presenting)"))
        XCTAssertFalse(app.contains("button?.title = "), "the status item is the badge image, not a plain 'Peak' title")
        let draw = try String(contentsOfFile: base + "StatusBadge.swift", encoding: .utf8)
        XCTAssertTrue(draw.contains("isTemplate = false"), "a template image would be tinted by the menu bar and lose the green")
        XCTAssertFalse(draw.contains("0x") || draw.contains("NSColor.gray") || draw.contains("secondaryLabel"))
    }
}

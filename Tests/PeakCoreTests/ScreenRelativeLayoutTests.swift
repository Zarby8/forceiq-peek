import Foundation
import XCTest
@testable import PeakCore

// The collapsed layout is ONE screen-relative rule (Christopher, Nov 17, 2026: "it has to be
// screen aware and size to the screen") — every number below is derived from the screen's own
// descriptor (frame, safe-area top, auxiliary areas, menu-bar height); nothing is a per-model
// constant. These synthetic screens pin the invariants on sizes and bands the live machines
// don't happen to have: ghost center == the screen's horizontal center, footprint == the
// screen's notch (or its band, for a virtual notch), ghost + dots on one vertical line in the
// band wherever the band has pixels to draw on.
final class ScreenRelativeLayoutTests: XCTestCase {

    /// A notched screen that is NOT the M5: 1600x1000, a 200x36 notch, a 40 pt menu bar,
    /// sitting at the global origin. If any 250 / 43 / 31 leaked in as a constant, this fails.
    func testHardwareNotchDerivesEverythingFromTheDescriptor() {
        let s = ScreenDescriptor(uuid: "H", name: "Notch 200", frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                 safeAreaTop: 36,
                                 auxiliaryTopLeft: CGRect(x: 0, y: 964, width: 700, height: 36),
                                 auxiliaryTopRight: CGRect(x: 900, y: 964, width: 700, height: 36),
                                 menuBarHeight: 40)
        let l = PeakGeometry().layout(for: s)
        XCTAssertEqual(l.collapsed.width, 200, accuracy: 0.5, "footprint == THIS screen's notch width")
        XCTAssertEqual(l.collapsed.minX, 700, accuracy: 0.5, "the silhouette starts where the notch starts")
        XCTAssertEqual(l.markRect.midX, 800, accuracy: 0.5)
        XCTAssertEqual(l.markRect.midX, s.frame.midX, accuracy: 0.5, "ghost center == screen center")
        XCTAssertEqual(l.markRect.width, 32, accuracy: 0.5, "the mark is sized to this notch's height (36 - 4)")
        XCTAssertEqual(l.markRect.maxY, (l.notchRect?.minY ?? 0) - 1, accuracy: 0.5,
                       "the chin: the centered ghost hangs 1 pt below the housing — the only pixels at the screen's center x")
        XCTAssertEqual(l.dotsRect.maxX, 700, accuracy: 0.5, "dots in the left ear, immediately left of the notch")
        XCTAssertEqual(l.dotsRect.height, 40, accuracy: 0.5, "the ear is as tall as this screen's menu bar")
    }

    /// The same notched geometry on a screen at a non-zero origin (a built-in right of two
    /// externals): screen-relative means the origin cancels out.
    func testHardwareNotchAtAnOffsetOrigin() {
        let s = ScreenDescriptor(uuid: "H2", name: "Notch offset", frame: CGRect(x: 2880, y: 0, width: 2048, height: 1330),
                                 safeAreaTop: 43,
                                 auxiliaryTopLeft: CGRect(x: 2880, y: 1287, width: 899, height: 43),
                                 auxiliaryTopRight: CGRect(x: 4029, y: 1287, width: 899, height: 43),
                                 menuBarHeight: 45)
        let l = PeakGeometry().layout(for: s)
        XCTAssertEqual(l.markRect.midX, s.frame.midX, accuracy: 0.5, "ghost center == THIS screen's center (3904)")
        XCTAssertEqual(l.collapsed.minX, 3779, accuracy: 0.5)
        XCTAssertEqual(l.collapsed.width, 250, accuracy: 0.5)
    }

    /// A notch-less screen LEFT of the main display (negative origin), 1080p, a 30 pt band:
    /// the virtual notch centers the ghost on the screen and on the band, dots on the same line.
    func testVirtualNotchCentersGhostAndDotsInTheBand() {
        let s = ScreenDescriptor(uuid: "V", name: "1080p", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                 safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, menuBarHeight: 30)
        let l = PeakGeometry().layout(for: s)
        XCTAssertTrue(l.virtualNotch)
        XCTAssertEqual(l.collapsed.height, 30, accuracy: 0.5, "the silhouette is contained in this screen's band")
        XCTAssertEqual(l.collapsed.midX, s.frame.midX, accuracy: 0.5)
        XCTAssertEqual(l.markRect.midX, s.frame.midX, accuracy: 0.5, "ghost center == screen center")
        XCTAssertEqual(l.markRect.midY, s.frame.maxY - 15, accuracy: 0.5, "ghost vertically centered in the band")
        XCTAssertEqual(l.dotsRect.midY, l.markRect.midY, accuracy: 0.5, "dots share the ghost's vertical center line")
        XCTAssertEqual(l.dotsRect.minX, l.collapsed.minX, accuracy: 0.5, "dots at the silhouette's left end")
    }

    /// A 4K notch-less screen with a tall 44 pt band: the mark scales with the band (44 - 4),
    /// and the same centering invariants hold.
    func testVirtualNotchScalesWithATallerBand() {
        let s = ScreenDescriptor(uuid: "V4K", name: "4K", frame: CGRect(x: 1920, y: 0, width: 3840, height: 2160),
                                 safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, menuBarHeight: 44)
        let l = PeakGeometry().layout(for: s)
        XCTAssertEqual(l.markRect.width, 40, accuracy: 0.5, "mark side == band height - 4, from THIS screen's band")
        XCTAssertEqual(l.markRect.midX, s.frame.midX, accuracy: 0.5)
        XCTAssertEqual(l.markRect.midY, s.frame.maxY - 22, accuracy: 0.5, "centered in the 44 pt band")
        XCTAssertEqual(l.dotsRect.midY, l.markRect.midY, accuracy: 0.5)
        XCTAssertEqual(l.collapsed.height, 44, accuracy: 0.5)
    }

    // ── app-side wiring guards (source-level, like SwitchActivationTests) ──

    private func appSource(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/ScreenRelativeLayoutTests.swift",
                                                  with: "Sources/ForceIQPeak/" + name)
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// The centering regression (Nov 17, 2026): the collapsed notch's ZStack is placed by
    /// padding inside a fixed frame — that frame MUST pin top-leading, or SwiftUI centers the
    /// padded content and the ghost renders ~(silhouette - content)/2 right of markRect while
    /// every log line says centered. (Measured live before the fix: +53 pt on a 250 pt notch.)
    func testCollapsedNotchFramePinsTopLeading() throws {
        let views = try appSource("Views.swift")
        XCTAssertTrue(views.contains(".frame(width: panel.collapsedSize.width, height: panel.collapsedSize.height, alignment: .topLeading)"),
                      "the collapsed notch frame pins its padded content top-leading")
        XCTAssertTrue(views.contains("alignment: .leading)   // leading, not centered"),
                      "the collapsed pill pins leading too (its markRect is the pill's left edge)")
    }

    /// The launcher hitbox (Christopher, Nov 17, 2026): every app tile is a Button whose label
    /// is the whole tile — logo included — at one uniform height across the row.
    func testSwitcherTileIsAWholeTileButton() throws {
        let views = try appSource("Views.swift")
        let tile = views.components(separatedBy: "struct SwitcherTile").last?
            .components(separatedBy: "struct SettingsView").first ?? ""
        XCTAssertTrue(tile.contains("Button {"), "the tile is a button, not a tap gesture on part of it")
        XCTAssertTrue(tile.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(tile.contains("minHeight: 76"), "one uniform tile height: no dead band above/below short tiles")
        XCTAssertTrue(tile.contains(".contentShape(Rectangle())"), "the label's whole rect is the hit area, empty corners included")
        XCTAssertFalse(tile.contains(".onTapGesture"), "the partial-gesture hitbox is gone")
    }

    /// The session-jumper rows were checked for the same defect: they are already whole-row
    /// Buttons (label carries a Spacer, so it spans the row). Pin that they stay that way.
    func testSessionJumperRowsAreWholeRowButtons() throws {
        let rows = try appSource("AgentWatchViews.swift")
        XCTAssertTrue(rows.contains("Button { SessionJumper.jump(s) }"), "jump rows are buttons")
        XCTAssertTrue(rows.contains(".buttonStyle(.plain)"))
    }
}

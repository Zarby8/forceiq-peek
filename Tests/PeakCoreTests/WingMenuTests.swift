import Foundation
import XCTest
@testable import PeakCore

/// The menu-bar item is off by default; the status wing's right-click is the Peak menu (Show, Displays, Presenting,
/// Do not disturb, Settings, Quit), so nothing is left without a way to reach it.
final class WingMenuTests: XCTestCase {
    func testTheMenuBarItemIsOffByDefaultAndFailsClosedToOff() {
        let r = tmpRoot()
        XCTAssertFalse(PeakPrefs(stateRoot: r).menuBarItem, "no file: off")
        try! Data(#"{"menuBarItem": true}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        XCTAssertTrue(PeakPrefs(stateRoot: r).menuBarItem, "the escape hatch")
        try! Data(#"{"menuBarItem": null}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        XCTAssertFalse(PeakPrefs(stateRoot: r).menuBarItem)
        try! Data(#"{"menuBarItem": "yes"}"#.utf8).write(to: r.appendingPathComponent("settings.json"))
        let bad = PeakPrefs(stateRoot: r)
        XCTAssertFalse(bad.menuBarItem); XCTAssertTrue(bad.loadIssue?.contains("menuBarItem") ?? false)
        XCTAssertTrue(PeakPrefs.Doc.CodingKeys.allCases.map(\.stringValue).contains("menuBarItem"))
    }

    func testTheWingRightClickOpensTheSameMenuTheStatusItemHeld() throws {
        let base = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/WingMenuTests.swift", with: "Sources/ForceIQPeak/")
        let app = try String(contentsOfFile: base + "AppDelegate.swift", encoding: .utf8)
        XCTAssertTrue(app.contains("guard prefs.menuBarItem else"), "no status item unless asked")
        XCTAssertTrue(app.contains("override func rightMouseDown(with event: NSEvent)"))
        XCTAssertTrue(app.contains("NSMenu.popUpContextMenu(self.makeMenu(), with: e, for: v)"), "the one menu, built once, shown from the wing")
        let menu = app.components(separatedBy: "func makeMenu() -> NSMenu").last?.components(separatedBy: "func menuWillOpen").first ?? ""
        for needle in ["Show ForceIQ Peak", "Presenting.menuTitle", "Do not disturb", "Built-in hotkey", "Settings…", "Quit ForceIQ Peak"] {
            XCTAssertTrue(menu.contains(needle), "the menu still offers: \(needle)")
        }
    }
}

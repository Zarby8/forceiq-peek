import Foundation
import XCTest

/// Peek ships an app icon (the eyes mark): the .icns is in the repo, Info.plist names it, and build.sh copies it into the bundle.
/// The About panel is the standard one, which shows the app icon, so this is also what keeps the About art from being the
/// generic default.
final class AppIconTests: XCTestCase {
    var peekRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func testTheIconFileIsAValidIcnsOfRealSize() throws {
        let d = try Data(contentsOf: peekRoot.appendingPathComponent("Resources/AppIcon.icns"))
        XCTAssertEqual(String(decoding: d.prefix(4), as: UTF8.self), "icns")
        XCTAssertGreaterThan(d.count, 50_000, "a full iconset (16 to 1024 px), not a stub")
    }

    func testInfoPlistNamesTheIcon() throws {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: peekRoot.appendingPathComponent("Info.plist")))
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
    }

    func testTheBuildCopiesTheIconIntoTheBundle() throws {
        let sh = try String(contentsOf: peekRoot.appendingPathComponent("build.sh"), encoding: .utf8)
        XCTAssertTrue(sh.contains("Resources/AppIcon.icns") && sh.contains("Contents/Resources/AppIcon.icns"))
    }

    func testTheAboutPanelStaysTheStandardOneThatShowsTheAppIcon() throws {
        let src = try String(contentsOf: peekRoot.appendingPathComponent("Sources/ForceIQPeak/AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("orderFrontStandardAboutPanel"))
    }
}

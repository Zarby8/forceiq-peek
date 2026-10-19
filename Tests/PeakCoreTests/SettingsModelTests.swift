import Foundation
import XCTest
@testable import PeakCore

/// The Settings window's model: every control writes through to settings.json at once, the two launch-only switches say so,
/// and Do not disturb / presenting go through the same controller paths as the menu.
@MainActor final class SettingsModelTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }
    func make(_ root: URL = tmpRoot()) -> (SettingsModel, PeakController, URL, MemLog) {
        let log = MemLog()
        let c = PeakController(prefs: PeakPrefs(stateRoot: root), profile: fixtureProfile("profile-coach-a"), hotkey: FakeHotkey(), logger: log)
        return (SettingsModel(prefs: c.prefs, controller: c), c, root, log)
    }

    func testDefaultsMatchThePrefsAndNothingNeedsARestart() {
        let (m, _, _, _) = make()
        XCTAssertTrue(m.autoPresenting); XCTAssertFalse(m.nextSessionPill); XCTAssertFalse(m.menuBarItem)
        XCTAssertFalse(m.quietEnabled); XCTAssertFalse(m.presenting); XCTAssertNil(m.dndUntil); XCTAssertFalse(m.restartNeeded)
        XCTAssertEqual(m.quietStart, 22 * 60); XCTAssertEqual(m.quietEnd, 7 * 60)
    }

    func testEveryToggleWritesThroughToSettingsJSON() {
        let (m, _, root, _) = make()
        m.autoPresenting = false; m.nextSessionPill = true; m.menuBarItem = true
        let p = PeakPrefs(stateRoot: root)
        XCTAssertFalse(p.autoPresenting); XCTAssertTrue(p.nextSessionPill); XCTAssertTrue(p.menuBarItem)
    }

    func testOnlyTheLaunchReadSwitchesAskForARestart() {
        let (m, _, _, _) = make()
        m.autoPresenting = false; XCTAssertFalse(m.restartNeeded, "auto-presenting applies at once")
        m.nextSessionPill = true; XCTAssertTrue(m.restartNeeded)
        let (n, _, _, _) = make()
        n.menuBarItem = true; XCTAssertTrue(n.restartNeeded)
    }

    func testQuietHoursWriteBothEndsAndClearTogether() {
        let (m, _, root, _) = make()
        m.quietEnabled = true
        XCTAssertEqual(PeakPrefs(stateRoot: root).quietHours, QuietHours(startMinute: 22 * 60, endMinute: 7 * 60))
        m.quietStart = 21 * 60 + 30; m.quietEnd = 6 * 60 + 15
        XCTAssertEqual(PeakPrefs(stateRoot: root).quietHours, QuietHours(startMinute: 21 * 60 + 30, endMinute: 6 * 60 + 15))
        let text = try! String(contentsOf: root.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"21:30\"") && text.contains("\"06:15\""), "HH:mm, zero padded")
        m.quietEnabled = false
        XCTAssertNil(PeakPrefs(stateRoot: root).quietHours)
        let off = try! String(contentsOf: root.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertFalse(off.contains("quietHours"))
    }

    func testAnExistingQuietWindowLoadsIntoTheControls() {
        let root = tmpRoot()
        try! Data(#"{"quietHoursStart":"20:00","quietHoursEnd":"06:30"}"#.utf8).write(to: root.appendingPathComponent("settings.json"))
        let (m, _, _, _) = make(root)
        XCTAssertTrue(m.quietEnabled); XCTAssertEqual(m.quietStart, 20 * 60); XCTAssertEqual(m.quietEnd, 6 * 60 + 30)
    }

    func testDoNotDisturbGoesThroughTheControllerAndTheLineSaysWhen() {
        let (m, c, root, log) = make()
        let now = Date(timeIntervalSince1970: 1_792_418_400)
        c.showPeek(PeakAlert(id: "x", kind: .meetingSoon, client: "Sample Skater", line: "Sample Skater in 9 min", holdSeconds: 5), on: "D1")
        m.setDoNotDisturb(.oneHour, now: now)
        XCTAssertNil(c.peek, "turning it on clears a peek that is showing")
        XCTAssertEqual(PeakPrefs(stateRoot: root).dndUntil?.timeIntervalSince1970 ?? 0, now.addingTimeInterval(3600).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(m.dndLine(now: now).hasPrefix("until "))
        XCTAssertEqual(m.dndLine(now: now.addingTimeInterval(7200)), "off", "once it has passed it reads off")
        m.setDoNotDisturb(.off, now: now)
        XCTAssertNil(PeakPrefs(stateRoot: root).dndUntil); XCTAssertEqual(m.dndLine(now: now), "off")
        XCTAssertTrue(log.lines.contains("state dnd=on")); XCTAssertTrue(log.lines.contains("state dnd=off"))
    }

    func testPresentingFollowsTheControllerBothWays() async {
        let (m, c, _, _) = make()
        m.setPresenting(true)
        XCTAssertTrue(c.presenting)
        c.setPresenting(false)
        m.refresh()
        XCTAssertFalse(m.presenting)
    }

    func testTurningAutoPresentingOffEndsAnAutomaticPresentation() {
        let (m, c, _, _) = make()
        c.setCommandLive(true); XCTAssertTrue(c.presenting)
        m.autoPresenting = false
        XCTAssertFalse(c.presenting, "the setting applies to the meeting that is running")
        m.autoPresenting = true
        XCTAssertTrue(c.presenting, "and back on, while Command is still live")
    }

    func testTimeConversionRoundTrips() {
        for mins in [0, 59, 60, 7 * 60, 22 * 60 + 30, 23 * 60 + 59] {
            XCTAssertEqual(SettingsModel.minutes(of: SettingsModel.date(minutes: mins, calendar: cal), calendar: cal), mins)
        }
    }

    func testTheWindowOffersEveryControlInWhiteAndBrandColors() throws {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/SettingsModelTests.swift", with: "Sources/ForceIQPeak/Views.swift")
        let v = try String(contentsOfFile: path, encoding: .utf8)
        let s = v.components(separatedBy: "struct SettingsView").last?.components(separatedBy: "/// App icons for the switcher").first ?? ""
        for needle in ["model.autoPresenting", "model.nextSessionPill", "model.menuBarItem", "model.quietEnabled", "setDoNotDisturb(.oneHour)",
                       "setDoNotDisturb(.tomorrowMorning)", "setDoNotDisturb(.off)", "model.setPresenting", "HotkeyRecorder()", "setVoice"] {
            XCTAssertTrue(s.contains(needle), "Settings still offers \(needle)")
        }
        XCTAssertFalse(s.contains("opacity") || s.contains("gray") || s.contains(".secondary"))
    }
}

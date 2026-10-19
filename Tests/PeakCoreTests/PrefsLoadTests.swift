import Foundation
import XCTest
@testable import PeakCore

// settings.json loading: lenient (every key optional, present keys kept), loud (a file that exists but can't be used is
// logged by path + key / parse position and shown as a plain-white row) and closed (desktopActions, commandMeetingLink and
// voice stay off on any failure). No file is normal and silent.
@MainActor final class PrefsLoadTests: XCTestCase {
    let a = "37D8832A-2D66-02CA-B9F7-8F30A301B230"

    func root(_ body: String?) -> URL {
        let r = tmpRoot()
        if let body { try! Data(body.utf8).write(to: r.appendingPathComponent("settings.json")) }
        return r
    }
    func assertAllDefaults(_ p: PeakPrefs, voiceOff: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(p.hiddenDisplays.isEmpty, file: file, line: line)
        XCTAssertFalse(p.globallyHidden, file: file, line: line)
        XCTAssertTrue(p.builtInHotkeyEnabled(default: true), file: file, line: line)
        XCTAssertFalse(p.builtInHotkeyEnabled(default: false), file: file, line: line)
        XCTAssertEqual(p.ghostFormat, .h264Black, file: file, line: line)
        XCTAssertFalse(p.desktopActions, file: file, line: line)
        XCTAssertFalse(p.commandMeetingLink, file: file, line: line)
        XCTAssertEqual(p.voiceEnabled, voiceOff ? false : nil, file: file, line: line)
    }
    func assertLoud(_ p: PeakPrefs, mentions: String, file: StaticString = #filePath, line: UInt = #line) {
        let issue = p.loadIssue ?? ""
        XCTAssertTrue(issue.contains(mentions), "loadIssue '\(issue)' should mention \(mentions)", file: file, line: line)
        let log = MemLog(); p.reportLoad(to: log)
        XCTAssertEqual(log.lines.count, 1, file: file, line: line)
        let l = log.lines.first ?? ""
        XCTAssertTrue(l.hasPrefix("settings unreadable path=\(p.url.path) "), l, file: file, line: line)
        XCTAssertTrue(l.contains(mentions), l, file: file, line: line)
        XCTAssertEqual(p.settingsNotice, "Settings file couldn't be read: using defaults", file: file, line: line)
        XCTAssertEqual(p.settingsNotice, PeakPrefs.unreadableNotice, file: file, line: line)
    }

    func testMissingKeysGetDefaultsWhilePresentKeysAreKept() {
        let p = PeakPrefs(stateRoot: root(#"{"commandMeetingLink": true}"#))
        XCTAssertTrue(p.commandMeetingLink, "a partial file keeps the keys it has (the old decoder read this as off)")
        XCTAssertNil(p.loadIssue); XCTAssertNil(p.settingsNotice); XCTAssertNil(p.loadLogLine)
        XCTAssertFalse(p.desktopActions); XCTAssertFalse(p.globallyHidden); XCTAssertTrue(p.hiddenDisplays.isEmpty)
        XCTAssertNil(p.voiceEnabled); XCTAssertEqual(p.ghostFormat, .h264Black); XCTAssertTrue(p.builtInHotkeyEnabled(default: true))

        let q = PeakPrefs(stateRoot: root(#"{"hiddenDisplays": ["\#(a)"], "voiceEnabled": true, "ghostFormat": "hevc-alpha", "hotkeyEnabled": false}"#))
        XCTAssertNil(q.loadIssue)
        XCTAssertFalse(q.isDisplayShown(a)); XCTAssertEqual(q.voiceEnabled, true); XCTAssertEqual(q.ghostFormat, .hevcAlpha)
        XCTAssertFalse(q.builtInHotkeyEnabled(default: true)); XCTAssertFalse(q.globallyHidden); XCTAssertFalse(q.commandMeetingLink)
        XCTAssertFalse(q.desktopActions)
    }

    func testEmptyObjectAndNullValuesGetDefaults() {
        assertAllDefaults(PeakPrefs(stateRoot: root("{}")), voiceOff: false)
        let p = PeakPrefs(stateRoot: root(#"{"desktopActions": null, "globallyHidden": null, "hiddenDisplays": null, "commandMeetingLink": true, "someFutureKey": 7}"#))
        XCTAssertNil(p.loadIssue, "null = missing; unknown keys are ignored")
        XCTAssertFalse(p.desktopActions); XCTAssertFalse(p.globallyHidden); XCTAssertTrue(p.hiddenDisplays.isEmpty); XCTAssertTrue(p.commandMeetingLink)
    }

    func testFullFileRoundTripsAndMissingKeysAreFilledOnSave() throws {
        let r = root(#"{"commandMeetingLink": true}"#)
        PeakPrefs(stateRoot: r).setDisplay(a, shown: false)
        let p = PeakPrefs(stateRoot: r)
        XCTAssertNil(p.loadIssue); XCTAssertTrue(p.commandMeetingLink); XCTAssertFalse(p.isDisplayShown(a)); XCTAssertFalse(p.desktopActions)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.appendingPathComponent(PeakPrefs.unreadableBackupName).path))
    }

    func testMalformedJSONGivesAllDefaultsLoggedErrorAndVisibleState() {
        let p = PeakPrefs(stateRoot: root(#"{"commandMeetingLink": true, "desktopActions": true, "hiddenDisplays": ["\#(a)"],"#))
        assertAllDefaults(p, voiceOff: true)
        assertLoud(p, mentions: "not valid JSON")
        XCTAssertTrue(p.isDisplayShown(a))
    }

    func testWrongTypedKeyIsLoggedByName() {
        let p = PeakPrefs(stateRoot: root(#"{"desktopActions": "yes", "commandMeetingLink": true}"#))
        assertAllDefaults(p, voiceOff: true)
        assertLoud(p, mentions: "key 'desktopActions' has the wrong type (expected true/false)")
        XCTAssertFalse(p.loadLogLine!.contains("yes"), "the log names the key, never its value")

        let q = PeakPrefs(stateRoot: root(#"{"hiddenDisplays": ["\#(a)", 3], "commandMeetingLink": true}"#))
        assertAllDefaults(q, voiceOff: true)
        assertLoud(q, mentions: "key 'hiddenDisplays[1]' has the wrong type")
    }

    func testLogNeverIncludesValues() {
        let secret = "fake-value-DO-NOT-LOG"
        for body in [#"{"ghostFormat": 5, "x": "\#(secret)"}"#, #"{"hiddenDisplays": "\#(secret)"}"#, #"{"voiceEnabled": "\#(secret)"}"#,
                     #"{"desktopActions": true, "\#(secret)"#, "\(secret)"] {
            let p = PeakPrefs(stateRoot: root(body))
            XCTAssertNotNil(p.loadIssue, body)
            XCTAssertFalse(p.loadLogLine!.contains("DO-NOT-LOG"), p.loadLogLine!)
        }
    }

    func testDesktopActionsStaysFalseOnAnyFailure() {
        var voiceProfile = fixtureProfile("profile-coach-a"); voiceProfile.modules["voice"] = true
        for body in [#"{"desktopActions": true,"#,                                   // malformed
                     #"{"desktopActions": true, "commandMeetingLink": true, "voiceEnabled": true, "globallyHidden": "no"}"#,  // other key wrong type
                     #"{"desktopActions": 1, "commandMeetingLink": true, "voiceEnabled": true}"#,  // the flag itself wrong type
                     #"[{"desktopActions": true}]"#, "true", "null", "", "  \n", "\u{FEFF}{\"desktopActions\": true"] {
            let r = root(body)
            let p = PeakPrefs(stateRoot: r)
            XCTAssertNotNil(p.loadIssue, "'\(body)' should fail loudly")
            XCTAssertNotNil(p.settingsNotice)
            XCTAssertFalse(p.desktopActions, "desktopActions on after '\(body)'")
            XCTAssertFalse(p.commandMeetingLink, "commandMeetingLink on after '\(body)'")
            XCTAssertEqual(p.voiceEnabled, false, "voice must fail closed after '\(body)'")
            XCTAssertFalse(VoiceGate.enabled(voiceProfile, setting: p.voiceEnabled), "voice on after '\(body)' even with modules.voice")
            let env = ["GOAT_PEAK_ROOT": r.path, DesktopActionGate.liveEnv: "1"]
            XCTAssertEqual(DesktopActionGate.mode(env: env, desktopActions: p.desktopActions, stateRoot: r.path), .off)
            XCTAssertFalse(CommandMeetingLinkGate.enabled(env: [:], setting: p.commandMeetingLink))
        }
        XCTAssertFalse(PeakPrefs(stateRoot: tmpRoot()).desktopActions, "no file: off")
        XCTAssertFalse(PeakPrefs(stateRoot: root("{}")).desktopActions, "missing key: off")
    }

    func testEmptyFileGivesDefaultsAndIsReported() {
        for body in ["", " \n\t"] {
            let p = PeakPrefs(stateRoot: root(body))
            assertAllDefaults(p, voiceOff: true)
            assertLoud(p, mentions: "the file is empty")
        }
    }

    func testTopLevelThatIsNotAnObjectIsReported() {
        let p = PeakPrefs(stateRoot: root(#"["desktopActions"]"#))
        assertAllDefaults(p, voiceOff: true)
        assertLoud(p, mentions: "the file isn't a JSON object")
    }

    func testNoFileGivesSilentDefaults() {
        let r = tmpRoot()
        let p = PeakPrefs(stateRoot: r)
        assertAllDefaults(p, voiceOff: false)
        XCTAssertNil(p.loadIssue); XCTAssertNil(p.loadLogLine); XCTAssertNil(p.settingsNotice)
        let log = MemLog(); p.reportLoad(to: log)
        XCTAssertTrue(log.lines.isEmpty, "a missing settings.json is normal, not an error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.url.path), "reading never creates the file")
        XCTAssertFalse(PeakPrefs(stateRoot: r.appendingPathComponent("not-made-yet")).loadIssue != nil, "no state root yet: silent")
    }

    func testUnreadableFileIsKeptBeforeTheFirstSave() throws {
        let bad = #"{"commandMeetingLink": true, "#
        let r = root(bad)
        let p = PeakPrefs(stateRoot: r)
        XCTAssertNotNil(p.loadIssue)
        p.setDisplay(a, shown: false)
        p.globallyHidden = true
        let backup = r.appendingPathComponent(PeakPrefs.unreadableBackupName)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), bad, "the coach's unreadable file is kept, not lost")
        let fresh = PeakPrefs(stateRoot: r)
        XCTAssertNil(fresh.loadIssue, "Peek's own write is valid JSON")
        XCTAssertFalse(fresh.isDisplayShown(a)); XCTAssertTrue(fresh.globallyHidden); XCTAssertFalse(fresh.commandMeetingLink)
        XCTAssertEqual(fresh.voiceEnabled, nil)
    }

    func testControllerStillStartsOnAnUnreadableFile() {
        let r = root("not json at all")
        let c = PeakController(prefs: PeakPrefs(stateRoot: r), profile: fixtureProfile("profile-coach-a"), hotkey: FakeHotkey())
        XCTAssertTrue(c.globallyVisible)
        XCTAssertTrue(c.isDisplayShown(a))
        let cards = CardStackViewModel(performer: SpyPerformer())
        XCTAssertNil(cards.settingsNotice)
        cards.settingsNotice = c.prefs.settingsNotice
        XCTAssertEqual(cards.settingsNotice, PeakPrefs.unreadableNotice)
    }
}

// The visible state is a plain-white status row with no toggle anywhere for desktopActions.
final class SettingsNoticeGuardTests: XCTestCase {
    func source(_ name: String) throws -> String {
        try XCTUnwrap(appSourceFiles().first { $0.name == name }, "\(name) not found").text
    }

    func testSettingsNoticeRowIsPureWhiteWithNoFade() throws {
        let s = codeLines(try source("CommandSignInViews.swift")).joined(separator: "\n")
        let r0 = try XCTUnwrap(s.range(of: "struct SettingsNoticeRow"))
        let r1 = try XCTUnwrap(s.range(of: "\n}\n", range: r0.upperBound..<s.endIndex))
        let row = String(s[r0.lowerBound..<r1.lowerBound])
        XCTAssertTrue(row.contains(".foregroundStyle(Color.white)"))
        for bad in [".opacity", "gray", "Gray", ".secondary", "tertiary", "placeholder", ".transition("] {
            XCTAssertFalse(row.contains(bad), "the settings row uses \(bad): text stays pure white at full opacity")
        }
        XCTAssertTrue(s.contains("SettingsNoticeRow(text: settingsNotice)"))
        XCTAssertTrue(try source("Views.swift").contains("settingsNotice: cards.settingsNotice"))
        let app = try source("AppDelegate.swift")
        XCTAssertTrue(app.contains("prefs.reportLoad(to: log)") && app.contains("cards.settingsNotice = prefs.settingsNotice"))
    }

    func testNoDesktopActionsToggle() {
        for f in appSourceFiles() {
            let code = codeLines(f.text).joined(separator: "\n")
            XCTAssertFalse(code.contains("desktopActions ="), "\(f.name) writes desktopActions: it has no UI and no app-side setter")
            XCTAssertFalse(code.contains("$prefs.desktopActions") || code.contains("Toggle(\"Desktop"), "\(f.name) shows a desktopActions toggle")
        }
    }
}

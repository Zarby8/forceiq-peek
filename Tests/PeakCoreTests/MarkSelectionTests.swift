import Foundation
import XCTest
@testable import PeakCore

// The mark resolution (PeakMark.resolve) + the settings.json `mark` key: the env var wins, the setting
// persists the choice per Mac, and unset means the eyes — so one coach's ghost never leaks onto another
// Mac, and a fresh install always starts on the eyes.
@MainActor final class MarkSelectionTests: XCTestCase {
    func root(_ body: String?) -> URL {
        let r = tmpRoot()
        if let body { try! Data(body.utf8).write(to: r.appendingPathComponent("settings.json")) }
        return r
    }

    func testEnvWinsOverSetting() {
        XCTAssertEqual(PeakMark.resolve(env: ["FORCEIQ_PEAK_MARK": "ghost"], setting: .bob), .ghost)
        XCTAssertEqual(PeakMark.resolve(env: ["FORCEIQ_PEAK_MARK": "bob"], setting: .ghost), .bob)
        XCTAssertEqual(PeakMark.resolve(env: ["FORCEIQ_PEAK_MARK": "eyes"], setting: .ghost), .eyes)
    }

    func testSettingAppliesWhenEnvIsSilent() {
        XCTAssertEqual(PeakMark.resolve(env: [:], setting: .ghost), .ghost)
        XCTAssertEqual(PeakMark.resolve(env: [:], setting: .bob), .bob)
        XCTAssertEqual(PeakMark.resolve(env: [:], setting: .eyes), .eyes)
    }

    func testDefaultIsEyes() {
        XCTAssertEqual(PeakMark.resolve(env: [:], setting: nil), .eyes)
        XCTAssertFalse(PeakMark.eyes.isVideo)
        XCTAssertTrue(PeakMark.bob.isVideo)
        XCTAssertTrue(PeakMark.ghost.isVideo)
    }

    func testUnrecognizedEnvFallsThroughToSetting() {
        XCTAssertEqual(PeakMark.resolve(env: ["FORCEIQ_PEAK_MARK": "banana"], setting: .ghost), .ghost)
        XCTAssertEqual(PeakMark.resolve(env: ["FORCEIQ_PEAK_MARK": ""], setting: nil), .eyes)
    }

    func testPrefsMarkKey() {
        XCTAssertEqual(PeakPrefs(stateRoot: root(#"{"mark": "ghost"}"#)).mark, .ghost)
        XCTAssertEqual(PeakPrefs(stateRoot: root(#"{"mark": "bob"}"#)).mark, .bob)
        XCTAssertNil(PeakPrefs(stateRoot: root("{}")).mark)
        XCTAssertNil(PeakPrefs(stateRoot: root(nil)).mark)
    }

    func testPrefsMarkUnrecognizedOrWrongType() {
        let p = PeakPrefs(stateRoot: root(#"{"mark": "banana"}"#))
        XCTAssertNil(p.mark)
        XCTAssertNil(p.loadIssue)                       // an unrecognized string is lenient: reads as unset
        let q = PeakPrefs(stateRoot: root(#"{"mark": 3}"#))
        XCTAssertNil(q.mark)
        XCTAssertNotNil(q.loadIssue)                    // a wrong type fails the file loudly, like every key
    }

    func testPrefsMarkRoundTrips() throws {
        let r = root("{}")
        let p = PeakPrefs(stateRoot: r)
        p.mark = .ghost
        let text = try String(contentsOf: r.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"mark\""))
        XCTAssertEqual(PeakPrefs(stateRoot: r).mark, .ghost)
        p.mark = nil
        XCTAssertNil(PeakPrefs(stateRoot: r).mark)
    }
}

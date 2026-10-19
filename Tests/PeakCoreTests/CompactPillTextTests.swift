import Foundation
import XCTest
@testable import PeakCore

/// The Studio Display pill showed "Spiros Giannoulias in…" (the countdown cut off). It now says the first name and a compact
/// countdown, so the time is always readable.
@MainActor final class CompactPillTextTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_418_400)
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func testCompactCountdownBuckets() {
        let c = { (m: Double) in NextSessionCountdown.compact(to: self.at(m), now: self.t0) }
        XCTAssertEqual(c(42), "42m"); XCTAssertEqual(c(1), "1m"); XCTAssertEqual(c(0.5), "now"); XCTAssertEqual(c(-14), "now")
        XCTAssertEqual(c(-16), "started")
        XCTAssertEqual(c(60), "1h"); XCTAssertEqual(c(190), "3h 10m"); XCTAssertEqual(c(24 * 60 + 4 * 60 + 30), "1d 4h")
        XCTAssertEqual(c(59.9), "59m")
    }

    func testThePillTextIsFirstNameAndCompactCountdown() async {
        let t = FakeTransport()
        let at = ISO8601DateFormatter().string(from: at(190))
        t.answers[NextSessionModel.path] = (200, #"{"ok":true,"session":{"client":"Spiros Giannoulias","scheduled_at":"\#(at)","duration_minutes":60,"session_type":"Breakdown","today":true},"warnings":[]}"#)
        let m = NextSessionModel(transport: t, enabled: true, roster: ["Spiros Giannoulias"])
        _ = await m.tick(now: t0)
        XCTAssertEqual(m.compactPillText(now: t0), "Spiros 3h 10m")
        XCTAssertEqual(m.pillText(now: t0), "Spiros Giannoulias in 3h 10m", "the full pill (the sheet) is unchanged")
        XCTAssertLessThanOrEqual((m.compactPillText(now: t0) ?? "").count, 16)
    }

    func testLongFirstNamesAreCutBeforeTheTime() {
        XCTAssertEqual(WingStatus.firstName("Maximilian Rodriguez", limit: 9), "Maximili…")
        XCTAssertEqual(WingStatus.firstName("Spiros Giannoulias", limit: 9), "Spiros")
        XCTAssertEqual(WingStatus.firstName("Christopher Zarb"), "Chris…", "the wing's 6-character default is unchanged")
    }

    func testTheCompactPillUsesTheCompactText() throws {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/CompactPillTextTests.swift", with: "Sources/ForceIQPeak/NextSessionViews.swift")
        let v = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(v.contains("compact ? model.compactPillText(now: ctx.date) : model.pillText(now: ctx.date)"))
    }
}

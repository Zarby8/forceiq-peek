import Foundation
import XCTest
@testable import PeakCore

/// The status wing's state: what it says, which dots it carries, and that nothing client-private shows while presenting.
final class WingStatusTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_418_400)
    func session(_ client: String = "Sample Skater", inMinutes m: Double) -> NextSession {
        NextSession(client: client, scheduledAt: t0.addingTimeInterval(m * 60), durationMinutes: 60, sessionType: "Breakdown", today: true)
    }
    func spec(_ s: NextSession? = nil, gaps: Int = 0, light: GPULightState = .green, presenting: Bool = false) -> WingSpec {
        WingStatus.spec(presenting: presenting, session: s, gaps: gaps, light: light, now: t0)
    }

    func testIdleIsPeakInGreenWithNoDots() {
        let w = spec()
        XCTAssertEqual(w.text, "PEEK"); XCTAssertEqual(w.textHex, Brand.greenHex); XCTAssertEqual(w.dots, [])
        XCTAssertEqual(w.accessibilityLabel, "ForceIQ Peek")
    }

    func testASessionInsideTheHourShowsTheFirstNameAndMinutes() {
        XCTAssertEqual(spec(session(inMinutes: 42)).text, "Sample 42m")
        XCTAssertEqual(spec(session(inMinutes: 42.9)).text, "Sample 42m", "whole minutes, rounded down")
        XCTAssertEqual(spec(session(inMinutes: 1)).text, "Sample 1m")
        XCTAssertEqual(spec(session(inMinutes: 0.5)).text, "Sample now")
        XCTAssertEqual(spec(session(inMinutes: -14)).text, "Sample now", "started, still in the first 15 minutes")
    }

    func testASessionOutsideTheWindowLeavesJustPeak() {
        XCTAssertEqual(spec(session(inMinutes: 60)).text, "PEEK", "exactly an hour out is not yet")
        XCTAssertEqual(spec(session(inMinutes: 300)).text, "PEEK")
        XCTAssertEqual(spec(session(inMinutes: -16)).text, "PEEK")
    }

    func testLongFirstNamesAreCut() {
        XCTAssertEqual(WingStatus.firstName("Christopher Zarb"), "Chris…")
        XCTAssertEqual(WingStatus.firstName("Al Roker"), "Al")
        XCTAssertEqual(WingStatus.firstName("Spiros Giannoulias"), "Spiros", "exactly six fits")
        XCTAssertEqual(WingStatus.firstName("Madonna"), "Madon…")
        XCTAssertEqual(WingStatus.firstName(""), "")
    }

    func testDotsAre5090HeldInRedThenAGapInGold() {
        XCTAssertEqual(spec(light: .red("meeting in progress")).dots, [Brand.redHex])
        XCTAssertEqual(spec(light: .unknown("status unavailable")).dots, [Brand.redHex], "unknown fails closed: red")
        XCTAssertEqual(spec(gaps: 2).dots, [Brand.goldHex])
        XCTAssertEqual(spec(gaps: 1, light: .red("x")).dots, [Brand.redHex, Brand.goldHex])
        XCTAssertEqual(spec(light: .green).dots, [], "a free 5090 is calm: no dot")
    }

    func testTheAccessibilityLabelNamesTheClientAndWhatNeedsYou() {
        let w = spec(session(inMinutes: 42), gaps: 2, light: .red("x"))
        XCTAssertEqual(w.accessibilityLabel, "ForceIQ Peek, Sample Skater in 42 minutes, 5090 held, 2 gaps need you")
        XCTAssertEqual(spec(session(inMinutes: 0.2), gaps: 1).accessibilityLabel, "ForceIQ Peek, Sample Skater now, 1 gap needs you")
    }

    func testPresentingShowsNoNameNoCountdownNoDots() {
        let w = spec(session(inMinutes: 42), gaps: 2, light: .red("x"), presenting: true)
        XCTAssertEqual(w.text, "PRESENTING"); XCTAssertEqual(w.textHex, Brand.goldHex); XCTAssertEqual(w.dots, [])
        XCTAssertFalse(w.accessibilityLabel.contains("Sample") || w.accessibilityLabel.contains("5090") || w.accessibilityLabel.contains("gap"))
    }

    func testTheLongestWingTextStillFitsTheWing() {
        let worst = WingStatus.firstName("Christopher") + " 59m"          // 11 characters at most
        XCTAssertLessThanOrEqual(worst.count, 11)
        // Measured on the M5 (11 pt heavy, 0.6 tracking): ~7.4 pt per character, and the view may scale it down to 0.75.
        // Room for text = wing - left pad 10 - dot column 12 - right pad 8.
        XCTAssertLessThanOrEqual(CGFloat(worst.count) * 7.4 * 0.75, PeakGeometry().wingWidth - 30)
    }

    func testTheWingViewIsBrandColorsOnlyAndTicksOnlyWhileACountdownShows() throws {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/WingStatusTests.swift", with: "Sources/ForceIQPeak/Views.swift")
        let v = try String(contentsOfFile: path, encoding: .utf8)
        let live = v.components(separatedBy: "struct NotchWingLive").last?.components(separatedBy: "/// Live progress under the notch").first ?? ""
        XCTAssertTrue(live.contains("Color.peakGreen") && live.contains("Color.peakGold") && live.contains("Color.peakRed"))
        XCTAssertFalse(live.contains("opacity") || live.contains("gray") || live.contains(".secondary") || live.contains("repeatForever"))
        XCTAssertTrue(live.contains("if ticking {") && live.contains("TimelineView(.periodic"), "a 30 s coarse tick, only while a countdown shows")
    }
}

import Foundation
import XCTest
@testable import PeakCore

/// The thin gold line under the notch: what counts as working, when a percent may be shown, the live-doc parse, the
/// geometry (a 2 pt line under the notch that never takes a click), and the look (brand gold, no text, nothing animating).
@MainActor final class LiveProgressTests: XCTestCase {
    let m5 = ScreenDescriptor(uuid: "M5", name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 2048, height: 1330),
                              safeAreaTop: 43, auxiliaryTopLeft: CGRect(x: 0, y: 1287, width: 899, height: 43),
                              auxiliaryTopRight: CGRect(x: 1149, y: 1287, width: 899, height: 43))
    func snap(fixes: Int = 0, downloads: Int = 0, percents: [Double] = []) -> EngineSnapshot {
        var s = EngineSnapshot(); s.fixesRunning = fixes; s.downloadsRunning = downloads; s.downloadPercents = percents; return s
    }

    func testIdleIsNotWorkingAndShowsNothing() {
        let p = LiveProgress(snap())
        XCTAssertFalse(p.working); XCTAssertNil(p.fraction); XCTAssertEqual(p.summary, ""); XCTAssertEqual(p, .idle)
    }

    func testAPercentShowsOnlyWhenEveryRunningDownloadReportsOneAndNoFixRuns() {
        XCTAssertEqual(LiveProgress(snap(downloads: 1, percents: [38])).fraction ?? -1, 0.38, accuracy: 1e-9)
        XCTAssertEqual(LiveProgress(snap(downloads: 2, percents: [20, 60])).fraction ?? -1, 0.40, accuracy: 1e-9, "the mean")
        XCTAssertNil(LiveProgress(snap(downloads: 2, percents: [20])).fraction, "one download has no percent: say working, not how far")
        XCTAssertNil(LiveProgress(snap(downloads: 1)).fraction, "no percent reported: never estimated")
        XCTAssertNil(LiveProgress(snap(fixes: 1, downloads: 1, percents: [38])).fraction, "a fix has no percent, so the line can't claim one")
        XCTAssertNil(LiveProgress(snap(fixes: 1)).fraction)
        XCTAssertTrue(LiveProgress(snap(fixes: 1)).working)
    }

    func testPercentsAreClamped() {
        XCTAssertEqual(LiveProgress(snap(downloads: 1, percents: [140])).fraction, 1)
        XCTAssertEqual(LiveProgress(snap(downloads: 1, percents: [-5])).fraction, 0)
    }

    func testSummaryIsPlainWordsAndNamesNoClient() {
        XCTAssertEqual(LiveProgress(snap(downloads: 1, percents: [38])).summary, "Downloading, 38 percent")
        XCTAssertEqual(LiveProgress(snap(downloads: 1)).summary, "Downloading")
        XCTAssertEqual(LiveProgress(snap(fixes: 1)).summary, "Fixing")
        XCTAssertEqual(LiveProgress(snap(fixes: 1, downloads: 1)).summary, "Fixing and downloading")
    }

    func testLiveDocParseKeepsOnlyNumericPercentsOfRunningDownloads() {
        let doc = #"{"fixes":[],"downloads":[{"state":"running","percent":38},{"state":"running","percent":null},{"state":"running","percent":true},{"state":"running","percent":"50"},{"state":"done","percent":100},{"state":"running","percent":12.5}],"counts":{"fixing":0,"downloading":5}}"#
        let x = EngineParse.live(Data(doc.utf8))
        XCTAssertEqual(x.downloading, 5)
        XCTAssertEqual(x.percents, [38, 12.5], "null, a bool, a string and a finished download contribute nothing")
        XCTAssertEqual(EngineParse.live(Data("not json".utf8)).percents, [])
        XCTAssertEqual(EngineParse.live(Data(#"{"fixes":[],"counts":{}}"#.utf8)).percents, [])
    }

    func testTheCardModelCarriesTheProgressFromEachRead() {
        let vm = CardStackViewModel(performer: SpyPerformer())
        vm.update(snap(downloads: 1, percents: [38]), profile: fixtureProfile("profile-coach-a"))
        XCTAssertEqual(vm.progress.fraction ?? -1, 0.38, accuracy: 1e-9)
        vm.update(snap(), profile: fixtureProfile("profile-coach-a"))
        XCTAssertEqual(vm.progress, .idle)
    }

    func testTheLineHangsJustUnderTheNotchAndTakesNoClicks() {
        let l = PeakGeometry().layout(for: m5)
        let n = l.notchRect!
        XCTAssertEqual(l.progressLine.height, 2)
        XCTAssertLessThan(l.progressLine.maxY, n.minY, "under the notch, in the screen content, never beside it in the menu bar")
        XCTAssertGreaterThanOrEqual(l.progressLine.minX, l.collapsed.minX); XCTAssertLessThanOrEqual(l.progressLine.maxX, n.maxX)
        XCTAssertTrue(l.canvas.contains(l.progressLine))
        for s in [PeakLayout.Surface.collapsed, .peek, .home, .chat] {
            XCTAssertFalse(l.hitRect(s) == l.progressLine, "not a surface")
        }
        XCTAssertFalse(l.hitRect(.collapsed).intersects(l.progressLine), "the line hangs below the collapsed shape")
        let studio = ScreenDescriptor(uuid: "S", name: "Studio Display", frame: CGRect(x: 2048, y: 0, width: 2560, height: 1440),
                                      safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        let sl = PeakGeometry().layout(for: studio)
        XCTAssertTrue(sl.virtualNotch, "the Studio Display now has a virtual notch, so the line hangs under it like the hardware one")
        XCTAssertEqual(sl.progressLine.height, 2)
        XCTAssertLessThan(sl.progressLine.maxY, sl.notchRect!.minY)
    }

    func testTheLineIsBrandGoldShapesOnlyAndNeverAnimates() throws {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/LiveProgressTests.swift", with: "Sources/ForceIQPeak/Views.swift")
        let views = try String(contentsOfFile: path, encoding: .utf8)
        let line = views.components(separatedBy: "struct NotchProgressLine").last?.components(separatedBy: "/// The ONE shell").first ?? ""
        XCTAssertTrue(line.contains("Color.peakGold"))
        XCTAssertFalse(line.contains("Text("), "a shape, never text")
        XCTAssertFalse(line.contains("repeatForever") || line.contains("TimelineView") || line.contains(".animation("), "a still line")
        XCTAssertFalse(line.contains("0x") || line.contains("gray") || line.contains(".secondary"))
    }
}

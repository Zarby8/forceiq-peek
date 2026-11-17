import XCTest
@testable import PeakCore

/// Stage 5: tile readouts, film readiness, the needs-you fault model + latch, tonight's line, the
/// money rollup, and the Stage-5 feed parsers. Only truthfully-sourced signals exist — the Ghost
/// release gate and FLOW TestFlight have no engine path, so those tiles stay plain by construction.
final class Stage5Tests: XCTestCase {
    private func snap(_ body: (inout EngineSnapshot) -> Void) -> EngineSnapshot {
        var s = EngineSnapshot(); body(&s); return s
    }

    // ── tiles ──
    func testTileReadoutsOnlyForSourcedTiles() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let s = snap { x in
            x.queueDepth = 3
            x.today = [SessionRow(client: "A", scheduledAt: now.addingTimeInterval(3600), durationMinutes: 60),
                       SessionRow(client: "B", scheduledAt: now.addingTimeInterval(-7200), durationMinutes: 60)]
        }
        let r = TileReadouts.build(from: s, now: now)
        XCTAssertEqual(r.text(forBundleID: "com.forceiq.commandbox"), "3 in queue")
        XCTAssertEqual(r.text(forBundleID: "com.forceiq.command"), "1 left today")
        XCTAssertNil(r.text(forBundleID: "com.forceiq.ghost.macos"))   // release gate: unsourced, plain
        XCTAssertNil(r.text(forBundleID: "com.forceiq.flowai"))        // TestFlight: unsourced, plain
        XCTAssertNil(r.text(forBundleID: "com.forceiq.export"))
    }
    func testTileReadoutNilWhenQueueUnknown() {
        let r = TileReadouts.build(from: snap { _ in }, now: Date())
        XCTAssertNil(r.text(forBundleID: "com.forceiq.commandbox"))
    }

    // ── film readiness ──
    func testFilmReadinessLines() {
        XCTAssertNil(FilmState(state: .ready).readinessLine)
        XCTAssertNil(FilmState(state: .unknown).readinessLine)
        XCTAssertEqual(FilmState(state: .finding).readinessLine, "Film still being found.")
        XCTAssertEqual(FilmState(state: .processing, stage: "upscaling").readinessLine, "Film still processing: upscaling.")
        XCTAssertEqual(FilmState(state: .processing).readinessLine, "Film still processing.")
    }
    func testFilmStateParse() {
        XCTAssertEqual(FilmState.parse(["state": "processing", "stage": "finding-game"])?.state, .processing)
        XCTAssertNil(FilmState.parse(["state": "bogus"]))
        XCTAssertNil(FilmState.parse(nil))
    }

    // ── needs you ──
    func testFaultsFromSnapshot() {
        let s = snap { x in
            x.pipelineFailures = [PipelineFailure(id: "up1", title: "Client upscale", step: "interpolation")]
            x.gpuWindow = GPUWindow(spans: [], live: false, calendarIssue: "calendar_unreadable")
            x.diskFreeGB = 4.2
            x.meetingError = "boom"
        }
        let f = NeedsYou.faults(from: s, now: Date())
        XCTAssertEqual(f.map(\.id), ["pipeline:up1", "calendar", "disk", "feed"])
        XCTAssertEqual(f[0].line, "Client upscale failed at interpolation")
        XCTAssertTrue(f[2].line.contains("4 GB free"))
    }
    func testNoFaultsWhenAllFine() {
        let s = snap { x in x.diskFreeGB = 400 }
        XCTAssertTrue(NeedsYou.faults(from: s, now: Date()).isEmpty)
    }
    func testFaultLatchFreshOnceThenClearsOnResolve() {
        var latch = FaultLatch()
        let a = NeedsYouFault(id: "disk", line: "x")
        XCTAssertEqual(latch.update([a]).fresh, [a])
        XCTAssertTrue(latch.update([a]).fresh.isEmpty)          // persistent: no re-nag
        XCTAssertEqual(latch.update([a]).current, [a])
        XCTAssertTrue(latch.update([]).current.isEmpty)          // resolved: clears
        XCTAssertEqual(latch.update([a]).fresh, [a])             // recurs: fresh again
    }
    func testPipelineFailureEscalatesTheMark() {
        let s = snap { x in x.pipelineFailures = [PipelineFailure(id: "k", title: "Upscale", step: "interpolation")] }
        XCTAssertEqual(GhostState.from(s), .error)
    }

    // ── money ──
    func testMoneyLineOnlyWhenPastDue() {
        XCTAssertNil(MoneyRollup(count: 0, totalCents: 0).line)
        XCTAssertEqual(MoneyRollup(count: 1, totalCents: 100_000).line, "1 unpaid invoice past due · $1,000")
        XCTAssertEqual(MoneyRollup(count: 3, totalCents: 250_050).line, "3 unpaid invoices past due · $2,501")
    }

    // ── tonight ──
    func testTonightLine() {
        let now = EngineParse.date("2026-10-19T21:00:00Z")!
        let start = EngineParse.date("2026-10-19T23:30:00Z")!
        XCTAssertEqual(TonightLine.text(TonightGames(clients: 3, nextStart: start), now: now)?.hasPrefix("3 clients tonight · puck drop "), true)
        XCTAssertEqual(TonightLine.text(TonightGames(clients: 1, nextStart: nil), now: now), "1 client tonight")
        XCTAssertNil(TonightLine.text(TonightGames(clients: 0, nextStart: nil), now: now))
    }

    // ── parsers ──
    func testStage5Parse() {
        let o: [String: Any] = ["queue_depth": 5,
                                "money": ["count": 2, "total_cents": 200_000],
                                "tonight": ["clients": 4, "next_start": "2026-10-19T23:30:00+00:00"],
                                "disk_free_gb": 123.4]
        XCTAssertEqual(Stage5Parse.queueDepth(o), 5)
        XCTAssertEqual(Stage5Parse.money(o), MoneyRollup(count: 2, totalCents: 200_000))
        XCTAssertEqual(Stage5Parse.tonight(o)?.clients, 4)
        XCTAssertEqual(Stage5Parse.diskFreeGB(o), 123.4)
        XCTAssertNil(Stage5Parse.money([:]))
        XCTAssertNil(Stage5Parse.tonight([:]))
    }
    func testPipelineFailuresParseFromLiveData() {
        let d = #"{"items":[{"key":"up1","kind":"fix","state":"failed","step":"interpolation","title":"Client upscale"},{"key":"dl1","kind":"download","state":"running","step":"","title":"Game"}]}"#.data(using: .utf8)!
        let f = Stage5Parse.pipelineFailures(liveData: d)
        XCTAssertEqual(f, [PipelineFailure(id: "up1", title: "Client upscale", step: "interpolation")])
        XCTAssertTrue(Stage5Parse.pipelineFailures(liveData: Data()).isEmpty)
    }
}

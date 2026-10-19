import Foundation
import XCTest
@testable import PeakCore

/// The 5090 light (red within 2 h, green otherwise, unknown = held) and the refusal of every 5090 GPU action while it
/// isn't green. FAKE client names only.
let lightNow = EngineParse.date("2026-10-19T12:00:00Z")!                // 8:00 AM ET
func win(_ startsIn: TimeInterval, minutes: Double = 60, live: Bool? = false) -> GPUWindow {
    GPUWindow(spans: [GPUSpan(start: lightNow.addingTimeInterval(startsIn), end: lightNow.addingTimeInterval(startsIn + minutes * 60), source: "command")], live: live)
}

final class GPULightStateTests: XCTestCase {
    func testMeetingWithinTwoHoursIsRed() {
        let s = GPULight.evaluate(win(90 * 60), readAt: lightNow, now: lightNow, tz: briefET)
        XCTAssertEqual(s, .red("meeting at 9:30 AM ET"))
        XCTAssertEqual(GPUGate.refusal(s), "Meeting at 9:30 AM ET, within 2 h: 5090 GPU jobs are held so the recorder isn't disturbed. Nothing ran.")
        XCTAssertEqual(s.dotHex, Brand.redHex)
        XCTAssertEqual(GPULight.evaluate(win(2 * 3600), readAt: lightNow, now: lightNow, tz: briefET), .red("meeting at 10:00 AM ET"), "exactly 2 h holds")
    }

    func testMoreThanTwoHoursOutIsGreen() {
        let s = GPULight.evaluate(win(2 * 3600 + 60), readAt: lightNow, now: lightNow, tz: briefET)
        XCTAssertEqual(s, .green)
        XCTAssertNil(GPUGate.refusal(s))
        XCTAssertEqual(s.dotHex, Brand.greenHex)
        XCTAssertEqual(GPULight.evaluate(GPUWindow(spans: [], live: false), readAt: lightNow, now: lightNow), .green)
        XCTAssertEqual(GPULight.evaluate(win(-2 * 3600), readAt: lightNow, now: lightNow), .green, "an ended meeting doesn't hold")
    }

    func testAMeetingInProgressOrLiveIsRed() {
        XCTAssertEqual(GPULight.evaluate(win(-20 * 60), readAt: lightNow, now: lightNow, tz: briefET), .red("meeting on now (since 7:40 AM ET)"))
        let live = GPULight.evaluate(GPUWindow(spans: [], live: true), readAt: lightNow, now: lightNow)
        XCTAssertEqual(live, .red("a Command meeting is live"))
        XCTAssertEqual(GPUGate.refusal(live), "A Command meeting is live: 5090 GPU jobs are held so the recorder isn't disturbed. Nothing ran.")
    }

    func testUnknownIsRedLabelledAndHolds() {
        let none = GPULight.evaluate(nil, readAt: nil, now: lightNow)
        XCTAssertEqual(none, .unknown("meeting status unavailable"))
        XCTAssertTrue(none.holdsGPU); XCTAssertEqual(none.dotHex, Brand.redHex)
        XCTAssertEqual(none.label, "5090 held · unknown: meeting status unavailable")
        let stale = GPULight.evaluate(win(5 * 3600), readAt: lightNow.addingTimeInterval(-301), now: lightNow, tz: briefET)
        XCTAssertEqual(stale, .unknown("meeting status STALE (read 7:54 AM ET, 5 min ago)"))
        XCTAssertEqual(GPULight.evaluate(win(5 * 3600), readAt: lightNow.addingTimeInterval(-300), now: lightNow), .green, "300 s is still fresh")
        let noLive = GPULight.evaluate(win(5 * 3600, live: nil), readAt: lightNow, now: lightNow)
        XCTAssertEqual(noLive, .unknown("Command's live status couldn't be read"))
        XCTAssertEqual(GPUGate.refusal(noLive), "Meeting status unknown (Command's live status couldn't be read): 5090 GPU jobs are held until Peak can see there's no meeting within 2 h. Nothing ran.")
    }

    func testTheClockMovesTheLightWithoutANewRead() {
        let w = win(2 * 3600 + 120)
        XCTAssertEqual(GPULight.evaluate(w, readAt: lightNow, now: lightNow), .green)
        XCTAssertEqual(GPULight.evaluate(w, readAt: lightNow, now: lightNow.addingTimeInterval(180)), .red("meeting at 10:02 AM ET"))
    }

    func testParseFailsClosed() throws {
        func doc(_ s: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any] }
        let ok = try doc(#"{"ok":true,"gpu_window":{"spans":[{"start":"2026-10-19T15:00:00+00:00","end":"2026-10-19T16:00:00+00:00","source":"command"}],"live":false}}"#)
        XCTAssertEqual(GPUWindow.parse(ok)?.spans.count, 1)
        XCTAssertEqual(GPUWindow.parse(ok)?.live, false)
        XCTAssertNil(GPUWindow.parse(try doc(#"{"ok":false,"meeting":null,"error":"Command didn't answer for bookings."}"#)))
        XCTAssertNil(GPUWindow.parse(try doc(#"{"ok":true,"meeting":null}"#)), "an older engine: unknown")
        XCTAssertNil(GPUWindow.parse(try doc(#"{"ok":true,"gpu_window":{"spans":[{"start":"soon","end":"later"}],"live":false}}"#)), "a bad span: don't guess")
        XCTAssertNil(GPUWindow.parse(try doc(#"{"ok":true,"gpu_window":{"spans":[{"start":"2026-10-19T15:00:00Z","end":"2026-10-19T16:00:00Z"}]}}"#))?.live)
    }

    @MainActor func testModelKeepsLastWindowAndGoesStaleOnItsOwn() {
        let m = GPULightModel()
        var clock = lightNow
        m.clock = { clock }
        XCTAssertTrue(m.state().holdsGPU, "no read yet: unknown")
        m.update(win(5 * 3600), at: lightNow)
        XCTAssertEqual(m.state(), .green); XCTAssertNil(m.hold())
        m.update(nil, at: lightNow.addingTimeInterval(60))            // a failed read keeps the last window + its time
        clock = lightNow.addingTimeInterval(301)
        if case .unknown(let r) = m.state() { XCTAssertTrue(r.contains("STALE")) } else { XCTFail("stale → unknown") }
        XCTAssertNotNil(m.hold())
    }
}

final class GPUGateClassifierTests: XCTestCase {
    func testWhatCountsAsA5090GPUAction() {
        XCTAssertTrue(GPUGate.isGPUAction(.shift))
        XCTAssertFalse(GPUGate.isGPUAction(.title))
        for (a, t) in [("gpu_and_deliver_retry", ""), ("recover", "step: gpu_and_deliver"), ("recover", ""), ("advisor_run", "client-upscale run"),
                       ("rerender", "then RIFE interpolation on the 5090"), ("fshifts", "add"), ("retry_pipeline_step", "job: x")] {
            XCTAssertTrue(GPUGate.isGPUAction(action: a, text: t), "\(a) \(t)")
        }
        for (a, t) in [("rerender", "title slide"), ("recover", "step: slides"), ("client_confirm", "jersey"), ("nas_remount", "")] {
            XCTAssertFalse(GPUGate.isGPUAction(action: a, text: t), "\(a) \(t)")
        }
    }
}

@MainActor final class GPURefusalTests: XCTestCase {
    static let shiftPreview = #"{"ok":true,"token":"0123456789ab","valid":true,"client":{"name":"Test Client Alpha"},"target_exists":false,"description":"d"}"#
    var light: GPULightState = .red("meeting at 9:30 AM ET")
    func hold() -> String? { GPUGate.refusal(light) }

    func testUpscaleDropZoneRefusedWhileRedAllowedWhileGreen() async {
        let t = FakeTransport(); t.answers["/api/peak/shift-drop/preview"] = (200, Self.shiftPreview)
        let d = DropStore(transport: t); d.gpuHold = { [unowned self] in self.hold() }
        d.received(URL(fileURLWithPath: "/Users/x/Alpha_DemoHawks_10.18.2026.mp4"))
        await d.preview(.shift)
        XCTAssertEqual(d.phase, .failed("Meeting at 9:30 AM ET, within 2 h: 5090 GPU jobs are held so the recorder isn't disturbed. Nothing ran."))
        XCTAssertTrue(t.posts.isEmpty, "held: nothing reached the engine")
        light = .unknown("meeting status unavailable")
        d.received(URL(fileURLWithPath: "/Users/x/Alpha_DemoHawks_10.18.2026.mp4")); await d.preview(.shift)
        if case .failed(let m) = d.phase { XCTAssertTrue(m.hasPrefix("Meeting status unknown")) } else { XCTFail("unknown holds too") }
        XCTAssertTrue(t.posts.isEmpty)
        light = .green
        d.received(URL(fileURLWithPath: "/Users/x/Alpha_DemoHawks_10.18.2026.mp4")); await d.preview(.shift)
        guard case .described = d.phase else { return XCTFail("green: the preview runs") }
        XCTAssertEqual(t.posts.map(\.0), ["/api/peak/shift-drop/preview"])
    }

    func testRunAndConfirmReCheckAtTheTap() async {
        let t = FakeTransport(); t.answers["/api/peak/shift-drop/preview"] = (200, Self.shiftPreview)
        light = .green
        let d = DropStore(transport: t); d.gpuHold = { [unowned self] in self.hold() }
        d.received(URL(fileURLWithPath: "/Users/x/Alpha_DemoHawks_10.18.2026.mp4")); await d.preview(.shift)
        light = .red("meeting at 9:30 AM ET")                          // a meeting slid inside 2 h after the preview
        await d.run()
        if case .failed = d.phase {} else { XCTFail("Run is refused") }
        XCTAssertFalse(t.posts.contains { $0.0.hasSuffix("/apply") })
        light = .green
        d.received(URL(fileURLWithPath: "/Users/x/Alpha_DemoHawks_10.18.2026.mp4")); await d.preview(.shift)
        t.answers["/api/peak/shift-drop/apply"] = (200, #"{"ok":true,"needs_confirm":true}"#); await d.run()
        light = .red("meeting at 9:30 AM ET")
        await d.confirm()
        if case .failed = d.phase {} else { XCTFail("Confirm is refused") }
        XCTAssertFalse(t.posts.contains { $0.0.hasSuffix("/apply") && ($0.1["confirm"] as? Bool) == true })
    }

    func testTitleDropIsNotGPUWorkAndRunsWhileRed() async {
        let t = FakeTransport(); t.answers["/api/peak/title-drop/preview"] = (200, #"{"ok":true,"token":"0123456789ab","client":"Test Client Alpha","ready":true,"description":"d"}"#)
        let d = DropStore(transport: t); d.gpuHold = { [unowned self] in self.hold() }
        d.received(URL(fileURLWithPath: "/Users/x/Films/x.png")); await d.preview(.title)
        guard case .described = d.phase else { return XCTFail("title drop is local work") }
    }

    func testA5090ProposalIsRefusedWhileRedAllowedWhileGreen() async {
        let t = FakeTransport()
        var o = proposalJSON(action: "recover"); o["inputs"] = ["job": "Test Client Alpha 10.18", "step": "gpu_and_deliver"]
        t.events = [.proposal(ProposalPolicy.card(from: o)!), .done(text: "", costUSD: 0, peakMTD: nil, warn: nil, firstTokenMs: nil)]
        let s = ThreePOStore(transport: t); s.gpuHold = { [unowned self] in self.hold() }
        s.draft = "retry the upscale"; await s.send()
        await s.run("abc123abc123")
        XCTAssertEqual(s.phases["abc123abc123"], .failed("Meeting at 9:30 AM ET, within 2 h: 5090 GPU jobs are held so the recorder isn't disturbed. Nothing ran."))
        XCTAssertFalse(t.posts.contains { $0.0 == "/api/act" })
        light = .green
        await s.run("abc123abc123")
        XCTAssertEqual(t.posts.last?.0, "/api/act")
        light = .red("meeting at 9:30 AM ET")
        await s.confirm("abc123abc123")
        XCTAssertEqual(t.posts.filter { $0.0 == "/api/act" }.count, 1, "confirm re-checks: still only the preview went out")
    }

    func testANonGPUProposalStillRunsWhileRed() async {
        let t = FakeTransport()
        t.events = [.proposal(ProposalPolicy.card(from: proposalJSON())!), .done(text: "", costUSD: 0, peakMTD: nil, warn: nil, firstTokenMs: nil)]
        let s = ThreePOStore(transport: t); s.gpuHold = { [unowned self] in self.hold() }
        s.draft = "x"; await s.send(); await s.run("abc123abc123")
        XCTAssertEqual(t.posts.last?.0, "/api/act")
    }

    func testA5090ApprovalRunIsRefusedWhileRedAllowedWhileGreen() async {
        let perf = SpyPerformer()
        let vm = CardStackViewModel(performer: perf)
        vm.gpuHold = { [unowned self] in self.hold() }
        var s = snapshot()
        s.approvals = s.approvals.map { a in
            a.id != "a1b2c3d4e5f6" ? a : ApprovalRow(id: a.id, kind: a.kind, kindLabel: a.kindLabel, title: "RIFE interpolation for Sample Skater", why: a.why,
                                                     client: a.client, gate: a.gate, touches: a.touches, outputs: a.outputs, actLabel: a.actLabel, test: false)
        }
        vm.update(s, profile: fixtureProfile("profile-coach-a"))
        let card = try! XCTUnwrap(vm.cards.first { $0.engineID == "a1b2c3d4e5f6" })
        XCTAssertTrue(GPUGate.isGPUAction(card))
        vm.tap(card)
        let ran = await vm.choose(.run)
        XCTAssertFalse(ran); XCTAssertTrue(perf.performed.isEmpty)
        XCTAssertEqual(vm.lastResult, "Meeting at 9:30 AM ET, within 2 h: 5090 GPU jobs are held so the recorder isn't disturbed. Nothing ran.")
        light = .green
        let ran2 = await vm.choose(.run)
        XCTAssertTrue(ran2); XCTAssertEqual(perf.performed.count, 1)
    }

    func testANonGPUApprovalStillRunsWhileRed() async {
        let perf = SpyPerformer()
        let vm = CardStackViewModel(performer: perf)
        vm.gpuHold = { [unowned self] in self.hold() }
        vm.update(snapshot(), profile: fixtureProfile("profile-coach-a"))
        let card = try! XCTUnwrap(vm.cards.first { $0.engineID == "a1b2c3d4e5f6" })
        XCTAssertFalse(GPUGate.isGPUAction(card))
        vm.tap(card)
        let ran = await vm.choose(.run)
        XCTAssertTrue(ran); XCTAssertEqual(perf.performed.count, 1)
    }
}

/// The app wires the gate into every GPU path, and no Peak code path can reach the recorder, its watchdog or the 5090.
final class GPUGuardTests: XCTestCase {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    func testEveryGPUPathIsWiredToTheLight() throws {
        let app = try String(contentsOf: Self.sources.appendingPathComponent("ForceIQPeak/AppDelegate.swift"), encoding: .utf8)
        for wire in ["dropsStore.gpuHold = gpuHold", "threePO.gpuHold = gpuHold", "cards.gpuHold = gpuHold",
                     "gpuLight.update(s.gpuWindow, at: s.takenAt ?? Date())"] {
            XCTAssertTrue(app.contains(wire), wire)
        }
        XCTAssertTrue(app.contains(#"self?.gpuLight.hold() ?? GPUGate.refusal(.unknown("meeting status unavailable"))"#), "no light = held")
    }

    func testNoCodePathCallsTheRecorderOrItsWatchdog() throws {
        let banned = try NSRegularExpression(pattern: #"(?i)\bssh\b|forceiq-5090|watchdog|launchctl|systemctl|recording\.lock|gpu-leases|nvidia-smi|\bProcess\(|\bNSTask\b|posix_spawn|(?<![.\w])system\s*\(|/usr/bin/|/bin/sh|\bkill\(|\bkillpg\("#)
        let fm = FileManager.default
        let files = try XCTUnwrap(fm.enumerator(at: Self.sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 30)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                XCTAssertNil(banned.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), "\(f.lastPathComponent):\(i + 1): \(line)")
            }
        }
        // The light reads only Peak's own engine feed; its file has no transport or network of its own.
        let light = try String(contentsOf: Self.sources.appendingPathComponent("PeakCore/GPULight.swift"), encoding: .utf8)
        for bad in ["URLSession", "transport.", "post(", "get("] { XCTAssertFalse(light.contains(bad), bad) }
    }
}

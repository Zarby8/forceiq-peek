import Foundation
@testable import PeakCore
import XCTest

/// The mark's sleep (GhostState.sleeping): after CardStackViewModel.sleepAfter of complete inactivity
/// the card model's ghost sleeps, and any activity — engine work, attention, an error, a live meeting,
/// watcher activity, chat/typing, or a user action — wakes it. Driven by the injected clock only.
@MainActor final class CardStackSleepTests: XCTestCase {
    var now = Date(timeIntervalSince1970: 1_700_000_000)

    func makeVM() -> CardStackViewModel {
        let vm = CardStackViewModel(performer: SpyPerformer())
        vm.clock = { [unowned self] in self.now }
        return vm
    }

    /// One refresh tick with a snapshot, `minutes` after the previous one.
    func tick(_ vm: CardStackViewModel, _ s: EngineSnapshot = EngineSnapshot(), minutes: Double = 1) {
        now = now.addingTimeInterval(minutes * 60)
        vm.update(s, profile: CoachProfile.none)
    }

    func testSleepsOnlyAfterTheFullIdleThreshold() {
        let vm = makeVM()
        vm.update(EngineSnapshot(), profile: CoachProfile.none)
        XCTAssertEqual(vm.ghost, .idle, "a fresh model starts awake")
        for _ in 1...9 { tick(vm); XCTAssertEqual(vm.ghost, .idle, "still awake before the threshold") }
        tick(vm, minutes: 0.5)
        XCTAssertEqual(vm.ghost, .idle, "9.5 min: awake")
        tick(vm, minutes: 0.5)
        XCTAssertEqual(vm.ghost, .sleeping, "10 min of complete inactivity: asleep")
        tick(vm, minutes: 30)
        XCTAssertEqual(vm.ghost, .sleeping, "stays asleep while nothing happens")
    }

    func testEngineWorkRestartsTheSleepClock() {
        let vm = makeVM()
        var working = EngineSnapshot(); working.fixesRunning = 1
        vm.update(working, profile: CoachProfile.none)
        for _ in 1...20 { tick(vm, working); XCTAssertEqual(vm.ghost, .working, "working never sleeps") }
        for _ in 1...9 { tick(vm); XCTAssertEqual(vm.ghost, .idle, "the countdown restarts when the work ends") }
        tick(vm)
        XCTAssertEqual(vm.ghost, .sleeping)
    }

    func testAttentionAndErrorPreventSleep() {
        var attention = EngineSnapshot()
        attention.approvals = [ApprovalRow(id: "a1b2c3d4e5f6", kind: "proposal", kindLabel: "Claude proposal",
                                           title: "Confirm jersey #17", why: "roster mismatch", client: "Sample Skater",
                                           gate: "routine", touches: [], outputs: [], actLabel: "client_confirm", test: false)]
        var error = EngineSnapshot()
        error.fixes = [FixRow(title: "x", client: "y", state: "failed", message: "")]
        for (s, want) in [(attention, GhostState.attention), (error, GhostState.error)] {
            let vm = makeVM()
            vm.update(s, profile: CoachProfile.none)
            for _ in 1...30 { tick(vm, s) }
            XCTAssertEqual(vm.ghost, want, "\(want) is activity: the mark never sleeps over it")
        }
    }

    func testALiveMeetingPreventsSleep() {
        var s = EngineSnapshot()
        s.meeting = MeetingRow(client: "Sample Skater", scheduledAt: now, durationMinutes: 60, joinURL: nil, openURL: "x")
        let vm = makeVM()
        vm.update(s, profile: CoachProfile.none)
        XCTAssertEqual(vm.ghost, .idle, "a meeting alone is not a mark state of its own")
        for _ in 1...30 { tick(vm, s) }
        XCTAssertEqual(vm.ghost, .idle, "a live meeting is activity: no sleeping through it")
    }

    func testWatcherActivityPreventsSleepAndTheClockRunsFromTheLastActiveTick() {
        let vm = makeVM()
        var agentsBusy = true
        vm.agentsActive = { agentsBusy }
        vm.update(EngineSnapshot(), profile: CoachProfile.none)
        for _ in 1...20 { tick(vm); XCTAssertEqual(vm.ghost, .idle, "an active Claude session keeps the mark awake") }
        agentsBusy = false
        for _ in 1...9 { tick(vm); XCTAssertEqual(vm.ghost, .idle, "the countdown runs from the last active tick") }
        tick(vm)
        XCTAssertEqual(vm.ghost, .sleeping)
    }

    func testActivityWakesTheMark() {
        let vm = makeVM()
        vm.update(EngineSnapshot(), profile: CoachProfile.none)
        for _ in 1...10 { tick(vm) }
        XCTAssertEqual(vm.ghost, .sleeping)
        var working = EngineSnapshot(); working.downloadsRunning = 1
        tick(vm, working)
        XCTAssertEqual(vm.ghost, .working, "the first active read wakes the mark")
    }

    func testAUserActionWakesTheMarkAtOnce() {
        let vm = makeVM()
        vm.update(EngineSnapshot(), profile: CoachProfile.none)
        for _ in 1...10 { tick(vm) }
        XCTAssertEqual(vm.ghost, .sleeping)
        vm.back()
        XCTAssertEqual(vm.ghost, .idle, "a tap wakes the mark without waiting for the next feed read")
    }

    func testTypingIsNeverSleptOver() async {
        let perf = BlockingPerformer()
        let vm = CardStackViewModel(performer: perf)
        vm.clock = { [unowned self] in self.now }
        vm.update(snapshot(), profile: fixtureProfile("profile-coach-a"))
        let card = try! XCTUnwrap(vm.cards.first { $0.engineID == "a1b2c3d4e5f6" })
        vm.tap(card)
        let chosen = Task { await vm.choose(.askClaude) }
        while perf.cont == nil { await Task.yield() }
        XCTAssertEqual(vm.ghost, .typing, "ask Claude puts the mark in typing while the reply streams")
        now = now.addingTimeInterval(20 * 60)
        vm.update(EngineSnapshot(), profile: CoachProfile.none)
        XCTAssertEqual(vm.ghost, .typing, "an update mid-stream never sleeps over the chat")
        perf.cont?.resume(returning: "done")
        let ran = await chosen.value
        XCTAssertTrue(ran)
        XCTAssertEqual(vm.ghost, .receipt, "the finished ask lands on the receipt one-shot")
    }
}

/// A performer that blocks inside perform() until the test releases it (a reply still streaming).
@MainActor final class BlockingPerformer: CardActionPerforming {
    var cont: CheckedContinuation<String, Never>?
    func perform(_ action: CardAction, on card: PeakCard) async -> String {
        await withCheckedContinuation { cont = $0 }
    }
}

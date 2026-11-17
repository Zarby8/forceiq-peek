import XCTest
@testable import PeakCore

/// Stage 6 presence: the other coach's live session — parse, the line's wording, and the view-model
/// surface. (Engine payload tests live in tests/test_peak_brief_feed.py; pill priority is view order:
/// checklist → watcher → tonight → next session → presence → idle title.)
final class Stage6Tests: XCTestCase {
    func testParsePresentAndAbsent() {
        let o: [String: Any] = ["other_coach_live": ["coach": "Shane Berschbach", "client": "Cooper Levine"]]
        XCTAssertEqual(OtherCoachLive.parse(o), OtherCoachLive(coach: "Shane Berschbach", client: "Cooper Levine"))
        XCTAssertNil(OtherCoachLive.parse([:]))
        XCTAssertNil(OtherCoachLive.parse(["other_coach_live": ["coach": "", "client": "X"]]))
        XCTAssertNil(OtherCoachLive.parse(["other_coach_live": ["coach": "Shane Berschbach"]]))
    }
    func testLineUsesFirstName() {
        XCTAssertEqual(OtherCoachLive(coach: "Shane Berschbach", client: "Cooper Levine").line,
                       "Shane is meeting with Cooper Levine")
        XCTAssertEqual(OtherCoachLive(coach: "Shane", client: "Cooper Levine").line,
                       "Shane is meeting with Cooper Levine")
    }
    @MainActor func testViewModelPublishesPresenceFromSnapshot() {
        let vm = CardStackViewModel(performer: SpyPerformer())
        var s = EngineSnapshot()
        s.otherCoachLive = OtherCoachLive(coach: "Shane Berschbach", client: "Cooper Levine")
        vm.update(s, profile: CoachProfile.none)
        XCTAssertEqual(vm.presenceLine, "Shane is meeting with Cooper Levine")
        vm.update(EngineSnapshot(), profile: CoachProfile.none)
        XCTAssertNil(vm.presenceLine)
    }
}

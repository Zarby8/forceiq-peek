import Foundation
import XCTest
@testable import PeakCore

/// The sectioned home sheet (Nov 17, 2026): HomeSheetPlan decides which sections
/// render and in what order, from bare content flags + the profile gates. The SwiftUI
/// home view derives the flags from its models and renders exactly this plan, so the
/// ordering, the module gating and the empty-section suppression are pinned here.
final class HomeSheetPlanTests: XCTestCase {
    func content(gates: HomeSheetGates = HomeSheetGates(meetings: true, agents: true, spend: true),
                 _ fill: (inout HomeSheetContent) -> Void = { _ in }) -> HomeSheetContent {
        var c = HomeSheetContent(gates: gates)
        fill(&c)
        return c
    }
    func everything(_ c: inout HomeSheetContent) {
        c.hasRecap = true; c.hasApproval = true; c.hasPresence = true; c.hasNeedsYou = true; c.hasFinish = true
        c.hasNudge = true; c.hasChecklist = true; c.hasBrief = true; c.hasNextPill = true
        c.hasAgentSessions = true; c.hasRunning = true; c.hasTonight = true; c.hasMoney = true
        c.waitingCards = 2; c.waitingExtras = true
    }

    func testFullSheetRendersEverySectionInUrgencyOrder() {
        let c = content { everything(&$0) }
        XCTAssertEqual(HomeSheetPlan.sections(c),
                       [.now, .nextSession, .agents, .running, .tonight, .business, .waiting])
    }

    func testEmptySheetIsJustNowAndWaiting() {
        // NOW always renders (the GPU/meeting status line always has a state — at
        // minimum it is the section's one quiet line) and WAITING always closes
        // (the card stack always carries its status rows). Nothing else renders,
        // and no empty labeled box appears between them.
        XCTAssertEqual(HomeSheetPlan.sections(content()), [.now, .waiting])
    }

    func testNextSessionNeedsAtLeastOnePieceOfContent() {
        XCTAssertEqual(HomeSheetPlan.sections(content { $0.hasBrief = true }),
                       [.now, .nextSession, .waiting])
        XCTAssertEqual(HomeSheetPlan.sections(content { $0.hasNextPill = true }),
                       [.now, .nextSession, .waiting])
        XCTAssertEqual(HomeSheetPlan.sections(content { $0.hasChecklist = true }),
                       [.now, .nextSession, .waiting])
    }

    func testMeetingsGateSuppressesNextSessionAndTonight() {
        let off = HomeSheetGates(meetings: false, agents: true, spend: true)
        let c = content(gates: off) { $0.hasBrief = true; $0.hasNextPill = true; $0.hasTonight = true }
        XCTAssertEqual(HomeSheetPlan.sections(c), [.now, .waiting])
    }

    func testAgentsGateSuppressesTheWatcherSectionEvenWithSessions() {
        let off = HomeSheetGates(meetings: true, agents: false, spend: true)
        let c = content(gates: off) { $0.hasAgentSessions = true }
        XCTAssertEqual(HomeSheetPlan.sections(c), [.now, .waiting])
    }

    func testSpendGateSuppressesBusinessEvenWithPastDueMoney() {
        // Shane's profile: spend off — no BUSINESS section unless his profile gains it.
        let off = HomeSheetGates(meetings: true, agents: true, spend: false)
        let c = content(gates: off) { $0.hasMoney = true }
        XCTAssertEqual(HomeSheetPlan.sections(c), [.now, .waiting])
    }

    func testShanesSheetSectionsLikeHisProfile() {
        // Shane: meetings + switcher + 3PO on; agents / approvals / family / drops /
        // spend off. His sheet sections his next session and the waiting stack, and
        // nothing agent- or money-shaped renders even if flags were somehow set.
        let shane = HomeSheetGates(meetings: true, agents: false, spend: false)
        let c = content(gates: shane) {
            $0.hasBrief = true; $0.hasNextPill = true
            $0.hasAgentSessions = true; $0.hasMoney = true; $0.hasTonight = true
        }
        XCTAssertEqual(HomeSheetPlan.sections(c), [.now, .nextSession, .tonight, .waiting])
    }

    func testRunningAndTonightVanishWithoutContent() {
        let c = content { $0.hasBrief = true }
        let s = HomeSheetPlan.sections(c)
        XCTAssertFalse(s.contains(.running))
        XCTAssertFalse(s.contains(.tonight))
        XCTAssertFalse(s.contains(.business))
        XCTAssertFalse(s.contains(.agents))
    }

    func testLabels() {
        let c = content { everything(&$0) }
        XCTAssertEqual(HomeSheetSection.now.label, "NOW")
        XCTAssertEqual(HomeSheetSection.nextSession.label, "NEXT SESSION")
        XCTAssertEqual(HomeSheetSection.tonight.label, "TONIGHT")
        XCTAssertEqual(HomeSheetSection.business.label, "BUSINESS")
        XCTAssertEqual(HomeSheetSection.waiting.label, "WAITING")
        // Every section wears the wrapper label except two: the watcher block labels
        // itself (its own heading, same treatment), and the waiting stack only when
        // cards or their footers are actually waiting.
        for s in HomeSheetPlan.sections(c) where s != .agents {
            XCTAssertTrue(HomeSheetPlan.showsLabel(s, c), "\(s)")
        }
        XCTAssertFalse(HomeSheetPlan.showsLabel(.agents, c))
        XCTAssertTrue(HomeSheetPlan.showsLabel(.waiting, c))
        let bare = content()
        XCTAssertFalse(HomeSheetPlan.showsLabel(.waiting, bare), "a lone status row wears no WAITING label")
        let extras = content { $0.waitingExtras = true }
        XCTAssertTrue(HomeSheetPlan.showsLabel(.waiting, extras), "the pipeline/unnamed footers earn the label")
    }

    func testNowAlwaysLeadsAndWaitingAlwaysCloses() {
        let combos: [HomeSheetContent] = [
            content(),
            content { everything(&$0) },
            content { $0.hasRunning = true },
            content(gates: HomeSheetGates(meetings: false, agents: false, spend: false)) { everything(&$0) },
        ]
        for c in combos {
            let s = HomeSheetPlan.sections(c)
            XCTAssertEqual(s.first, .now)
            XCTAssertEqual(s.last, .waiting)
        }
    }
}

/// The view contract (source scans): the home view renders exactly the plan, the GPU
/// light lives inside NOW on the home surface (and stays pinned on every other
/// surface), the brief card wears no heading of its own anymore, and the launcher
/// remains a footer after the scroll's host in the expanded view.
final class HomeSheetViewContractTests: XCTestCase {
    func source(_ name: String) throws -> String {
        try XCTUnwrap(appSourceFiles().first { $0.name == name }).text
    }
    func range(_ s: String, of needle: String) throws -> String.Index {
        try XCTUnwrap(s.range(of: needle), needle).lowerBound
    }

    func testHomeViewRendersThePlanInPlanOrder() throws {
        let rv = try source("RunningViews.swift")
        XCTAssertTrue(rv.contains("HomeSheetPlan.sections(content)"), "the home view renders the plan, not a hand-ordered stack")
        let cases = ["case .now:", "case .nextSession:", "case .agents:", "case .running:",
                     "case .tonight:", "case .business:", "case .waiting:"]
        let idx = try cases.map { try range(rv, of: $0) }
        XCTAssertEqual(idx, idx.sorted(), "section cases appear in plan order")
    }

    func testGPULightLivesInsideNowOnHomeAndStaysPinnedElsewhere() throws {
        let rv = try source("RunningViews.swift")
        let now = try range(rv, of: "case .now:")
        let next = try range(rv, of: "case .nextSession:")
        let dot = try range(rv, of: "GPULightDot(light: light)")
        XCTAssertTrue(now < dot && dot < next, "the GPU/meeting status line is a row of the NOW section")
        let v = try source("Views.swift")
        XCTAssertTrue(v.contains("if !showsHome { GPULightDot(light: light) }"),
                      "off the home surface the light stays pinned under the header")
    }

    func testBriefCardHasNoHeadingOfItsOwn() throws {
        let brief = try source("SessionBriefViews.swift")
        XCTAssertFalse(brief.contains("TODAY'S ONE THING"), "the heading folded into the NEXT SESSION section label")
    }

    func testLauncherStaysAFooterAfterTheHomeScroll() throws {
        let v = try source("Views.swift")
        let home = try range(v, of: "PeekHomeScroll(nextSession:")
        let launcher = try range(v, of: "SwitcherRow(entries: switcher")
        XCTAssertLessThan(home, launcher, "the switcher renders after the scroll host: a footer, not a row in the flow")
    }
}

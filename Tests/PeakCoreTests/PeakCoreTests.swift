import CoreGraphics
import CryptoKit
import Foundation
import XCTest
@testable import PeakCore

// ───────────────────────────── fixtures + fakes ─────────────────────────────
let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let peakDir = testsDir.deletingLastPathComponent().deletingLastPathComponent()

func fixtureProfile(_ name: String) -> CoachProfile {
    CoachProfile.decode(try! Data(contentsOf: testsDir.appendingPathComponent("Fixtures/\(name).json")))!
}

func tmpRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("peak-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@MainActor final class FakeHotkey: HotkeyRegistering {
    var registered = false, registerCalls = 0, unregisterCalls = 0
    var handler: (@MainActor () -> Void)?
    func register(_ onPress: @escaping @MainActor () -> Void) { registered = true; registerCalls += 1; handler = onPress }
    func unregister() { registered = false; unregisterCalls += 1; handler = nil }
    func press() { handler?() }
}

@MainActor final class SpyPerformer: CardActionPerforming {
    var performed: [CardAction] = []
    func perform(_ action: CardAction, on card: PeakCard) async -> String { performed.append(action); return "done" }
}

@MainActor final class MemLog: PeakLogging {
    var lines: [String] = []
    func log(_ event: String) { lines.append(event) }
}

struct FakeLocator: AppLocating {
    let installed: Set<String>
    func isInstalled(_ id: String) -> Bool { installed.contains(id) }
}

func snapshot() -> EngineSnapshot {
    var s = EngineSnapshot()
    s.meeting = MeetingRow(client: "Sample Skater", scheduledAt: Date().addingTimeInterval(3600), durationMinutes: 60,
                           joinURL: "https://example.test/m", openURL: "forceiq-command://app/open#path=%2Fschedule")
    s.fixes = [FixRow(title: "Re-render title slide", client: "Demo Player", state: "running", message: ""),
               FixRow(title: "Remount NAS", client: "", state: "running", message: ""),
               FixRow(title: "Upscale shift 2", client: "Demo Player", state: "running", message: "gpu")]
    s.approvals = [
        ApprovalRow(id: "a1b2c3d4e5f6", kind: "proposal", kindLabel: "Claude proposal", title: "Confirm jersey #17", why: "roster mismatch",
                    client: "Sample Skater", gate: "routine", touches: [], outputs: [], actLabel: "client_confirm", test: false),
        ApprovalRow(id: "0f9e8d7c6b5a", kind: "proposal", kindLabel: "Claude proposal", title: "Text the family", why: "",
                    client: "Demo Player", gate: "send", touches: [], outputs: [], actLabel: "imessage", test: false),
        ApprovalRow(id: "111111111111", kind: "proposal", kindLabel: "Claude proposal", title: "Remove duplicate clip", why: "",
                    client: "Sample Skater", gate: "routine", touches: [], outputs: [], actLabel: "advisor_run", test: false),
        ApprovalRow(id: "222222222222", kind: "proposal", kindLabel: "Proposal", title: "Fix the invoice", why: "",
                    client: "Demo Player", gate: "invoice/booking", touches: [], outputs: [], actLabel: "", test: false),
        ApprovalRow(id: "333333333333", kind: "escalation", kindLabel: "Escalation", title: "Update the clients table", why: "db edit",
                    client: "Sample Skater", gate: "db", touches: [], outputs: [], actLabel: "", test: false),
        ApprovalRow(id: "444444444444", kind: "proposal", kindLabel: "Proposal", title: "Book next session", why: "",
                    client: "Demo Player", gate: "routine", touches: [], outputs: [], actLabel: "", test: false),
        ApprovalRow(id: "555555555555", kind: "test", kindLabel: "Dry-run test", title: "[TEST] x", why: "",
                    client: "Sample Skater", gate: "routine", touches: [], outputs: [], actLabel: "", test: true),
        ApprovalRow(id: "666666666666", kind: "proposal", kindLabel: "Proposal", title: "No client here", why: "",
                    client: "", gate: "routine", touches: [], outputs: [], actLabel: "", test: false),
    ]
    s.familyEnabled = true
    s.family = [FamilyRow(jobID: "j1", client: "Sample Skater", reason: "no portal login", link: "https://example.test/f", meetingDate: "2026-10-14")]
    return s
}

// ───────────────────────────── client name always present ─────────────────────────────
final class ClientNameTests: XCTestCase {
    func testEveryCardNamesItsClient() {
        let out = ModuleRegistry.build(snapshot(), fixtureProfile("profile-coach-a"))
        XCTAssertFalse(out.cards.isEmpty)
        for c in out.cards { XCTAssertFalse(c.client.trimmingCharacters(in: .whitespaces).isEmpty, c.id) }
        XCTAssertGreaterThanOrEqual(out.unnamed, 2)       // the NAS fix + the no-client approval: counted, never a card
        XCTAssertFalse(out.cards.contains { $0.title.contains("No client") || $0.title.contains("Remount") })
    }

    func testMeetingWithoutClientIsDropped() {
        var s = EngineSnapshot()
        s.meeting = MeetingRow(client: "  ", scheduledAt: Date(), durationMinutes: 60, joinURL: nil, openURL: "forceiq-command://app/open")
        XCTAssertTrue(ModuleRegistry.build(s, fixtureProfile("profile-coach-a")).cards.isEmpty)
    }

    func testParseMeetingRequiresClientAndHttpsJoin() {
        let ok = #"{"ok":true,"meeting":{"client":"Sample Skater","scheduled_at":"2026-10-19T15:00:00+00:00","duration_minutes":60,"join_url":"http://x.test","open_url":"forceiq-command://app/open#path=%2Fschedule"}}"#
        let (m, _) = EngineParse.meeting(Data(ok.utf8))
        XCTAssertEqual(m?.client, "Sample Skater")
        XCTAssertNil(m?.joinURL)
        let none = #"{"ok":true,"meeting":{"client":"","scheduled_at":"2026-10-19T15:00:00+00:00"}}"#
        XCTAssertNil(EngineParse.meeting(Data(none.utf8)).0)
    }

    func testPipelineProgressIsNeverACard() {
        let out = ModuleRegistry.build(snapshot(), fixtureProfile("profile-coach-a"))
        XCTAssertFalse(out.cards.contains { $0.title.lowercased().contains("upscale") })
        XCTAssertEqual(out.pipelineHidden, 1)
        XCTAssertTrue(CardPolicy.isPipelineProgress("Dagu publish step"))
    }
}

// ───────────────────────────── tap shows the description, never runs ─────────────────────────────
@MainActor final class TapTests: XCTestCase {
    func testTapOnlyDescribes() async {
        let spy = SpyPerformer()
        let vm = CardStackViewModel(performer: spy)
        vm.update(snapshot(), profile: fixtureProfile("profile-coach-a"))
        for c in vm.cards {
            vm.tap(c)
            XCTAssertEqual(vm.phase, .describing(c.id))
            XCTAssertEqual(vm.describedCard?.id, c.id)
            XCTAssertFalse(vm.describedCard!.description.inputs.isEmpty)
            XCTAssertFalse(vm.describedCard!.description.touches.isEmpty)
            XCTAssertFalse(vm.describedCard!.description.outputs.isEmpty)
        }
        XCTAssertTrue(spy.performed.isEmpty, "a tap must never run anything")
    }

    func testNothingRunsWithoutADescribedCard() async {
        let spy = SpyPerformer()
        let vm = CardStackViewModel(performer: spy)
        vm.update(snapshot(), profile: fixtureProfile("profile-coach-a"))
        let ran = await vm.choose(.run)
        XCTAssertFalse(ran)
        XCTAssertTrue(spy.performed.isEmpty)
    }

    func testExplicitRunAfterDescriptionRuns() async {
        let spy = SpyPerformer()
        let vm = CardStackViewModel(performer: spy)
        vm.update(snapshot(), profile: fixtureProfile("profile-coach-a"))
        let c = vm.cards.first { $0.engineID == "a1b2c3d4e5f6" }!
        vm.tap(c)
        XCTAssertTrue(spy.performed.isEmpty)
        let ran = await vm.choose(.run)
        XCTAssertTrue(ran)
        XCTAssertEqual(spy.performed, [.run])
    }

    func testDescriptionOffersRunAskCopy() {
        let out = ModuleRegistry.build(snapshot(), fixtureProfile("profile-coach-a"))
        let c = out.cards.first { $0.engineID == "a1b2c3d4e5f6" }!
        XCTAssertTrue([CardAction.run, .askClaude, .copyPrompt].allSatisfy(c.actions.contains))
    }
}

// ───────────────────────────── disallowed actions are view-only ─────────────────────────────
@MainActor final class ViewOnlyTests: XCTestCase {
    func testSendsDeletesInvoicesBookingsDBAreViewOnly() {
        let out = ModuleRegistry.build(snapshot(), fixtureProfile("profile-coach-a"))
        for id in ["0f9e8d7c6b5a", "111111111111", "222222222222", "333333333333", "444444444444"] {
            let c = out.cards.first { $0.engineID == id }!
            XCTAssertTrue(c.viewOnly, id)
            XCTAssertNotNil(c.viewOnlyReason, id)
            XCTAssertFalse(c.actions.contains(.run), id)
            XCTAssertFalse(c.actions.contains(.askClaude), id)
            XCTAssertTrue(c.actions.contains(.openInGOAT), id)
        }
        XCTAssertFalse(out.cards.first { $0.engineID == "a1b2c3d4e5f6" }!.viewOnly)
    }

    func testRunIsRefusedOnAViewOnlyCardEvenIfAsked() async {
        let spy = SpyPerformer()
        let vm = CardStackViewModel(performer: spy)
        vm.update(snapshot(), profile: fixtureProfile("profile-coach-a"))
        let c = vm.cards.first { $0.engineID == "0f9e8d7c6b5a" }!
        vm.tap(c)
        let ran = await vm.choose(.run)
        XCTAssertFalse(ran)
        XCTAssertTrue(spy.performed.isEmpty)
        XCTAssertNotNil(vm.lastResult)
        _ = await vm.choose(.openInGOAT)
        XCTAssertEqual(spy.performed, [.openInGOAT])
    }

    func testFixesAreViewOnlyAndFamilyOnlyCopies() {
        let out = ModuleRegistry.build(snapshot(), fixtureProfile("profile-coach-a"))
        XCTAssertTrue(out.cards.filter { $0.kind == .fix }.allSatisfy { $0.viewOnly && !$0.actions.contains(.run) })
        let fam = out.cards.first { $0.kind == .family }!
        XCTAssertFalse(fam.actions.contains(.run))
        XCTAssertTrue(fam.actions.contains(.copyLink("https://example.test/f")))
    }

    func testFamilyCardsNeedTheEngineFlag() {
        var s = snapshot(); s.familyEnabled = false
        XCTAssertFalse(ModuleRegistry.build(s, fixtureProfile("profile-coach-a")).cards.contains { $0.kind == .family })
        XCTAssertTrue(EngineParse.family(Data(#"{"enabled":false,"alerts":[{"client":"X","id":"1"}]}"#.utf8)).rows.isEmpty)
    }

    func testOnlyBrandTextColors() {
        XCTAssertEqual(Brand.allowedTextHex, [0xFFFFFF, 0x5BE37D, 0xF5C542, 0x000000])
    }
}

// ───────────────────────────── per-display hide persistence + hotkey ─────────────────────────────
@MainActor final class PrefsAndHotkeyTests: XCTestCase {
    let a = "37D8832A-2D66-02CA-B9F7-8F30A301B230", b = "9C1A5F2E-0000-4C3B-8E7D-1234567890AB"

    func testPerDisplayHidePersistsAcrossLaunches() {
        let root = tmpRoot()
        let p1 = PeakPrefs(stateRoot: root)
        p1.setDisplay(a, shown: false)
        let p2 = PeakPrefs(stateRoot: root)               // a fresh launch reads the file
        XCTAssertFalse(p2.isDisplayShown(a))
        XCTAssertTrue(p2.isDisplayShown(b))
        XCTAssertFalse(p2.isDisplayShown(a.lowercased()))
        p2.setDisplay(a, shown: true)
        XCTAssertTrue(PeakPrefs(stateRoot: root).isDisplayShown(a))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.json").path))
    }

    func testControllerPanelVisibilityPerDisplay() {
        let c = PeakController(prefs: PeakPrefs(stateRoot: tmpRoot()), profile: fixtureProfile("profile-coach-a"), hotkey: FakeHotkey())
        c.setDisplay(a, shown: false)
        XCTAssertFalse(c.panelVisible(on: a))
        XCTAssertTrue(c.panelVisible(on: b))
        c.hide()
        XCTAssertFalse(c.panelVisible(on: b))
    }

    func testHotkeyTogglesVisibility() {
        let hk = FakeHotkey()
        let c = PeakController(prefs: PeakPrefs(stateRoot: tmpRoot()), profile: fixtureProfile("profile-coach-a"), hotkey: hk)
        XCTAssertTrue(hk.registered)
        XCTAssertTrue(c.globallyVisible)
        hk.press(); XCTAssertFalse(c.globallyVisible)
        hk.press(); XCTAssertTrue(c.globallyVisible)
    }

    func testHotkeyOffSettingUnregistersAndPersists() {
        let root = tmpRoot()
        let hk = FakeHotkey()
        let c = PeakController(prefs: PeakPrefs(stateRoot: root), profile: fixtureProfile("profile-coach-a"), hotkey: hk)
        c.setHotkeyEnabled(false)
        XCTAssertFalse(hk.registered)
        XCTAssertEqual(hk.unregisterCalls, 1)
        hk.press(); XCTAssertTrue(c.globallyVisible)       // nothing bound
        let hk2 = FakeHotkey()
        let c2 = PeakController(prefs: PeakPrefs(stateRoot: root), profile: fixtureProfile("profile-coach-a"), hotkey: hk2)
        XCTAssertFalse(c2.hotkeyEnabled)
        XCTAssertFalse(hk2.registered, "off survives a relaunch")
        c2.setHotkeyEnabled(true)
        XCTAssertTrue(hk2.registered)
        XCTAssertTrue(PeakPrefs(stateRoot: root).builtInHotkeyEnabled(default: false))
    }

    func testProfileDefaultHotkeyOffIsRespected() {
        let hk = FakeHotkey()
        let c = PeakController(prefs: PeakPrefs(stateRoot: tmpRoot()), profile: fixtureProfile("profile-demo-coach"), hotkey: hk)
        XCTAssertFalse(c.hotkeyEnabled)
        XCTAssertFalse(hk.registered)
    }
}

// ───────────────────────────── notch vs pill geometry (mock screens) ─────────────────────────────
final class GeometryTests: XCTestCase {
    // A 14" MacBook Pro-like notch display (points) and a Studio Display-like screen to its right.
    let notch = ScreenDescriptor(uuid: "N", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                 auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 662, height: 32),
                                 auxiliaryTopRight: CGRect(x: 850, y: 950, width: 662, height: 32))
    let studio = ScreenDescriptor(uuid: "S", name: "Studio Display", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                                  safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)

    func testNotchDisplayWrapsTheNotch() {
        let l = PeakGeometry().layout(for: notch)
        XCTAssertEqual(l.mode, .notch)
        XCTAssertEqual(l.notchRect, CGRect(x: 662, y: 950, width: 188, height: 32))
        XCTAssertEqual(l.collapsed.maxY, 982)
        XCTAssertEqual(l.collapsed.height, 32)
        XCTAssertLessThan(l.collapsed.minX, 662); XCTAssertGreaterThan(l.collapsed.maxX, 850)
        XCTAssertEqual(l.collapsed.midX, l.notchRect!.midX, accuracy: 0.5)
        XCTAssertEqual(l.expanded.maxY, 982)
        XCTAssertEqual(l.expanded.midX, l.notchRect!.midX, accuracy: 0.5)
    }

    func testNoNotchGetsTopCenterPill() {
        let g = PeakGeometry()
        let l = g.layout(for: studio)
        XCTAssertEqual(l.mode, .pill)
        XCTAssertNil(l.notchRect)
        XCTAssertEqual(l.collapsed.midX, studio.frame.midX, accuracy: 0.5)
        XCTAssertEqual(l.collapsed.maxY, studio.frame.maxY - g.pillTopGap, accuracy: 0.5)
        XCTAssertEqual(l.collapsed.size, g.pillSize)
        XCTAssertTrue(studio.frame.contains(l.expanded))
    }

    func testSafeAreaWithoutAuxiliaryAreasIsAPill() {
        let odd = ScreenDescriptor(uuid: "O", name: "x", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), safeAreaTop: 24,
                                   auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        XCTAssertEqual(PeakGeometry().layout(for: odd).mode, .pill)
    }
}

// ───────────────────────────── forceiq-peak:// URL parsing ─────────────────────────────
final class URLTests: XCTestCase {
    let allow: Set<String> = ["com.example.alpha", "com.example.beta"]
    func p(_ s: String) -> PeakURLAction? { PeakURLRouter.parse(s, allowedBundleIDs: allow) }

    func testEachAction() {
        XCTAssertEqual(p("forceiq-peak://toggle"), .toggle)
        XCTAssertEqual(p("forceiq-peak://show"), .show)
        XCTAssertEqual(p("forceiq-peak://hide"), .hide)
        XCTAssertEqual(p("forceiq-peak://expand"), .expand)
        XCTAssertEqual(p("forceiq-peak://collapse"), .collapse)
        XCTAssertEqual(p("forceiq-peak://ask"), .ask(nil))
        XCTAssertEqual(p("forceiq-peak://ask?q=next%20meeting%20for%20Sample"), .ask("next meeting for Sample"))
        XCTAssertEqual(p("forceiq-peak://switch?app=com.example.alpha"), .switchApp("com.example.alpha"))
        XCTAssertEqual(p("forceiq-peak://display?id=37d8832a-2d66-02ca-b9f7-8f30a301b230&state=off"),
                       .display(uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230", on: false))
        XCTAssertEqual(p("forceiq-peak://display?id=37D8832A-2D66-02CA-B9F7-8F30A301B230&state=on"),
                       .display(uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230", on: true))
        XCTAssertEqual(p("FORCEIQ-PEAK://Toggle"), .toggle)
    }

    func testBadActionAndWrongSchemeAreIgnored() {
        XCTAssertNil(p("forceiq-peak://send?to=x"))
        XCTAssertNil(p("forceiq-peak://delete"))
        XCTAssertNil(p("forceiq-peak://"))
        XCTAssertNil(p("forceiq-notch://toggle"))
        XCTAssertNil(p("https://toggle"))
        XCTAssertNil(p("forceiq-peak://toggle?x=1"))
        XCTAssertNil(p("forceiq-peak://toggle/extra"))
        XCTAssertNil(p("forceiq-peak://toggle#frag"))
        XCTAssertNil(p("forceiq-peak://user@toggle"))
    }

    func testBadDisplayState() {
        XCTAssertNil(p("forceiq-peak://display?id=37D8832A-2D66-02CA-B9F7-8F30A301B230&state=maybe"))
        XCTAssertNil(p("forceiq-peak://display?id=37D8832A-2D66-02CA-B9F7-8F30A301B230"))
        XCTAssertNil(p("forceiq-peak://display?id=not-a-uuid&state=on"))
        XCTAssertNil(p("forceiq-peak://display?id=37D8832A-2D66-02CA-B9F7-8F30A301B230&state=on&state=off"))
    }

    func testDisallowedBundle() {
        XCTAssertNil(p("forceiq-peak://switch?app=com.apple.Terminal"))
        XCTAssertNil(p("forceiq-peak://switch?app="))
        XCTAssertNil(p("forceiq-peak://switch"))
        XCTAssertNil(p("forceiq-peak://switch?app=com.example.alpha&extra=1"))
    }

    func testAskNeverCarriesControlCharsOrHugeText() {
        XCTAssertNil(p("forceiq-peak://ask?q=a%0Ab"))
        XCTAssertNil(p("forceiq-peak://ask?q=" + String(repeating: "a", count: 600)))
        XCTAssertNil(p("forceiq-peak://ask?text=hi"))
    }

    @MainActor func testControllerHandlesURLsAndLogsNamesOnly() {
        let log = MemLog()
        let c = PeakController(prefs: PeakPrefs(stateRoot: tmpRoot()), profile: fixtureProfile("profile-coach-a"), hotkey: FakeHotkey(), logger: log)
        var switched: [String] = []
        c.onSwitchApp = { switched.append($0) }
        c.handle(.hide); XCTAssertFalse(c.globallyVisible)
        c.handle(.show); XCTAssertTrue(c.globallyVisible)
        c.handle(.expand); XCTAssertTrue(c.expanded)
        c.handle(.collapse); XCTAssertFalse(c.expanded)
        c.handle(.ask("secret question text")); XCTAssertEqual(c.askText, "secret question text"); XCTAssertTrue(c.expanded)
        c.handle(.switchApp("com.example.alpha")); XCTAssertEqual(switched, ["com.example.alpha"])
        c.handle(.display(uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230", on: false))
        XCTAssertFalse(c.isDisplayShown("37D8832A-2D66-02CA-B9F7-8F30A301B230"))
        c.handle(.toggle); XCTAssertFalse(c.globallyVisible)
        let all = log.lines.joined(separator: "\n")
        XCTAssertFalse(all.contains("secret"))
        XCTAssertFalse(all.contains("com.example"))
        XCTAssertFalse(all.contains("37D8832A"))
        XCTAssertTrue(all.contains("url ask"))
    }
}

// ───────────────────────────── per-coach isolation + modules ─────────────────────────────
@MainActor final class CoachIsolationTests: XCTestCase {
    func testSecondCoachNeverSeesTheFirstCoachsClients() {
        let first = fixtureProfile("profile-coach-a"), second = fixtureProfile("profile-demo-coach")
        let s = snapshot()                                   // every client in it is on the FIRST coach's roster
        XCTAssertFalse(ModuleRegistry.build(s, first).cards.isEmpty)
        let out = ModuleRegistry.build(s, second)
        XCTAssertTrue(out.cards.isEmpty, "a coach only ever sees their own roster")
        XCTAssertFalse(out.cards.contains { first.roster.names.contains($0.client) })
    }

    func testStateRootsAreSeparate() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let a = fixtureProfile("profile-coach-a").stateRootURL(home: home), b = fixtureProfile("profile-demo-coach").stateRootURL(home: home)
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.path.hasPrefix(b.path + "/")); XCTAssertFalse(b.path.hasPrefix(a.path + "/"))
        let ra = tmpRoot(), rb = tmpRoot()
        PeakPrefs(stateRoot: ra).setDisplay("37D8832A-2D66-02CA-B9F7-8F30A301B230", shown: false)
        XCTAssertTrue(PeakPrefs(stateRoot: rb).isDisplayShown("37D8832A-2D66-02CA-B9F7-8F30A301B230"))
    }

    func testDisabledModuleShowsNoCards() {
        let second = fixtureProfile("profile-demo-coach")      // approvals + family off
        var s = snapshot()
        s.meeting = MeetingRow(client: "Pat Example", scheduledAt: Date().addingTimeInterval(600), durationMinutes: 60, joinURL: nil,
                               openURL: "forceiq-command://app/open")
        s.approvals = s.approvals.map { ApprovalRow(id: $0.id, kind: $0.kind, kindLabel: $0.kindLabel, title: $0.title, why: $0.why,
                                                     client: "Robin Sample", gate: "routine", touches: [], outputs: [], actLabel: "", test: false) }
        s.family = [FamilyRow(jobID: "j2", client: "Pat Example", reason: "r", link: nil, meetingDate: "")]
        let out = ModuleRegistry.build(s, second)
        XCTAssertEqual(out.cards.map(\.kind), [.meeting])
        var none = second; none.modules["meetings"] = false
        XCTAssertTrue(ModuleRegistry.build(s, none).cards.isEmpty)
        XCTAssertTrue(ModuleRegistry.build(s, .none).cards.isEmpty, "no profile, no cards")
    }

    func testSwitcherComesOnlyFromTheProfileAndGreysMissingApps() {
        let first = fixtureProfile("profile-coach-a")
        let e = AppSwitcher.entries(first, FakeLocator(installed: ["com.example.alpha"]))
        XCTAssertEqual(e.map(\.app.bundleID), ["com.example.alpha", "com.example.beta"])
        XCTAssertEqual(e.map(\.installed), [true, false])
        XCTAssertFalse(AppSwitcher.canActivate("com.example.beta", first, FakeLocator(installed: ["com.example.alpha"])))
        XCTAssertFalse(AppSwitcher.canActivate("com.example.demoapp", first, FakeLocator(installed: ["com.example.demoapp"])))
        XCTAssertTrue(AppSwitcher.canActivate("com.example.alpha", first, FakeLocator(installed: ["com.example.alpha"])))
    }

    func testSwitchURLIsRefusedWhenTheSwitcherModuleIsOff() {
        var p = fixtureProfile("profile-coach-a"); p.modules["switcher"] = false
        var switched = 0
        let c = PeakController(prefs: PeakPrefs(stateRoot: tmpRoot()), profile: p, hotkey: FakeHotkey())
        c.onSwitchApp = { _ in switched += 1 }
        c.handle(.switchApp("com.example.alpha"))
        XCTAssertEqual(switched, 0)
    }

    func testProfileLoaderPrefersEngineThenCacheThenNone() {
        let root = tmpRoot()
        var p = fixtureProfile("profile-coach-a"); p.stateRoot = root.path
        let d = try! JSONEncoder().encode(p)
        let (a, src) = ProfileLoader.resolve(engine: d, cacheRoot: root)
        XCTAssertEqual(src, "engine"); XCTAssertEqual(a.coachID, "coach-a")
        let (b, src2) = ProfileLoader.resolve(engine: nil, cacheRoot: root)
        XCTAssertEqual(src2, "cache"); XCTAssertEqual(b.coachID, "coach-a")
        let (c, src3) = ProfileLoader.resolve(engine: Data("{}".utf8), cacheRoot: tmpRoot())
        XCTAssertEqual(src3, "none"); XCTAssertFalse(c.configured)
    }

    func testDeclaredModuleIdsExist() {
        for id in ["drops", "3po", "voice", "machine_glance", "spend"] { XCTAssertNotNil(PeakModuleID(rawValue: id), id) }
        XCTAssertFalse(fixtureProfile("profile-coach-a").isEnabled(.threePO))
    }
}

// ───────────────────────────── the BOB Motion pack data drives playback ─────────────────────────────
final class GhostPackTests: XCTestCase {
    let bob = peakDir.appendingPathComponent("Resources/bob")
    var manifest: [String: Any] { try! JSONSerialization.jsonObject(with: Data(contentsOf: bob.appendingPathComponent("MANIFEST.json"))) as! [String: Any] }
    var pack: GhostPack { GhostPack.load(manifest: try! Data(contentsOf: bob.appendingPathComponent("MANIFEST.json")), root: bob)! }

    /// The state map and every frame count / range / duration come from MANIFEST.json, whatever its values are.
    func testStateMapIsDataDriven() {
        let m = manifest
        let map = m["peak_state_map"] as! [String: [String: Any]]
        let states = m["states"] as! [String: [String: Any]]
        XCTAssertEqual(Set(map.keys), Set(GhostState.allCases.map(\.rawValue)))
        for s in GhostState.allCases {
            let asset = map[s.rawValue]!["asset"] as! String
            let st = states[asset]!, loop = st["loop"] as! [String: Any]
            let pb = pack.playback(for: s)!
            XCTAssertEqual(pb.asset, asset)
            XCTAssertEqual(pb.frames, st["frames"] as! Int, s.rawValue)
            XCTAssertEqual(pb.mode.rawValue, loop["mode"] as! String, s.rawValue)
            XCTAssertEqual(Double(pb.frames) / pb.fps, (st["duration_s"] as! NSNumber).doubleValue, accuracy: 0.001, s.rawValue)
            if let lf = loop["loop_frames"] as? [Int] { XCTAssertEqual(pb.loop, lf[0]...lf[1], s.rawValue) }
            if let i = loop["intro_frames"] as? [Int] { XCTAssertEqual(pb.intro, i[0]...i[1], s.rawValue) }
            if let f = loop["frames"] as? [Int] { XCTAssertEqual(pb.once, f[0]...f[1], s.rawValue) }
            if let h = loop["hold_frame"] as? Int { XCTAssertEqual(pb.holdFrame, h, s.rawValue) }
        }
        // A different manifest changes playback with no code change (nothing is hardcoded).
        var edited = m
        var st = states; var idle = st["idle"]!; idle["frames"] = 30; idle["duration_s"] = 1.25
        idle["loop"] = ["mode": "loop", "loop_frames": [0, 29]]; st["idle"] = idle; edited["states"] = st
        let p2 = GhostPack.load(manifest: try! JSONSerialization.data(withJSONObject: edited), root: nil)!
        XCTAssertEqual(p2.playback(for: .idle)!.frames, 30)
        XCTAssertEqual(p2.playback(for: .idle)!.loop, 0...29)
    }

    func testPackV11Values() {
        XCTAssertEqual(manifest["version"] as? String, "1.1")
        XCTAssertEqual(pack.stateMap["working"], "thinking")
        let idle = pack.playback(for: .idle)!
        XCTAssertEqual(idle.mode, .loop); XCTAssertEqual(idle.frames, 60); XCTAssertEqual(idle.loop, 0...59)
        XCTAssertEqual(idle.seconds(idle.loop!).end, 2.5, accuracy: 1e-9)
        let w = pack.playback(for: .working)!
        XCTAssertEqual(w.mode, .introThenLoop); XCTAssertEqual(w.intro, 0...15); XCTAssertEqual(w.loop, 16...71)
        XCTAssertEqual(w.seconds(w.loop!).start, 16.0 / 24, accuracy: 1e-9)
        let t = pack.playback(for: .typing)!
        XCTAssertEqual(t.intro, 0...19); XCTAssertEqual(t.loop, 20...67)
        XCTAssertEqual(pack.playback(for: .attention)!.loop, 0...47)
        let r = pack.playback(for: .receipt)!
        XCTAssertEqual(r.mode, .oneShot); XCTAssertTrue(r.thenIdle)
        let e = pack.playback(for: .error)!
        XCTAssertEqual(e.mode, .oneShotHold); XCTAssertEqual(e.holdFrame, 61)
    }

    func testBundledFilesMatchManifestMD5AndOnlyUsedSizesShip() throws {
        XCTAssertEqual(pack.sizes, [64, 128])
        XCTAssertEqual(pack.pixelSize(points: 22, scale: 2), 64)
        XCTAssertEqual(pack.pixelSize(points: 40, scale: 2), 128)
        let shipped = try FileManager.default.contentsOfDirectory(atPath: bob.appendingPathComponent("h264-black").path).sorted()
        XCTAssertEqual(shipped.count, GhostState.allCases.count * 2)
        for s in GhostState.allCases {
            for px in pack.sizes {
                let rel = pack.file(for: s, px: px, format: .h264Black)!
                let data = try Data(contentsOf: bob.appendingPathComponent(rel))
                XCTAssertEqual(md5Hex(data), pack.md5[rel], rel)
            }
        }
        XCTAssertEqual(pack.file(for: .idle, px: 64, format: .hevcAlpha), "hevc-alpha/peak-bob-idle-64.mov")
    }

    func testGhostStateFromData() {
        var s = EngineSnapshot()
        XCTAssertEqual(GhostState.from(s), .idle)
        s.approvals = snapshot().approvals; XCTAssertEqual(GhostState.from(s), .attention)
        s.fixesRunning = 1; XCTAssertEqual(GhostState.from(s), .working)
        s.fixes = [FixRow(title: "x", client: "y", state: "failed", message: "")]; XCTAssertEqual(GhostState.from(s), .error)
    }
}

func md5Hex(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }

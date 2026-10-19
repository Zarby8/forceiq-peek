import Foundation
import XCTest
@testable import PeakCore

// Command meeting link (Command #685), behind a flag that is OFF by default. The directory is mocked entirely
// (FakeTransport answers GET /api/peak/client-directory); no test reaches the engine, Command or the network.
// Fake names only ("Test Client …") and generated UUIDs.

@MainActor final class CommandMeetingLinkTests: XCTestCase {
    static let alphaID = "756d57ad-2ded-4d28-b704-edfff0137bc7"
    static let bravoID = "c8191fda-c7f4-410e-ad9e-e8d3fca3f17b"
    static let charlieID = "c56788b1-9a49-4633-aaf9-3d2054a225b3"
    static let twinA = "bbec199d-1e28-4ed4-a997-5a1502929ed5"
    static let twinB = "2b239a94-02ad-4186-976c-e39af458e8c8"
    static let ids = [alphaID, bravoID, charlieID, twinA, twinB]
    static let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let sourcesDir = testsDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    /// The mocked directory: one id with stray case / whitespace, one non-UUID id, two clients sharing a name.
    static func directory(_ extra: String = "") -> String {
        #"{"ok":true,"count":6,"dropped":0,"clients":[{"id":"  756D57AD-2DED-4D28-B704-EDFFF0137BC7 ","display_name":"Test Client Alpha"},{"id":"c8191fda-c7f4-410e-ad9e-e8d3fca3f17b","display_name":"Test Client Bravo"},{"id":"c56788b1-9a49-4633-aaf9-3d2054a225b3","display_name":"Test Client Charlie"},{"id":"client-42","display_name":"Test Client Delta"},{"id":"bbec199d-1e28-4ed4-a997-5a1502929ed5","display_name":"Test Client Twin"},{"id":"2b239a94-02ad-4186-976c-e39af458e8c8","display_name":"Test Client Twin"}\#(extra)]}"#
    }

    let now = Date(timeIntervalSince1970: 1_792_000_000)
    let tz = TimeZone(identifier: "America/Detroit")!
    func ctx(flag: Bool = true, mode: DesktopActionMode = .off, meeting: MeetingRow? = nil) -> ClientCommandContext {
        ClientCommandContext(roster: ["Test Client Alpha", "Test Client Bravo"], meeting: meeting, desktopActions: false, flowApp: "FLOW",
                             now: now, timeZone: tz, desktopMode: mode, commandMeetingLink: flag)
    }

    struct Rig { let t: FakeTransport; let s: ThreePOStore; let log: MemLog; let opened: Box; let signIns: Box }
    final class Box { var items: [String] = [] }

    func rig(flag: Bool = true, mode: DesktopActionMode = .off, answer: (Int, String)? = nil) -> Rig {
        let t = FakeTransport()
        t.answers[DirectoryCache.path] = answer ?? (200, Self.directory())
        let log = MemLog()
        let s = ThreePOStore(transport: t, logger: log)
        let opened = Box(), signIns = Box()
        s.commandContext = { self.ctx(flag: flag, mode: mode) }
        s.onCommandRun = { c in opened.items.append(c.link ?? c.action); return "opened" }
        s.onCommandSignIn = { n in signIns.items.append(n.message) }
        return Rig(t: t, s: s, log: log, opened: opened, signIns: signIns)
    }

    func say(_ r: Rig, _ text: String) async -> ProposalCard? {
        await r.s.sendDictation(text)
        return r.s.transcript.messages.last?.proposals.first
    }

    // ── the link itself ──
    func testLinkIsOnlyBuiltFromALowercaseTrimmedUUIDWithSourceGoat() {
        XCTAssertEqual(CommandMeetingLink.url(clientID: "  756D57AD-2DED-4D28-B704-EDFFF0137BC7\n"),
                       "forceiq-command://meeting/start?client_id=756d57ad-2ded-4d28-b704-edfff0137bc7&source=goat")
        for bad in ["", " ", "Test Client Alpha", "client-42", "756d57ad2ded4d28b704edfff0137bc7", "756d57ad-2ded-4d28-b704-edfff0137bc7&x=1",
                    "756d57ad-2ded-4d28-b704-edfff0137bc7 extra", "{756d57ad-2ded-4d28-b704-edfff0137bc7}", "../sessions", "g56d57ad-2ded-4d28-b704-edfff0137bc7"] {
            XCTAssertNil(CommandMeetingLink.url(clientID: bad), bad)
            XCTAssertNil(DirectoryClient(id: bad, displayName: "Test Client Alpha"), bad)
        }
        XCTAssertNil(CommandMeetingLink.url(clientID: nil))
        XCTAssertTrue(CommandMeetingLink.isValid(CommandMeetingLink.url(clientID: Self.alphaID)))
        for bad in ["forceiq-command://meeting/start?client_id=Test%20Client%20Alpha&source=goat",
                    "forceiq-command://meeting/start?client_id=\(Self.alphaID)",
                    "forceiq-command://meeting/start?client_id=\(Self.alphaID.uppercased())&source=goat",
                    "forceiq-command://meeting/start?client_id=\(Self.alphaID)&source=goat&workflow=meeting-with-client",
                    "forceiq-command://app/open#path=%2Fschedule", "https://example.test/?client_id=\(Self.alphaID)&source=goat"] {
            XCTAssertFalse(CommandMeetingLink.isValid(bad), bad)
        }
    }

    /// Property-style: whatever name is heard or typed, it never reaches a link. Random fake names (seeded), including
    /// ones that look like query fragments; the only links that ever exist are the strict UUID shape.
    func testARawNameNeverAppearsInTheURL() async {
        var g = SeededRandom(seed: 0x5eed)
        let parts = ["test", "client", "alpha", "bravo", "zulu", "o'neil", "anne-marie", "&source=x", "client_id=", "?", "#path", "%20", "Ünïcødé"]
        var links = 0
        for _ in 0..<300 {
            var words: [String] = []
            let k = Int.random(in: 1...4, using: &g)
            for _ in 0..<k { words.append(parts[Int.random(in: 0..<parts.count, using: &g)]) }
            let n = words.joined(separator: " ")
            XCTAssertNil(CommandMeetingLink.url(clientID: n), n)
            let dir = [DirectoryClient(id: Self.alphaID, displayName: "Test Client Alpha")!,
                       DirectoryClient(id: Self.bravoID, displayName: n.isEmpty ? "Test Client Bravo" : n) ?? DirectoryClient(id: Self.bravoID, displayName: "Test Client Bravo")!]
            let cmd = ClientCommand(kind: .startMeeting, spokenClient: n, said: "start a meeting with \(n)")
            if case .unique(let c) = DirectoryMatcher.match(n, in: dir) {
                let card = ClientCommands.meetingLinkCard(cmd, client: c, ctx(), id: "x", exact: true)!
                links += 1
                XCTAssertTrue(CommandMeetingLink.isValid(card.link), card.link ?? "nil")
                let link = card.link!.lowercased()
                for w in n.lowercased().split(separator: " ") where w.count > 2 && !"forceiq-command://meeting/start?client_id=&source=goat".contains(w) {
                    XCTAssertFalse(link.contains(String(w)), "\(w) leaked into \(link)")
                }
                XCTAssertTrue(card.link!.hasSuffix(c.id + "&source=goat"))
            }
        }
        XCTAssertGreaterThan(links, 0)
        // and through the store: every link card's URL is the UUID shape, never the heard words
        let r = rig()
        for said in ["start a meeting with Test Client Alpha", "start a meeting with  TEST client   alpha ", "start a meeting with Test Client Bravo"] {
            let c = await say(r, said)
            XCTAssertTrue(CommandMeetingLink.isValid(c?.link), said)
            XCTAssertFalse(c!.link!.lowercased().contains("test"), said)
        }
    }

    // ── matching ──
    func testUniqueExactMatchGoesStraightToTheLinkCard() async {
        let r = rig()
        guard let c = await say(r, "Start a meeting with   test CLIENT alpha.") else { return XCTFail("no card") }
        XCTAssertEqual(c.origin, .command); XCTAssertEqual(c.action, ClientCommands.meetingLinkAction)
        XCTAssertEqual(c.link, "forceiq-command://meeting/start?client_id=\(Self.alphaID)&source=goat")
        XCTAssertEqual(c.client, "Test Client Alpha"); XCTAssertTrue(c.label.contains("Test Client Alpha"))
        XCTAssertTrue(c.inputs.contains("Client: Test Client Alpha"))
        XCTAssertTrue(c.touches.contains("Nothing starts until you tap Start in Command"))
        XCTAssertTrue(c.touches.contains("Start meeting sheet for Test Client Alpha"))
        XCTAssertEqual(c.outputs, ["Command: the Start meeting sheet for Test Client Alpha"])
        XCTAssertFalse(c.viewOnly); XCTAssertNil(c.previewBody); XCTAssertNil(c.confirmBody)
        XCTAssertEqual(r.s.phases[c.id], .described)
        XCTAssertEqual(r.t.gets, [DirectoryCache.path]); XCTAssertTrue(r.t.posts.isEmpty)       // one GET, no stream, no /api/act
        XCTAssertTrue(r.opened.items.isEmpty)                                                   // nothing opened before Run
    }

    func testAmbiguousGivesAPickCardNamingEveryCandidate() async {
        let r = rig()
        guard let pick = await say(r, "start a meeting with test client") else { return XCTFail("no card") }
        XCTAssertEqual(pick.origin, .pick); XCTAssertNil(pick.link)
        XCTAssertEqual(Set(pick.picks), ["Test Client Alpha", "Test Client Bravo", "Test Client Charlie", "Test Client Twin", "Test Client Twin (2)"])
        XCTAssertFalse(pick.picks.contains("Test Client Delta"))                // its id wasn't a UUID: never offered
        for p in pick.picks { for id in Self.ids { XCTAssertFalse(p.contains(id)) } }
        XCTAssertTrue(r.opened.items.isEmpty)
        r.s.pickClient(pick.id, "Test Client Bravo")
        guard let c = r.s.transcript.messages.last?.proposals.first else { return XCTFail("no link card") }
        XCTAssertEqual(c.client, "Test Client Bravo")
        XCTAssertEqual(c.link, "forceiq-command://meeting/start?client_id=\(Self.bravoID)&source=goat")
        XCTAssertTrue(c.inputs.contains("Matched: you picked this client"))
        XCTAssertTrue(r.opened.items.isEmpty)
    }

    func testSeveralExactMatchesAreAPickAndEachButtonIsOneClient() async {
        let r = rig()
        guard let pick = await say(r, "start a meeting with Test Client Twin") else { return XCTFail("no card") }
        XCTAssertEqual(pick.origin, .pick); XCTAssertEqual(pick.picks, ["Test Client Twin", "Test Client Twin (2)"])
        r.s.pickClient(pick.id, "Test Client Twin (2)")
        XCTAssertEqual(r.s.transcript.messages.last?.proposals.first?.link, CommandMeetingLink.url(clientID: Self.twinB))
    }

    func testFuzzyOrPartialGoesToConfirmNeverAuto() async {
        for said in ["start a meeting with test client alfa", "start a meeting with alpha", "start a meeting with Test Clint Charlie", "start a meeting with bravo"] {
            let r = rig()
            guard let c = await say(r, said) else { return XCTFail(said) }
            XCTAssertEqual(c.origin, .pick, said); XCTAssertNil(c.link, said)
            XCTAssertFalse(c.picks.isEmpty, said)
            XCTAssertFalse(r.log.lines.contains { $0.contains("match=unique") }, said)
        }
        let dir = [DirectoryClient(id: Self.alphaID, displayName: "Test Client Alpha")!]
        XCTAssertEqual(DirectoryMatcher.match("test client alph", in: dir), .ambiguous(dir))     // one fuzzy candidate is still a pick
        XCTAssertEqual(DirectoryMatcher.match(" TEST  client ALPHA ", in: dir), .unique(dir[0]))
    }

    func testNoMatchGivesAPlainNotFoundCard() async {
        let r = rig()
        guard let c = await say(r, "start a meeting with Nobody Fictional") else { return XCTFail("no card") }
        XCTAssertEqual(c.action, ClientCommands.notFoundAction); XCTAssertTrue(c.viewOnly); XCTAssertNil(c.link)
        XCTAssertTrue(c.reason.contains("No active client in your Command directory"))
        await r.s.run(c.id)
        XCTAssertTrue(r.opened.items.isEmpty)                                   // a not-found card has nothing to run
        XCTAssertTrue(r.log.lines.contains { $0.contains("match=none") })
    }

    func testANonUUIDIdFromTheDirectoryIsRejected() async {
        guard case .clients(let list, let dropped) = DirectoryResult.parse(200, Data(Self.directory().utf8)) else { return XCTFail() }
        XCTAssertEqual(dropped, 1); XCTAssertEqual(list.count, 5)
        XCTAssertFalse(list.contains { $0.displayName == "Test Client Delta" })
        XCTAssertTrue(list.allSatisfy { CommandMeetingLink.clientID($0.id) == $0.id })
        XCTAssertEqual(list.first?.id, Self.alphaID)                            // trimmed + lower-cased
        let r = rig()
        let c = await say(r, "start a meeting with Test Client Delta")
        XCTAssertNotEqual(c?.action, ClientCommands.meetingLinkAction)          // never a link for that row
        XCTAssertFalse(r.s.transcript.messages.flatMap(\.proposals).contains { $0.link?.contains("client-42") == true })
        // a card can't be built from a bad id even if one were handed over
        let cmd = ClientCommand(kind: .startMeeting, spokenClient: "x", said: "x")
        XCTAssertNil(DirectoryClient(id: "client-42", displayName: "Test Client Delta").flatMap { ClientCommands.meetingLinkCard(cmd, client: $0, ctx(), id: "x", exact: true) })
    }

    // ── auth: 401 → the existing sign-in row; 403 → a dead state; never a retry loop ──
    func testA401ShowsTheSignInStateAndDoesNotRetry() async {
        let expired = #"{"ok":false,"clients":[],"count":0,"auth":"expired","error":"Command sign-in expired, tap to sign in","signin":{"act":"command_signin","label":"Sign in to Command"}}"#
        for answer in [(200, expired), (401, "{}")] {
            let r = rig(answer: answer)
            guard let c = await say(r, "start a meeting with Test Client Alpha") else { return XCTFail() }
            XCTAssertEqual(c.action, ClientCommands.directoryProblemAction); XCTAssertTrue(c.viewOnly); XCTAssertNil(c.link)
            XCTAssertEqual(c.reason, CommandSignInNotice.expiredText)
            XCTAssertEqual(r.signIns.items, [CommandSignInNotice.expiredText])  // the existing sign-in row is shown
            _ = await say(r, "start a meeting with Test Client Alpha")
            XCTAssertEqual(r.t.gets.count, 1)                                   // asked again: answered from memory, no second call
            await r.s.run(c.id)
            XCTAssertTrue(r.opened.items.isEmpty)
            XCTAssertTrue(r.log.lines.contains { $0.contains("directory=expired") })
        }
    }

    func testA403IsADeadStateNotARetry() async {
        let r = rig(answer: (200, #"{"ok":false,"clients":[],"count":0,"auth":"forbidden","error":"This Command sign-in can't list clients (coach or admin only). Sign in to Command as a coach."}"#))
        guard let c = await say(r, "start a meeting with Test Client Alpha") else { return XCTFail() }
        XCTAssertEqual(c.action, ClientCommands.directoryProblemAction); XCTAssertTrue(c.viewOnly)
        XCTAssertTrue(c.reason.contains("coach or admin only"))
        XCTAssertTrue(r.signIns.items.isEmpty)
        _ = await say(r, "start a meeting with Test Client Bravo")
        XCTAssertEqual(r.t.gets.count, 1)
        XCTAssertTrue(r.opened.items.isEmpty)
        XCTAssertTrue(r.log.lines.contains { $0.contains("directory=forbidden") })
    }

    func testCacheIsMemoryOnlyAndShortLived() async {
        let t = FakeTransport()
        t.answers[DirectoryCache.path] = (200, Self.directory())
        let cache = DirectoryCache(ttl: 120, failureTTL: 30)
        let t0 = Date(timeIntervalSince1970: 1_792_000_000)
        _ = await cache.load(t, now: t0)
        let (_, hit) = await cache.load(t, now: t0.addingTimeInterval(60))
        XCTAssertTrue(hit); XCTAssertEqual(t.gets.count, 1)
        let (_, miss) = await cache.load(t, now: t0.addingTimeInterval(121))
        XCTAssertFalse(miss); XCTAssertEqual(t.gets.count, 2)
        t.answers[DirectoryCache.path] = (502, "{}")
        cache.clear()
        _ = await cache.load(t, now: t0)
        _ = await cache.load(t, now: t0.addingTimeInterval(31))
        XCTAssertEqual(t.gets.count, 4)                                         // a failure is held 30 s, then asked again on demand
        let src = try! String(contentsOf: Self.sourcesDir.appendingPathComponent("PeakCore/CommandMeetingLink.swift"), encoding: .utf8)
        for bad in ["write(to", "FileManager", "UserDefaults", "createFile", "Keychain"] { XCTAssertFalse(src.contains(bad), bad) }
    }

    // ── flag off: the old meeting path, unchanged ──
    func testFlagOffKeepsTheOldMeetingPath() async {
        let m = MeetingRow(client: "Test Client Alpha", scheduledAt: now.addingTimeInterval(1800), durationMinutes: 60, joinURL: nil,
                           openURL: CommandLink.room(sessionID: "s_1"))
        for (flag, mode) in [(false, DesktopActionMode.off), (true, .dryRun), (true, .live), (false, .dryRun)] {
            let t = FakeTransport()
            t.answers[DirectoryCache.path] = (200, Self.directory())
            let s = ThreePOStore(transport: t)
            s.commandContext = { self.ctx(flag: flag, mode: mode, meeting: m) }
            await s.sendDictation("Start a meeting with Test Client Alpha")
            let c = s.transcript.messages.last?.proposals.first
            XCTAssertEqual(c?.action, "start_meeting", "\(flag) \(mode)")
            XCTAssertEqual(c?.link, CommandLink.room(sessionID: "s_1"), "\(flag) \(mode)")
            XCTAssertTrue(t.gets.isEmpty, "\(flag) \(mode)")                    // the directory is never read
            if mode != .off { XCTAssertNotNil(DryRunPlanner.plan(c!)) }         // dry run / live: still locate-only
        }
        XCTAssertFalse(ClientCommandContext(roster: []).commandMeetingLink)
        XCTAssertFalse(ClientCommandContext(roster: []).usesMeetingLink)
    }

    func testFlagIsOffByDefaultAndHasNoUI() throws {
        XCTAssertFalse(CommandMeetingLinkGate.enabled(env: [:]))
        XCTAssertFalse(CommandMeetingLinkGate.enabled(env: ["FORCEIQ_PEAK_COMMAND_MEETING_LINK": "true"]))
        XCTAssertFalse(CommandMeetingLinkGate.enabled(env: ["FORCEIQ_PEAK_COMMAND_MEETING_LINK": "0"]))
        XCTAssertTrue(CommandMeetingLinkGate.enabled(env: ["FORCEIQ_PEAK_COMMAND_MEETING_LINK": "1"]))
        XCTAssertTrue(CommandMeetingLinkGate.enabled(env: [:], setting: true))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peak-cmdlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(PeakPrefs(stateRoot: dir).commandMeetingLink)
        let ui = try FileManager.default.contentsOfDirectory(at: Self.sourcesDir.appendingPathComponent("ForceIQPeak"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for f in ui {
            let src = try String(contentsOf: f, encoding: .utf8)
            XCTAssertFalse(src.contains("prefs.commandMeetingLink ="), f.lastPathComponent)
            XCTAssertFalse(src.contains("$prefs.commandMeetingLink"), f.lastPathComponent)
            if f.lastPathComponent != "AppDelegate.swift" { XCTAssertFalse(src.contains("commandMeetingLink"), f.lastPathComponent) }
            for line in src.split(separator: "\n") where line.contains("Toggle(") { XCTAssertFalse(line.lowercased().contains("meeting"), f.lastPathComponent) }
        }
        let app = try String(contentsOf: Self.sourcesDir.appendingPathComponent("ForceIQPeak/AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("commandMeetingLink = CommandMeetingLinkGate.enabled(env: ProcessInfo.processInfo.environment, setting: prefs.commandMeetingLink)"))
        XCTAssertTrue(app.contains("guard commandMeetingLink, desktopMode == .off, CommandMeetingLink.isValid(c.link)"))   // re-checked on Run
    }

    // ── nothing opens before Run; Run opens once ──
    func testNothingOpensBeforeAnExplicitRunTap() async {
        let r = rig()
        guard let c = await say(r, "start a meeting with Test Client Alpha") else { return XCTFail() }
        XCTAssertTrue(r.opened.items.isEmpty)
        await r.s.ask(c.id); r.s.copy(c.id)                                   // Ask Claude / Copy prompt never open anything
        XCTAssertTrue(r.opened.items.isEmpty)
        await r.s.run(c.id)
        XCTAssertEqual(r.opened.items, ["forceiq-command://meeting/start?client_id=\(Self.alphaID)&source=goat"])
        await r.s.run(c.id)
        XCTAssertEqual(r.opened.items.count, 1)                                 // a second tap does nothing
    }

    // ── logs: counts and outcomes only ──
    func testLogsNeverCarryClientNamesOrIds() async {
        let r = rig()
        for said in ["start a meeting with Test Client Alpha", "start a meeting with test client", "start a meeting with Nobody Fictional"] {
            _ = await say(r, said)
        }
        if let pick = r.s.transcript.messages.flatMap(\.proposals).first(where: { $0.origin == .pick }) { r.s.pickClient(pick.id, "Test Client Charlie") }
        if let c = r.s.transcript.messages.last?.proposals.first { await r.s.run(c.id) }
        XCTAssertTrue(r.log.lines.contains { $0.contains("match=unique") })
        XCTAssertTrue(r.log.lines.contains { $0.contains("match=ambiguous") })
        XCTAssertTrue(r.log.lines.contains { $0.contains("match=none") })
        for l in r.log.lines {
            for bad in ["Test Client", "test client", "Nobody", "Fictional", "client-42"] + Self.ids + Self.ids.map({ $0.uppercased() }) {
                XCTAssertFalse(l.contains(bad), "log leaked \(bad): \(l)")
            }
        }
    }

    func testDemoDirectoryIsFakeAndParses() {
        guard case .clients(let list, let dropped) = DirectoryResult.parse(200, Data(DemoData.directoryJSON.utf8)) else { return XCTFail() }
        XCTAssertEqual(list.count, 3); XCTAssertEqual(dropped, 1)
        XCTAssertTrue(list.allSatisfy { $0.displayName.hasPrefix("Test Client ") })
    }
}

/// A small deterministic generator for the property-style test (SplitMix64).
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

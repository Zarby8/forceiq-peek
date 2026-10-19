import Foundation
import XCTest
@testable import PeakCore

/// The engine's next-meeting answer when Command's dashboard sign-in is dead (engine/peakmeeting.py auth_expired).
let expiredJSON = #"{"ok":false,"meeting":null,"auth":"expired","error":"Command sign-in expired, tap to sign in","signin":{"act":"command_signin","label":"Sign in to Command"},"open_url":"forceiq-command://app/open#path=%2Fschedule"}"#

final class FakeSignInTransport: CommandSignInTransport, @unchecked Sendable {
    var calls: [(String, Bool)] = []
    var replies: [(Int, String)]
    init(_ replies: [(Int, String)]) { self.replies = replies }
    func act(_ name: String, confirm: Bool) async -> (Int, Data) {
        calls.append((name, confirm))
        let r = replies.isEmpty ? (500, "{}") : replies.removeFirst()
        return (r.0, Data(r.1.utf8))
    }
}

let askReply = (200, #"{"ok":true,"needs_confirm":true,"confirm_text":"Command emails a one-time sign-in link to coach@example.invalid."}"#)

final class CommandSignInParseTests: XCTestCase {
    func testExpiredMapsToVisibleNotice() {
        let n = EngineParse.commandSignIn(Data(expiredJSON.utf8))
        XCTAssertEqual(n?.message, "Command sign-in expired, tap to sign in")
        XCTAssertEqual(n?.label, "Sign in to Command")
        XCTAssertEqual(CommandSignInNotice.expiredText, "Command sign-in expired, tap to sign in")
    }

    func testOtherErrorsAndOtherActsAreNotANotice() {
        XCTAssertNil(EngineParse.commandSignIn(Data(#"{"ok":false,"meeting":null,"error":"Command didn't answer for bookings."}"#.utf8)))
        XCTAssertNil(EngineParse.commandSignIn(Data(#"{"auth":"expired","signin":{"act":"mail_send"}}"#.utf8)))
        XCTAssertNil(EngineParse.commandSignIn(Data(#"{"auth":"expired"}"#.utf8)))
        XCTAssertNil(EngineParse.commandSignIn(Data("not json".utf8)))
    }

    func testBrandWhiteOnBlackNoGray() {
        XCTAssertEqual(CommandSignInStyle.textHex, Brand.whiteHex)
        XCTAssertEqual(CommandSignInStyle.backgroundHex, Brand.blackHex)
        XCTAssertTrue(Brand.allowedTextHex.contains(CommandSignInStyle.accentHex))
        XCTAssertTrue(Brand.allowedTextHex.contains(CommandSignInStyle.buttonLabelHex))
        XCTAssertEqual(CommandSignInStyle.opacity, 1.0)
    }
}

@MainActor final class CommandSignInModelTests: XCTestCase {
    func notice() -> CommandSignInNotice { EngineParse.commandSignIn(Data(expiredJSON.utf8))! }

    func testNoticeAppearsAndNothingRunsOnItsOwn() async {
        let t = FakeSignInTransport([askReply])
        let m = CommandSignInModel(transport: t)
        m.update(notice())
        XCTAssertEqual(m.phase, .notice)
        m.update(notice()); m.update(notice())                       // feed refreshes alone never call GOAT
        XCTAssertTrue(t.calls.isEmpty)
    }

    func testTapOpensGoatsSignInConfirmWithoutRunningIt() async {
        let t = FakeSignInTransport([askReply])
        let m = CommandSignInModel(transport: t)
        m.update(notice())
        await m.tap()
        XCTAssertEqual(t.calls.map(\.0), ["command_signin"])
        XCTAssertEqual(t.calls.map(\.1), [false])                    // ask only: never confirm on the tap
        guard case .confirm(let text) = m.phase else { return XCTFail("expected GOAT's confirm, got \(m.phase)") }
        XCTAssertTrue(text.contains("one-time sign-in link"))
    }

    func testOnlyTheExplicitSignInTapConfirms() async {
        let t = FakeSignInTransport([askReply, (200, #"{"ok":true,"message":"✓ Signed in to Command"}"#)])
        let m = CommandSignInModel(transport: t)
        m.update(notice())
        await m.confirm()                                            // not on the confirm yet: ignored
        XCTAssertTrue(t.calls.isEmpty)
        await m.tap()
        await m.confirm()
        XCTAssertEqual(t.calls.map(\.1), [false, true])
        XCTAssertEqual(m.phase, .result(ok: true, "✓ Signed in to Command"))
        m.update(nil)                                                // the next feed has no notice: gone
        XCTAssertEqual(m.phase, .hidden)
    }

    func testCancelSendsNothing() async {
        let t = FakeSignInTransport([askReply])
        let m = CommandSignInModel(transport: t)
        m.update(notice())
        await m.tap()
        m.cancel()
        XCTAssertEqual(m.phase, .notice)
        XCTAssertEqual(t.calls.count, 1)
    }

    func testGoatDownShowsPlainFailureNothingRan() async {
        let t = FakeSignInTransport([(0, "")])
        let m = CommandSignInModel(transport: t)
        m.update(notice())
        await m.tap()
        XCTAssertEqual(m.phase, .result(ok: false, "GOAT didn't answer. Nothing ran."))
        m.update(notice())
        XCTAssertEqual(m.phase, .notice)
    }

    func testCardStackCarriesTheNoticeForConfiguredCoachOnly() {
        var s = EngineSnapshot()
        s.commandSignIn = notice()
        let vm = CardStackViewModel(performer: SpyPerformer(), signInTransport: FakeSignInTransport([]))
        vm.update(s, profile: DemoData.profile())
        XCTAssertEqual(vm.signIn.phase, .notice)
        vm.update(EngineSnapshot(), profile: DemoData.profile())
        XCTAssertEqual(vm.signIn.phase, .hidden)
        vm.update(s, profile: CoachProfile.none)
        XCTAssertEqual(vm.signIn.phase, .hidden)
    }
}

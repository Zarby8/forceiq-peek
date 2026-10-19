import Foundation

/// Command's dashboard sign-in is dead (the engine says auth: "expired"). Peak shows ONE plain state,
/// "Command sign-in expired, tap to sign in", and its tap opens GOAT's EXISTING Sign in to Command flow:
/// the first tap only asks GOAT (POST /api/act {name: command_signin}, no confirm) for what it would do, and nothing
/// runs until the coach taps Sign in to Command on that confirm. Peak never stores, reads or shows a token.
public struct CommandSignInNotice: Equatable, Sendable {
    public static let expiredText = "Command sign-in expired, tap to sign in"
    public static let act = "command_signin"                 // the only act this notice can ask GOAT for
    public let message: String
    public let label: String
    public init(message: String = CommandSignInNotice.expiredText, label: String = "Sign in to Command") {
        self.message = message; self.label = label
    }
}

extension EngineParse {
    /// GET /api/peak/next-meeting or /api/family-delivery-alerts → the sign-in notice when the engine says
    /// auth: "expired". Only GOAT's command_signin act is accepted; anything else is ignored.
    public static func commandSignIn(_ d: Data) -> CommandSignInNotice? {
        guard let o = obj(d), str(o["auth"]) == "expired" else { return nil }
        let s = o["signin"] as? [String: Any]
        guard str(s?["act"]) == CommandSignInNotice.act else { return nil }
        let msg = str(o["error"]).trimmingCharacters(in: .whitespaces)
        let label = str(s?["label"]).trimmingCharacters(in: .whitespaces)
        return CommandSignInNotice(message: msg.isEmpty ? CommandSignInNotice.expiredText : String(msg.prefix(120)),
                                   label: label.isEmpty ? "Sign in to Command" : String(label.prefix(40)))
    }
}

/// POST /api/act {name, args: {}, confirm}. The engine answers {ok, needs_confirm, confirm_text, message}.
public protocol CommandSignInTransport: AnyObject, Sendable {
    func act(_ name: String, confirm: Bool) async -> (Int, Data)
}

@MainActor public final class CommandSignInModel: ObservableObject {
    public enum Phase: Equatable {
        case hidden
        case notice                  // "Command sign-in expired, tap to sign in"
        case asking                  // asked GOAT what Sign in to Command does (nothing runs)
        case confirm(String)         // GOAT's own confirm text + the Sign in to Command button
        case signingIn               // the coach tapped Sign in to Command
        case result(ok: Bool, String)
    }
    @Published public private(set) var phase: Phase = .hidden
    @Published public private(set) var notice: CommandSignInNotice? = nil
    weak var transport: CommandSignInTransport?
    weak var logger: PeakLogging?
    /// Every act this model sent (name, confirm). Tests read it; the app logs only the name.
    public private(set) var sent: [(String, Bool)] = []

    public init(transport: CommandSignInTransport? = nil, logger: PeakLogging? = nil) { self.transport = transport; self.logger = logger }

    /// Each feed refresh. The notice comes and goes with the engine; a flow the coach started is left alone.
    public func update(_ n: CommandSignInNotice?) {
        notice = n
        switch phase {
        case .hidden: if n != nil { phase = .notice }
        case .notice: if n == nil { phase = .hidden }
        case .result(let ok, _): if n == nil { phase = .hidden } else if !ok { phase = .notice }
        default: break
        }
    }

    /// Tap on the notice: ask GOAT for its Sign in to Command confirm. Never confirms, so nothing runs.
    public func tap() async {
        guard phase == .notice, let t = transport else { return }
        phase = .asking
        let (code, d) = await send(t, confirm: false)
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if code == 200, (o?["needs_confirm"] as? Bool) == true {
            let text = (o?["confirm_text"] as? String) ?? "GOAT signs in to Command for you."
            phase = .confirm(String(text.prefix(600)))
        } else {
            phase = .result(ok: false, Self.message(o) ?? "GOAT didn't answer. Nothing ran.")
        }
    }

    /// The explicit Sign in to Command tap on GOAT's confirm: the only call with confirm: true.
    public func confirm() async {
        guard case .confirm = phase, let t = transport else { return }
        phase = .signingIn
        let (code, d) = await send(t, confirm: true)
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        let ok = code == 200 && (o?["ok"] as? Bool) == true
        phase = .result(ok: ok, Self.message(o) ?? (ok ? "Signed in to Command." : "Sign-in didn't finish. Nothing else changed."))
    }

    public func cancel() { phase = notice == nil ? .hidden : .notice }

    private func send(_ t: CommandSignInTransport, confirm: Bool) async -> (Int, Data) {
        sent.append((CommandSignInNotice.act, confirm))
        logger?.log("command signin \(confirm ? "confirm" : "ask")")
        return await t.act(CommandSignInNotice.act, confirm: confirm)
    }

    static func message(_ o: [String: Any]?) -> String? {
        guard let m = o?["message"] as? String, !m.isEmpty else { return nil }
        return String(m.prefix(300))
    }
}

/// The notice's look: pure white text on black, a gold outline and a filled gold action. Nothing gray or faded.
public enum CommandSignInStyle {
    public static let backgroundHex = Brand.blackHex
    public static let textHex = Brand.whiteHex
    public static let accentHex = Brand.goldHex
    public static let buttonLabelHex = Brand.blackHex
    public static let opacity: Double = 1.0
}

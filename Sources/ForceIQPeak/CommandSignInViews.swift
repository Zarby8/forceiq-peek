import SwiftUI
import PeakCore

/// "Command sign-in expired, tap to sign in": pure white on black, gold outline, gold action. Tapping asks GOAT for
/// its Sign in to Command confirm (nothing runs); only the Sign in to Command button on that confirm signs in.
/// The top of the home list: the Command sign-in notice when the engine says so, else "All clear" when empty.
struct HomeStatusRows: View {
    @ObservedObject var signIn: CommandSignInModel
    let empty: Bool
    var body: some View {
        if signIn.phase != .hidden {
            CommandSignInBanner(model: signIn)
        } else if empty {
            Text("All clear. Nothing waiting for you.").font(.system(size: 13)).foregroundStyle(Color.white)
        }
    }
}

struct CommandSignInBanner: View {
    @ObservedObject var model: CommandSignInModel
    var white: Color { Color(hex: CommandSignInStyle.textHex) }
    var gold: Color { Color(hex: CommandSignInStyle.accentHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.phase {
            case .hidden:
                EmptyView()
            case .notice:
                Button(action: { Haptic.tick(); Task { await model.tap() } }) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(gold)
                        Text(model.notice?.message ?? CommandSignInNotice.expiredText)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(white)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(gold)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.notice?.message ?? CommandSignInNotice.expiredText)
            case .asking:
                Text("Asking GOAT how it signs you in. Nothing runs yet.").font(.system(size: 12)).foregroundStyle(white)
            case .confirm(let text):
                Text("Sign in to Command").font(.system(size: 13, weight: .bold)).foregroundStyle(gold)
                Text(text).font(.system(size: 12)).foregroundStyle(white).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PeakButton(title: model.notice?.label ?? "Sign in to Command", color: .peakGold, filled: true) { Task { await model.confirm() } }
                    PeakButton(title: "Not now", color: .peakGold) { model.cancel() }
                }
            case .signingIn:
                Text("Signing in to Command through GOAT (it reads the sign-in email from Mail, up to 3 min).")
                    .font(.system(size: 12)).foregroundStyle(white).fixedSize(horizontal: false, vertical: true)
            case .result(let ok, let msg):
                Text(msg).font(.system(size: 12, weight: .semibold)).foregroundStyle(ok ? Color.peakGreen : white)
                    .fixedSize(horizontal: false, vertical: true)
                if !ok { PeakButton(title: "Back", color: .peakGold) { model.cancel() } }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: CommandSignInStyle.backgroundHex)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(gold, lineWidth: 1))
        .opacity(CommandSignInStyle.opacity)
    }
}

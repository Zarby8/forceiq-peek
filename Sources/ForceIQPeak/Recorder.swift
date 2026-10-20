import KeyboardShortcuts
import SwiftUI

/// KeyboardShortcuts' own recorder for the Peek shortcut (default ctrl+opt+G).
struct HotkeyRecorder: View {
    var body: some View { KeyboardShortcuts.Recorder(for: PeakHotkeyName.current) }
}

/// The dictation toggle's own shortcut (default ctrl+opt+D): a press starts listening, the next press stops.
struct DictateRecorder: View {
    var body: some View { KeyboardShortcuts.Recorder(for: .dictate) }
}

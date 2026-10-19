import KeyboardShortcuts
import SwiftUI

/// KeyboardShortcuts' own recorder for the Peak shortcut (default ctrl+opt+G).
struct HotkeyRecorder: View {
    var body: some View { KeyboardShortcuts.Recorder(for: PeakHotkeyName.current) }
}

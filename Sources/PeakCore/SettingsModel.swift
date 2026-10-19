import Foundation
import Combine

/// The Settings window's state: one place that reads and writes the prefs the menu used to leave to hand-edited JSON. Every
/// change is written through at once. `restartNeeded` is set for the two switches Peek reads only at launch (the next-session
/// feed and the menu-bar item); everything else takes effect immediately.
@MainActor public final class SettingsModel: ObservableObject {
    let prefs: PeakPrefs
    let controller: PeakController
    private var bag = Set<AnyCancellable>()

    @Published public var autoPresenting: Bool { didSet { if autoPresenting != oldValue { prefs.autoPresenting = autoPresenting; controller.reevaluatePresenting() } } }
    @Published public var nextSessionPill: Bool { didSet { if nextSessionPill != oldValue { prefs.nextSessionPill = nextSessionPill; restartNeeded = true } } }
    @Published public var menuBarItem: Bool { didSet { if menuBarItem != oldValue { prefs.menuBarItem = menuBarItem; restartNeeded = true } } }
    @Published public var quietEnabled: Bool { didSet { if quietEnabled != oldValue { writeQuiet() } } }
    /// Minutes after local midnight.
    @Published public var quietStart: Int { didSet { if quietStart != oldValue { writeQuiet() } } }
    @Published public var quietEnd: Int { didSet { if quietEnd != oldValue { writeQuiet() } } }
    @Published public private(set) var dndUntil: Date?
    @Published public private(set) var presenting: Bool
    @Published public private(set) var restartNeeded = false

    public init(prefs: PeakPrefs, controller: PeakController) {
        self.prefs = prefs; self.controller = controller
        autoPresenting = prefs.autoPresenting
        nextSessionPill = prefs.nextSessionPill
        menuBarItem = prefs.menuBarItem
        let q = prefs.quietHours
        quietEnabled = q != nil
        quietStart = q?.startMinute ?? 22 * 60
        quietEnd = q?.endMinute ?? 7 * 60
        dndUntil = prefs.dndUntil
        presenting = controller.presenting
        controller.$presenting.receive(on: RunLoop.main).sink { [weak self] p in self?.presenting = p }.store(in: &bag)
    }

    private func writeQuiet() { prefs.setQuietHours(quietEnabled ? QuietHours(startMinute: quietStart, endMinute: quietEnd) : nil) }

    /// Re-read what other places (the menu) may have changed.
    public func refresh() { dndUntil = prefs.dndUntil; presenting = controller.presenting }

    public func setDoNotDisturb(_ c: DoNotDisturbChoice, now: Date = Date()) { controller.setDoNotDisturb(c, now: now); dndUntil = prefs.dndUntil }
    public func setPresenting(_ on: Bool) { controller.setPresenting(on) }

    /// "Do not disturb until 3:10 PM", or "off" once it has passed.
    public func dndLine(now: Date = Date()) -> String {
        guard let u = dndUntil, u > now else { return "off" }
        return "until " + DateFormatter.localizedString(from: u, dateStyle: Calendar.current.isDate(u, inSameDayAs: now) ? .none : .short, timeStyle: .short)
    }

    /// Date ↔ minutes for the time pickers.
    public static func date(minutes: Int, on day: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }
    public static func minutes(of d: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: d); return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

import AppKit
import CoreFoundation

/// Moving the user INTO an app whose main window lives on another Space — the full-screen
/// case Christopher reported twice (Nov 17, 2026). Measured live on his three-display desk,
/// under his real conditions (target full-screen on the main display, that display showing
/// another app's Space): NSRunningApplication.activate(), a Launch Services reopen
/// (`open -b`), an Accessibility raise, and an AppleScript activate ALL make the app
/// frontmost and leave every display on its current Space — the switch reads as dead.
/// (On a single display the reopen did switch, which is why the first fix "passed".)
/// The Dock and Mission Control switch because the WindowServer itself moves the display's
/// current Space; the only programmatic route to that same move is SkyLight's managed-space
/// setter. It is resolved at runtime, symbol by symbol: if anything is missing or any step
/// fails, the jump returns false and the caller keeps the plain reopen — an enhancement
/// with a fallback, never a single point of failure.
enum SpaceJump {
    /// If the app's main (largest) window is not on any display's current Space, move its
    /// display's current Space to the window's Space. Returns true when a jump was issued.
    /// The caller still activates the app afterwards (the reopen), which then lands the
    /// user in the window they asked for.
    static func jumpToWindowSpace(of app: NSRunningApplication) -> Bool {
        guard let bridge = Bridge.shared, let win = mainWindow(of: app) else { return false }
        if onScreenWindowIDs().contains(win.id) { return false }   // visible on a current Space already: the reopen lands unaided
        guard let spaces = bridge.spaces(forWindow: win.id), spaces.count == 1, let sid = spaces.first,
              let uuid = displayUUID(containing: win.bounds) else { return false }
        return bridge.setCurrentSpace(sid, onDisplay: uuid)
    }

    /// The app's largest layer-0 window — its main window, for the apps the switcher carries.
    private static func mainWindow(of app: NSRunningApplication) -> (id: Int, bounds: CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var best: (id: Int, bounds: CGRect)?
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? Int, owner == Int(app.processIdentifier),
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let wid = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let width = b["Width"] as? CGFloat, let height = b["Height"] as? CGFloat else { continue }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            if best == nil || rect.width * rect.height > best!.bounds.width * best!.bounds.height { best = (wid, rect) }
        }
        return best
    }

    /// Windows on a CURRENT Space of some display (the on-screen list is exactly that).
    private static func onScreenWindowIDs() -> Set<Int> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? Int })
    }

    /// The UUID of the display whose bounds contain the window's center.
    private static func displayUUID(containing rect: CGRect) -> String? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for id in ids where CGDisplayBounds(id).contains(center) {
            guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let s = CFUUIDCreateString(nil, cf) as String? else { return nil }
            return s
        }
        return nil
    }

    // ── the SkyLight bridge: every symbol optional, resolved once ──
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?
    private typealias SetSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Int32

    private final class Bridge {
        static var shared: Bridge? { Bridge() }   // built per call: dlopen/dlsym are cheap on a click path, and a computed property stays clear of shared-mutable-state rules
        private let cid: Int32
        private let copySpacesFn: CopySpacesFn
        private let setSpaceFn: SetSpaceFn
        init?() {
            guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
                  let main = dlsym(h, "SLSMainConnectionID"),
                  let copy = dlsym(h, "CGSCopySpacesForWindows"),
                  let set = dlsym(h, "SLSManagedDisplaySetCurrentSpace") else { return nil }
            cid = unsafeBitCast(main, to: MainConnFn.self)()
            copySpacesFn = unsafeBitCast(copy, to: CopySpacesFn.self)
            setSpaceFn = unsafeBitCast(set, to: SetSpaceFn.self)
        }
        func spaces(forWindow id: Int) -> [UInt64]? {
            (copySpacesFn(cid, 0x7, [id] as CFArray) as? [NSNumber])?.map { $0.uint64Value }
        }
        func setCurrentSpace(_ sid: UInt64, onDisplay uuid: String) -> Bool {
            setSpaceFn(cid, uuid as CFString, sid) == 0
        }
    }
}

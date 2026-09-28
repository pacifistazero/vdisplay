import Cocoa

/// Software brightness for a display with no backlight to talk to - a virtual display,
/// or a panel on a port that can't do DDC. A black window covers the screen and its
/// alpha stands in for "how dim".
///
/// This is the trick MonitorControl uses for virtual displays specifically: its normal
/// software dimming scales the gamma table (`CGSetDisplayTransferByTable`), but gamma
/// does not take on a virtual display, so it falls back to an overlay window. Since the
/// physical monitor here mirrors the virtual display, dimming the virtual display dims
/// what the monitor shows.
final class DisplayShade {
    static let shared = DisplayShade()

    /// Brightness floor. At 0 the screen would be solid black with no way to see the menu
    /// that turns it back up, so the darkest setting still passes 15% through - the same
    /// floor MonitorControl uses.
    private static let floor = 0.15

    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var levels: [CGDirectDisplayID: Int] = [:]

    /// Current software brightness for a display, 100 when it was never dimmed.
    func level(for displayID: CGDirectDisplayID) -> Int { levels[displayID] ?? 100 }

    /// Nudge a display's software brightness and return the level actually applied.
    @discardableResult
    func change(_ displayID: CGDirectDisplayID, by delta: Int) -> Int {
        let next = max(0, min(100, level(for: displayID) + delta))
        set(level: next, for: displayID)
        return next
    }

    /// Dim `displayID` to `level` percent, 100 being untouched. Returns false when that
    /// display is not on screen (a mirror slave is not its own `NSScreen`, the master is).
    @discardableResult
    func set(level: Int, for displayID: CGDirectDisplayID) -> Bool {
        guard let screen = Self.screen(for: displayID) else { return false }
        let window = windows[displayID] ?? make(for: displayID, on: screen)
        window.setFrame(screen.frame, display: true)
        let clamped = max(0, min(100, level))
        let brightness = Self.floor + (1 - Self.floor) * Double(clamped) / 100
        window.contentView?.alphaValue = 1 - brightness
        levels[displayID] = clamped
        return true
    }

    /// Drop the overlay for a display that has gone away.
    func clear(_ displayID: CGDirectDisplayID) {
        windows.removeValue(forKey: displayID)?.close()
        levels.removeValue(forKey: displayID)
    }

    /// Drop overlays for displays that are gone. Without this, a shade whose display was
    /// removed keeps its frame and can end up dimming a screen that is still there.
    func prune(keeping live: Set<CGDirectDisplayID>) {
        for id in windows.keys where !live.contains(id) { clear(id) }
    }

    func clearAll() {
        windows.values.forEach { $0.close() }
        windows.removeAll()
    }

    private func make(for displayID: CGDirectDisplayID, on screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: [],
                              backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        // Above everything, including the menu bar and full-screen apps, or the dimming
        // would stop at whatever window happens to be in front.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = .black
        window.contentView?.alphaValue = 0
        window.orderFrontRegardless()
        windows[displayID] = window
        return window
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID
        }
    }
}

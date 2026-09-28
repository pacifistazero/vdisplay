import Cocoa
import ApplicationServices
import VirtualDisplayKit

/// Routes the keyboard brightness and volume keys to an external monitor over
/// DDC - MonitorControl-style.
///
/// The two key groups arrive as different event types on Apple Silicon:
/// - brightness: ordinary `keyDown` events (keycode 144 = up / F2, 145 = down / F1)
/// - volume: `NSSystemDefined` subtype 8 events (keyCode 0 = up, 1 = down, 7 = mute)
///
/// Installing an active (event-swallowing) tap requires Accessibility permission.
/// While enabled the built-in HUD is suppressed and we draw our own via `LevelHUD`.
final class MediaKeyController {
    private static let keyDownRawType: UInt32 = 10        // kCGEventKeyDown
    private static let keyUpRawType: UInt32 = 11          // kCGEventKeyUp
    private static let systemDefinedRawType: UInt32 = 14  // NSEvent.EventType.systemDefined
    private static let brightnessUpKey: Int64 = 144       // F2
    private static let brightnessDownKey: Int64 = 145     // F1
    private static let soundUpKey = 0                     // NX_KEYTYPE_SOUND_UP
    private static let soundDownKey = 1                   // NX_KEYTYPE_SOUND_DOWN
    private static let muteKey = 7                        // NX_KEYTYPE_MUTE
    private static let step = 6                           // percent per key press

    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private let ddcQueue = DispatchQueue(label: "com.vdisplay.ddc.keys")
    private let pendingLock = NSLock()
    private var pending: [String: Int] = [:]   // feature -> newest wanted value
    private var failures: [String: Int] = [:]  // feature -> consecutive write failures
    // Touched only on the main thread (the tap source runs on the main run loop).
    private var brightnessLevel = 100
    private var volumeLevel = 50
    private var mutedFrom: Int?   // volume before muting, nil when not muted
    private let hud = LevelHUD()
    // Refreshed on the main thread when displays change, read on the tap thread.
    private var layout = BrightnessTarget.Layout()

    private(set) var routesBrightness = false
    private(set) var routesVolume = false

    var isRunning: Bool { tap != nil }

    /// Whether this process has Accessibility permission. If `prompt` is true and
    /// it doesn't, macOS shows its own "grant access" dialog.
    static func hasAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Choose which key groups are routed to DDC, starting or stopping the tap as
    /// needed. Returns nil on success, else a message explaining what stopped it.
    ///
    /// A group is only routed if the monitor actually answers on DDC - otherwise we
    /// would swallow the keys and leave the user with no working volume/brightness.
    @discardableResult
    func update(brightness: Bool, volume: Bool) -> String? {
        // Re-read so the first key press steps from the monitor's real value. Brightness
        // is still worth routing without DDC when a virtual display is up: those are dimmed
        // with an overlay, and the keys pass through untouched on displays macOS handles.
        if brightness, let level = DDCControl.brightness.get() {
            brightnessLevel = level
            routesBrightness = true
        } else {
            routesBrightness = brightness && !DisplayManager.shared.activeDisplayIDs.isEmpty
        }
        if volume, let level = DDCControl.volume.get() {
            volumeLevel = level
            routesVolume = true
        } else {
            routesVolume = false
        }

        guard routesBrightness || routesVolume else {
            stop()
            return (brightness || volume) ? Self.unreachable : nil
        }
        // The mask encodes which groups are routed, so a routing change needs a new tap.
        stop()
        guard start() else {
            routesBrightness = false
            routesVolume = false
            return "Grant Accessibility permission in System Settings › Privacy & "
                 + "Security › Accessibility, then enable this again."
        }
        return (brightness && !routesBrightness) || (volume && !routesVolume)
            ? Self.unreachable : nil
    }

    private static let unreachable =
        "No DDC-capable monitor answered. Connect it over USB-C / DisplayPort and try again."

    private func start() -> Bool {
        guard tap == nil else { return true }

        // Ask only for the event classes that are actually routed. Being handed an event
        // then means its group is routed, and a group that is off costs us nothing: with
        // brightness off, ordinary keystrokes never round-trip through this process.
        var mask: CGEventMask = 0
        if routesBrightness {
            mask |= (CGEventMask(1) << Self.keyDownRawType)
                  | (CGEventMask(1) << Self.keyUpRawType)
        }
        if routesVolume { mask |= CGEventMask(1) << Self.systemDefinedRawType }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let me = Unmanaged<MediaKeyController>.fromOpaque(userInfo!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap

        // Service the tap on its own thread. An active tap makes the window server wait
        // for our callback on every matching event, so on the main thread any menu build,
        // DDC read or modal alert would land on the user as input lag.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            tapRunLoop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun()   // returns once stop() stops this run loop
        }
        thread.name = "com.vdisplay.keytap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()   // so stop() always finds a run loop to stop
        return true
    }

    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop = tapRunLoop { CFRunLoopStop(loop) }
        tap = nil
        tapRunLoop = nil
    }

    // Runs on the tap thread. Keep it quick: the window server is blocked until it
    // returns. The levels are only touched here, the HUD hops to the main thread, and
    // the DDC write goes to its own queue.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        switch type.rawValue {
        case Self.keyDownRawType, Self.keyUpRawType:
            return handleBrightness(type: type, event: event) ? nil : pass
        case Self.systemDefinedRawType:
            return handleVolume(event: event) ? nil : pass
        default:
            return pass
        }
    }

    /// Refresh the cached display layout. Main thread, on every display change.
    func refreshLayout() {
        layout = BrightnessTarget.Layout()
    }

    /// Returns true when the event was ours and should be swallowed.
    private func handleBrightness(type: CGEventType, event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.brightnessUpKey || keyCode == Self.brightnessDownKey else {
            return false
        }
        // Act on the display the pointer is on, and hand the key back to macOS for the
        // ones it already handles - otherwise swallowing it kills their brightness keys.
        let target = layout.target(at: event.location)
        if case .system = target { return false }

        // Act on key-down (including auto-repeat while held); swallow key-up too so
        // the system never sees a dangling brightness event on the built-in panel.
        guard type.rawValue == Self.keyDownRawType else { return true }
        let delta = keyCode == Self.brightnessUpKey ? Self.step : -Self.step

        switch target {
        case .virtual(let displayID):
            // The overlay is AppKit, so it has to be touched on the main thread.
            DispatchQueue.main.async {
                let level = DisplayShade.shared.change(displayID, by: delta)
                self.hud.show(level: level, symbol: "sun.max.fill")
                var settings = SettingsStore.shared.load()
                settings.virtualBrightness = level
                SettingsStore.shared.save(settings)
            }
        case .ddc:
            brightnessLevel = max(0, min(100, brightnessLevel + delta))
            let goal = brightnessLevel
            showHUD(goal, "sun.max.fill")
            write(.brightness, goal) { [weak self] in self?.routesBrightness = false }
        case .system:
            break   // returned above
        }
        return true
    }

    private func showHUD(_ level: Int, _ symbol: String) {
        DispatchQueue.main.async { self.hud.show(level: level, symbol: symbol) }
    }

    /// DDC writes are slow (~80ms each), so they run off the tap thread, and only the
    /// newest value per feature is sent: holding a key queues one write per repeat, and
    /// applying the superseded ones would leave the monitor crawling behind the keyboard.
    ///
    /// If a write fails the monitor is gone (unplugged, asleep): give the keys back to
    /// macOS rather than swallowing them into a dead channel. The saved setting is
    /// untouched, so routing resumes at the next launch, on the next display change, or
    /// when the user re-ticks the menu item.
    private func write(_ control: DDCControl, _ value: Int, onFailure: @escaping () -> Void) {
        pendingLock.lock()
        pending[control.feature] = value
        pendingLock.unlock()

        ddcQueue.async {
            self.pendingLock.lock()
            let target = self.pending.removeValue(forKey: control.feature)
            self.pendingLock.unlock()
            guard let target else { return }          // a newer write already took this slot
            guard control.set(target) != nil else {
                self.pendingLock.lock()
                self.failures[control.feature] = 0
                self.pendingLock.unlock()
                return
            }
            // One failed write is usually a flaky DDC exchange, not a missing monitor.
            // Only hand the keys back after it keeps failing.
            self.pendingLock.lock()
            let count = (self.failures[control.feature] ?? 0) + 1
            self.failures[control.feature] = count
            self.pendingLock.unlock()
            guard count >= 3 else { return }

            DispatchQueue.main.async {
                onFailure()
                self.stop()
                // Rebuild the tap for whatever is still routed (nothing, if both failed).
                if self.routesBrightness || self.routesVolume { _ = self.start() }
            }
        }
    }

    /// Volume keys are `NSSystemDefined` subtype 8: the key code and press state
    /// are packed into `data1`. Returns true when the event should be swallowed.
    private func handleVolume(event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let keyCode = Int((ns.data1 & 0xFFFF_0000) >> 16)
        guard keyCode == Self.soundUpKey || keyCode == Self.soundDownKey
                || keyCode == Self.muteKey else { return false }

        let isDown = ((ns.data1 & 0xFF00) >> 8) == 0x0A
        guard isDown else { return true }   // swallow the key-up half too

        switch keyCode {
        case Self.muteKey:
            if let previous = mutedFrom {
                volumeLevel = previous
                mutedFrom = nil
            } else {
                mutedFrom = volumeLevel
                volumeLevel = 0
            }
        default:
            // Any level change also lifts mute, matching how macOS behaves.
            mutedFrom = nil
            let delta = keyCode == Self.soundUpKey ? Self.step : -Self.step
            volumeLevel = max(0, min(100, volumeLevel + delta))
        }
        let goal = volumeLevel
        // No DDC "get mute", so muting is just volume 0 with the old level remembered.
        showHUD(goal, goal == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        write(.volume, goal) { [weak self] in self?.routesVolume = false }
        return true
    }
}

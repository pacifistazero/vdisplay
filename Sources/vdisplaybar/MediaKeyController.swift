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
    private var runLoopSource: CFRunLoopSource?
    private let ddcQueue = DispatchQueue(label: "com.vdisplay.ddc.keys")
    // Touched only on the main thread (the tap source runs on the main run loop).
    private var brightnessLevel = 100
    private var volumeLevel = 50
    private var mutedFrom: Int?   // volume before muting, nil when not muted
    private let hud = LevelHUD()

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
        // Re-read so the first key press steps from the monitor's real value.
        if brightness, let level = DDCControl.brightness.get() {
            brightnessLevel = level
            routesBrightness = true
        } else {
            routesBrightness = false
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

        let mask = (CGEventMask(1) << Self.keyDownRawType)
                 | (CGEventMask(1) << Self.keyUpRawType)
                 | (CGEventMask(1) << Self.systemDefinedRawType)
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
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    // Runs on the main run loop (the tap source is attached there), so touching
    // the levels and the HUD is safe; only the slow DDC write is off-loaded.
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

    /// Returns true when the event was ours and should be swallowed.
    private func handleBrightness(type: CGEventType, event: CGEvent) -> Bool {
        guard routesBrightness else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.brightnessUpKey || keyCode == Self.brightnessDownKey else {
            return false
        }
        // Act on key-down (including auto-repeat while held); swallow key-up too so
        // the system never sees a dangling brightness event on the built-in panel.
        if type.rawValue == Self.keyDownRawType {
            let delta = keyCode == Self.brightnessUpKey ? Self.step : -Self.step
            brightnessLevel = max(0, min(100, brightnessLevel + delta))
            let goal = brightnessLevel
            hud.show(level: goal, symbol: "sun.max.fill")
            write(.brightness, goal) { [weak self] in self?.routesBrightness = false }
        }
        return true
    }

    /// DDC writes are slow, so they run off the main thread. If one fails the monitor
    /// is gone (unplugged, asleep): give the keys back to macOS rather than swallowing
    /// them into a dead channel. The saved setting is untouched, so it resumes at the
    /// next launch - or when the user re-ticks the menu item.
    private func write(_ control: DDCControl, _ value: Int, onFailure: @escaping () -> Void) {
        ddcQueue.async {
            guard control.set(value) != nil else { return }
            DispatchQueue.main.async {
                onFailure()
                if !self.routesBrightness && !self.routesVolume { self.stop() }
            }
        }
    }

    /// Volume keys are `NSSystemDefined` subtype 8: the key code and press state
    /// are packed into `data1`. Returns true when the event should be swallowed.
    private func handleVolume(event: CGEvent) -> Bool {
        guard routesVolume,
              let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
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
        hud.show(level: goal, symbol: goal == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        write(.volume, goal) { [weak self] in self?.routesVolume = false }
        return true
    }
}

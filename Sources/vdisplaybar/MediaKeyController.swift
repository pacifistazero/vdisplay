import Cocoa
import ApplicationServices
import VirtualDisplayKit

/// Routes the keyboard brightness keys to the external monitor's brightness over
/// DDC - MonitorControl-style.
///
/// On Apple Silicon the brightness keys are ordinary `keyDown` events (keycode
/// 144 = up / F2, 145 = down / F1), not the `NSSystemDefined` media events used
/// on Intel - so we tap at the HID level and match those keycodes. Installing an
/// active (event-swallowing) tap requires Accessibility permission. While
/// enabled the built-in HUD is suppressed and we draw our own via `BrightnessHUD`.
final class MediaKeyController {
    private static let keyDownRawType: UInt32 = 10   // kCGEventKeyDown
    private static let keyUpRawType: UInt32 = 11     // kCGEventKeyUp
    private static let brightnessUpKey: Int64 = 144  // F2
    private static let brightnessDownKey: Int64 = 145 // F1
    private static let step = 6                       // percent per key press

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let ddcQueue = DispatchQueue(label: "com.vdisplay.brightness.keys")
    private var level = 100                            // touched only on the main thread
    private let hud = BrightnessHUD()

    var isRunning: Bool { tap != nil }

    /// Whether this process has Accessibility permission. If `prompt` is true and
    /// it doesn't, macOS shows its own "grant access" dialog.
    static func hasAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Begin intercepting. Returns false if the tap couldn't be created, which
    /// almost always means Accessibility permission is missing.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        level = BrightnessController.shared.get() ?? 100

        let mask = (CGEventMask(1) << Self.keyDownRawType)
                 | (CGEventMask(1) << Self.keyUpRawType)
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
    // `level` and the HUD is safe; only the slow DDC write is off-loaded.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == Self.keyDownRawType || type.rawValue == Self.keyUpRawType else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.brightnessUpKey || keyCode == Self.brightnessDownKey else {
            return Unmanaged.passUnretained(event)
        }
        // Act on key-down (including auto-repeat while held); swallow key-up too so
        // the system never sees a dangling brightness event on the built-in panel.
        if type.rawValue == Self.keyDownRawType {
            let delta = keyCode == Self.brightnessUpKey ? Self.step : -Self.step
            level = max(0, min(100, level + delta))
            let goal = level
            hud.show(level: goal)
            ddcQueue.async { _ = BrightnessController.shared.set(goal) }
        }
        return nil // consume so the built-in display's brightness doesn't also move
    }
}

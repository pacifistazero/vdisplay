import Cocoa
import ApplicationServices
import VirtualDisplayKit

/// Intercepts the keyboard brightness keys (F1/F2) with a CGEventTap and routes
/// them to the external monitor's brightness over DDC - MonitorControl-style.
///
/// Installing an *active* (event-swallowing) tap requires Accessibility
/// permission. While enabled, the built-in brightness HUD is suppressed and we
/// draw our own via `BrightnessHUD`.
final class MediaKeyController {
    // The NSSystemDefined CGEventType has no Swift enum case; its raw value is 14.
    private static let systemDefinedRawType: UInt32 = 14
    private static let auxControlSubtype = 8          // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    private static let brightnessUp = 2               // NX_KEYTYPE_BRIGHTNESS_UP
    private static let brightnessDown = 3             // NX_KEYTYPE_BRIGHTNESS_DOWN
    private static let step = 6                        // percent per key press

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let ddcQueue = DispatchQueue(label: "com.vdisplay.brightness.keys")
    private var level = 100                             // touched only on the main thread
    private let hud = BrightnessHUD()

    var isRunning: Bool { tap != nil }

    /// Whether this process has Accessibility permission. If `prompt` is true and
    /// it doesn't, macOS shows its "grant access" dialog.
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

        let mask = CGEventMask(1) << Self.systemDefinedRawType
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let me = Unmanaged<MediaKeyController>.fromOpaque(userInfo!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
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
        guard type.rawValue == Self.systemDefinedRawType,
              let ns = NSEvent(cgEvent: event),
              Int(ns.subtype.rawValue) == Self.auxControlSubtype else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = Int((ns.data1 & 0xFFFF_0000) >> 16)
        guard keyCode == Self.brightnessUp || keyCode == Self.brightnessDown else {
            return Unmanaged.passUnretained(event)
        }
        let keyDown = ((ns.data1 & 0x0000_FF00) >> 8) == 0x0A
        if keyDown {
            let delta = keyCode == Self.brightnessUp ? Self.step : -Self.step
            level = max(0, min(100, level + delta))
            let goal = level
            hud.show(level: goal)
            ddcQueue.async { _ = BrightnessController.shared.set(goal) }
        }
        return nil // consume so the system doesn't also handle it
    }
}

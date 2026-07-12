import Foundation
import CoreGraphics
import CGVirtualDisplayShim

/// Creates and tears down virtual displays via the private CGVirtualDisplay API.
///
/// A display lives exactly as long as its `CGVirtualDisplay` object is retained,
/// so the manager keeps a strong reference for every active display and drops it
/// to remove the display.
public final class DisplayManager {
    public static let shared = DisplayManager()

    private let queue = DispatchQueue(label: "com.vdisplay.manager")
    private var active: [String: CGVirtualDisplay] = [:]
    // WindowServer rejects a second display that shares another's EDID identity,
    // so every display gets a unique serial number.
    private var nextSerial: UInt32 = 0x0001

    public init() {}

    /// Create the display for `profile`. Returns its CGDirectDisplayID, or nil on failure.
    /// If a display with the same name is already active, returns its existing id.
    @discardableResult
    public func start(_ profile: DisplayProfile) -> UInt32? {
        if let existing = active[profile.name] { return existing.displayID }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(queue)
        descriptor.name = profile.name
        descriptor.maxPixelsWide = profile.hiDPI ? profile.width * 2 : profile.width
        descriptor.maxPixelsHigh = profile.hiDPI ? profile.height * 2 : profile.height
        // Physical size drives reported DPI; ~100dpi keeps UI scaling sane.
        descriptor.sizeInMillimeters = CGSize(width: Double(profile.width) * 0.254,
                                              height: Double(profile.height) * 0.254)
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x1AB2
        descriptor.serialNum = nextSerial
        nextSerial += 1
        descriptor.terminationHandler = { _, _ in }

        let display = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = profile.hiDPI ? 1 : 0
        var modes = [CGVirtualDisplayMode(width: profile.width,
                                          height: profile.height,
                                          refreshRate: profile.refreshRate)]
        if profile.hiDPI {
            // Advertise the 2x pixel mode so macOS offers a crisp "looks like WxH".
            modes.append(CGVirtualDisplayMode(width: profile.width * 2,
                                              height: profile.height * 2,
                                              refreshRate: profile.refreshRate))
        }
        settings.modes = modes

        guard display.apply(settings) else { return nil }
        active[profile.name] = display
        return display.displayID
    }

    /// Remove the display with the given profile name. Returns false if none was active.
    @discardableResult
    public func stop(_ name: String) -> Bool {
        guard active[name] != nil else { return false }
        active.removeValue(forKey: name)
        return true
    }

    public func stopAll() {
        active.removeAll()
    }

    public func isActive(_ name: String) -> Bool {
        active[name] != nil
    }

    public var activeNames: [String] {
        Array(active.keys)
    }
}

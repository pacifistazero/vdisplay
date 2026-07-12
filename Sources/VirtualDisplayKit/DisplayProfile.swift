import Foundation

/// A saved virtual-display configuration.
public struct DisplayProfile: Codable, Equatable {
    public var name: String
    public var width: UInt32
    public var height: UInt32
    public var refreshRate: Double
    public var hiDPI: Bool
    /// Start this display automatically when the menu-bar app launches.
    public var autostart: Bool

    public init(name: String,
                width: UInt32,
                height: UInt32,
                refreshRate: Double = 60,
                hiDPI: Bool = true,
                autostart: Bool = false) {
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
        self.autostart = autostart
    }

    /// Human-readable one-liner, e.g. "1080p 16:9 — 1920×1080 @60Hz".
    public var label: String {
        let hz = refreshRate == refreshRate.rounded()
            ? String(Int(refreshRate)) : String(refreshRate)
        return "\(name) — \(width)×\(height) @\(hz)Hz"
    }

    // Tolerate older JSON that predates newer fields.
    private enum CodingKeys: String, CodingKey {
        case name, width, height, refreshRate, hiDPI, autostart
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        width = try c.decode(UInt32.self, forKey: .width)
        height = try c.decode(UInt32.self, forKey: .height)
        refreshRate = try c.decodeIfPresent(Double.self, forKey: .refreshRate) ?? 60
        hiDPI = try c.decodeIfPresent(Bool.self, forKey: .hiDPI) ?? true
        autostart = try c.decodeIfPresent(Bool.self, forKey: .autostart) ?? false
    }
}

public extension DisplayProfile {
    /// Sensible starter set, written on first run.
    static let defaults: [DisplayProfile] = [
        DisplayProfile(name: "1080p 16:9", width: 1920, height: 1080),
        DisplayProfile(name: "1440p (2K) 16:9", width: 2560, height: 1440),
        DisplayProfile(name: "4K 16:9", width: 3840, height: 2160),
        DisplayProfile(name: "Ultrawide 21:9", width: 3440, height: 1440),
    ]
}

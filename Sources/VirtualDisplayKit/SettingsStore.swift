import Foundation

/// App-wide settings persisted at ~/.config/vdisplay/settings.json.
public struct Settings: Codable, Equatable {
    /// Name of a saved layout to re-apply shortly after the menu-bar app launches
    /// (i.e. at login). `nil` disables auto-restore.
    public var startupLayout: String?

    /// Route the keyboard brightness keys to the external monitor over DDC.
    public var brightnessKeys: Bool

    /// Route the keyboard volume keys to the external monitor's speakers over DDC.
    public var volumeKeys: Bool

    /// Software brightness applied to virtual displays, 0-100 (100 = untouched). They
    /// have no backlight, so this is an overlay rather than a DDC write.
    public var virtualBrightness: Int

    public init(startupLayout: String? = nil,
                brightnessKeys: Bool = false,
                volumeKeys: Bool = false,
                virtualBrightness: Int = 100) {
        self.startupLayout = startupLayout
        self.brightnessKeys = brightnessKeys
        self.volumeKeys = volumeKeys
        self.virtualBrightness = virtualBrightness
    }

    private enum CodingKeys: String, CodingKey {
        case startupLayout, brightnessKeys, volumeKeys, virtualBrightness
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startupLayout = try c.decodeIfPresent(String.self, forKey: .startupLayout)
        brightnessKeys = try c.decodeIfPresent(Bool.self, forKey: .brightnessKeys) ?? false
        volumeKeys = try c.decodeIfPresent(Bool.self, forKey: .volumeKeys) ?? false
        virtualBrightness = try c.decodeIfPresent(Int.self, forKey: .virtualBrightness) ?? 100
    }
}

public final class SettingsStore {
    public static let shared = SettingsStore()

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vdisplay/settings.json")
    }

    public var path: String { fileURL.path }

    public func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return settings
    }

    @discardableResult
    public func save(_ settings: Settings) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

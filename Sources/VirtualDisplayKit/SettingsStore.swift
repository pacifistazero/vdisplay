import Foundation

/// App-wide settings persisted at ~/.config/vdisplay/settings.json.
public struct Settings: Codable, Equatable {
    /// Name of a saved layout to re-apply shortly after the menu-bar app launches
    /// (i.e. at login). `nil` disables auto-restore.
    public var startupLayout: String?

    public init(startupLayout: String? = nil) {
        self.startupLayout = startupLayout
    }

    private enum CodingKeys: String, CodingKey { case startupLayout }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startupLayout = try c.decodeIfPresent(String.self, forKey: .startupLayout)
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

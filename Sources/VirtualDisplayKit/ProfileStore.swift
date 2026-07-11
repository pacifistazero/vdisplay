import Foundation

/// Reads and writes the saved-profiles JSON at ~/.config/vdisplay/profiles.json.
public final class ProfileStore {
    public static let shared = ProfileStore()

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/vdisplay", isDirectory: true)
            self.fileURL = dir.appendingPathComponent("profiles.json")
        }
    }

    public var path: String { fileURL.path }

    /// Load profiles, falling back to the built-in defaults on any error.
    public func load() -> [DisplayProfile] {
        guard let data = try? Data(contentsOf: fileURL),
              let profiles = try? JSONDecoder().decode([DisplayProfile].self, from: data),
              !profiles.isEmpty else {
            return DisplayProfile.defaults
        }
        return profiles
    }

    /// Load profiles, writing the defaults to disk if the file doesn't exist yet.
    public func loadOrCreate() -> [DisplayProfile] {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            save(DisplayProfile.defaults)
            return DisplayProfile.defaults
        }
        return load()
    }

    @discardableResult
    public func save(_ profiles: [DisplayProfile]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profiles).write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

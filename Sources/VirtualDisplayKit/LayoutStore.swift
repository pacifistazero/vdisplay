import Foundation

/// Saves and restores full monitor arrangements (resolution, position, rotation,
/// primary display) by name. Uses `displayplacer` as the capture/apply engine.
///
/// Layouts are stored as the raw `displayplacer "..." "..."` command under
/// ~/.config/vdisplay/layouts/<name>.txt so they're human-readable and portable.
public final class LayoutStore {
    public static let shared = LayoutStore()

    private let dir: URL

    public init(dir: URL? = nil) {
        self.dir = dir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vdisplay/layouts", isDirectory: true)
    }

    public var path: String { dir.path }

    private func fileURL(_ name: String) -> URL {
        dir.appendingPathComponent(name).appendingPathExtension("txt")
    }

    /// Names of saved layouts, sorted.
    public func list() -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.pathExtension == "txt" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Capture the current arrangement. Returns nil on success, else an error message.
    public func save(_ name: String) -> String? {
        guard let placer = Self.displayplacerPath() else {
            return "displayplacer not found — install it with: brew install displayplacer"
        }
        let result = Self.run(placer, ["list"])
        guard let command = result.stdout
            .split(separator: "\n")
            .last(where: { $0.hasPrefix("displayplacer ") })
            .map(String.init) else {
            return "could not read the current arrangement"
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try command.write(to: fileURL(name), atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Apply a saved arrangement. Returns nil on success, else an error message.
    public func restore(_ name: String) -> String? {
        guard let placer = Self.displayplacerPath() else {
            return "displayplacer not found — install it with: brew install displayplacer"
        }
        guard let command = try? String(contentsOf: fileURL(name), encoding: .utf8) else {
            return "no saved layout named “\(name)”"
        }
        // command looks like: displayplacer "id:… res:… origin:(x,y) …" "id:… …"
        let args = Array(Self.parseQuotedArgs(
            command.trimmingCharacters(in: .whitespacesAndNewlines)).dropFirst())
        guard !args.isEmpty else { return "saved layout “\(name)” is empty" }
        let result = Self.run(placer, args)
        if result.exitCode == 0 { return nil }
        let msg = result.stderr.isEmpty ? result.stdout : result.stderr
        return msg.isEmpty ? "displayplacer exited with code \(result.exitCode)" : msg
    }

    public func delete(_ name: String) {
        try? FileManager.default.removeItem(at: fileURL(name))
    }

    // MARK: - helpers

    static func displayplacerPath() -> String? {
        let candidates = ["/opt/homebrew/bin/displayplacer", "/usr/local/bin/displayplacer"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        let which = run("/usr/bin/which", ["displayplacer"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return which.isEmpty ? nil : which
    }

    static func run(_ path: String, _ args: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return ("", "\(error)", -1) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: o, encoding: .utf8) ?? "",
                String(data: e, encoding: .utf8) ?? "",
                process.terminationStatus)
    }

    /// Split a shell-style string honoring double quotes (no escape handling needed
    /// for displayplacer's output).
    static func parseQuotedArgs(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuotes = false
        for ch in s {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == " " && !inQuotes {
                if !current.isEmpty { args.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { args.append(current) }
        return args
    }
}

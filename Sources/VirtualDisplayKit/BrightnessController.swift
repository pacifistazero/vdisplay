import Foundation

/// Controls the brightness of a physical external monitor over DDC/CI using
/// `m1ddc` as the engine. Virtual displays have no backlight, so this only
/// affects real DDC-capable panels connected to an Apple Silicon Mac.
public final class BrightnessController {
    public static let shared = BrightnessController()

    public init() {}

    /// True when the `m1ddc` engine is installed.
    public var isAvailable: Bool { Self.m1ddcPath() != nil }

    /// Current luminance (0-100), or nil if it can't be read.
    public func get() -> Int? {
        guard let m1ddc = Self.m1ddcPath() else { return nil }
        let r = Self.run(m1ddc, ["get", "luminance"])
        guard r.exitCode == 0 else { return nil }
        return Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Set luminance to `value` (clamped to 0-100). Returns nil on success,
    /// else an error message.
    @discardableResult
    public func set(_ value: Int) -> String? {
        guard let m1ddc = Self.m1ddcPath() else {
            return "m1ddc not found — install it with: brew install m1ddc"
        }
        let clamped = max(0, min(100, value))
        let r = Self.run(m1ddc, ["set", "luminance", String(clamped)])
        if r.exitCode == 0 { return nil }
        let msg = r.stderr.isEmpty ? r.stdout : r.stderr
        return msg.isEmpty ? "m1ddc exited with code \(r.exitCode)" : msg
    }

    // MARK: - helpers

    static func m1ddcPath() -> String? {
        let candidates = ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        let which = run("/usr/bin/which", ["m1ddc"]).stdout
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
}

import Foundation

/// Controls a DDC/CI feature of a physical external monitor using `m1ddc` as the
/// engine. Virtual displays have no backlight or speakers, so this only affects
/// real DDC-capable panels connected to an Apple Silicon Mac.
public final class DDCControl {
    /// Backlight brightness.
    public static let brightness = DDCControl(feature: "luminance", label: "brightness")
    /// Monitor speaker volume (the panel's own speakers, e.g. over HDMI/DP).
    public static let volume = DDCControl(feature: "volume", label: "volume")

    /// The m1ddc feature name, e.g. "luminance" or "volume".
    public let feature: String
    /// Human-readable name used in error messages.
    public let label: String

    public init(feature: String, label: String) {
        self.feature = feature
        self.label = label
    }

    /// True when the `m1ddc` engine is installed.
    public var isAvailable: Bool { Self.m1ddcPath() != nil }

    /// Current value (0-100), or nil if it can't be read.
    ///
    /// A single DDC read is not reliable - the monitor occasionally answers with nothing
    /// or with garbage - so a failed read is retried before giving up. MonitorControl does
    /// the same for the same reason; treating one flaky read as "no monitor" is how key
    /// routing ends up switching itself off while the monitor is sitting right there.
    public func get() -> Int? {
        guard let m1ddc = Self.m1ddcPath() else { return nil }
        for attempt in 0 ..< 3 {
            if attempt > 0 { usleep(40_000) }
            let r = Self.run(m1ddc, ["get", feature])
            guard r.exitCode == 0,
                  let value = Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            return value
        }
        return nil
    }

    /// Set the value (clamped to 0-100). Returns nil on success, else an error message.
    @discardableResult
    public func set(_ value: Int) -> String? {
        guard let m1ddc = Self.m1ddcPath() else {
            return "m1ddc not found — install it with: brew install m1ddc"
        }
        let clamped = max(0, min(100, value))
        let r = Self.run(m1ddc, ["set", feature, String(clamped)])
        if r.exitCode == 0 { return nil }
        let msg = r.stderr.isEmpty ? r.stdout : r.stderr
        return msg.isEmpty ? "m1ddc exited with code \(r.exitCode)" : msg
    }

    /// Nudge the value by `delta` (e.g. +10 / -10), clamped to 0-100.
    /// Returns the new value on success, else nil.
    @discardableResult
    public func change(by delta: Int) -> Int? {
        guard let current = get() else { return nil }
        let next = max(0, min(100, current + delta))
        return set(next) == nil ? next : nil
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

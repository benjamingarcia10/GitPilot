import Foundation

/// Minimal stderr logger. Run the bundled binary directly to see output:
///   ./GitPilot.app/Contents/MacOS/GitPilot
/// Or stream the app's stderr in Console.app while the bundle runs from Finder.
enum Log {
    enum Level: String { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    /// Suppress debug output by default. Set GITPILOT_DEBUG=1 in the environment
    /// (e.g., via dev.sh) to see per-enrichment timings and similar noise.
    private static let debugEnabled: Bool = {
        ProcessInfo.processInfo.environment["GITPILOT_DEBUG"] == "1"
    }()

    /// Serializes writes so concurrent enrichment tasks don't interleave mid-line.
    private static let lock = NSLock()

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func debug(_ msg: String, elapsed start: Date? = nil) {
        guard debugEnabled else { return }
        write(level: .debug, msg: msg, elapsed: start)
    }

    static func info(_ msg: String)  { write(level: .info,  msg: msg, elapsed: nil) }
    static func warn(_ msg: String)  { write(level: .warn,  msg: msg, elapsed: nil) }
    static func error(_ msg: String) { write(level: .error, msg: msg, elapsed: nil) }

    private static func write(level: Level, msg: String, elapsed start: Date?) {
        let stamp = formatter.string(from: Date())
        let line: String
        if let start {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            line = "[\(stamp)] [gitpilot] [\(level.rawValue)] \(msg) — \(ms)ms\n"
        } else {
            line = "[\(stamp)] [gitpilot] [\(level.rawValue)] \(msg)\n"
        }
        lock.lock()
        FileHandle.standardError.write(Data(line.utf8))
        lock.unlock()
    }
}

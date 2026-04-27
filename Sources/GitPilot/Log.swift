import Foundation

/// Minimal stderr logger. Run the bundled binary directly to see output:
///   ./GitPilot.app/Contents/MacOS/GitPilot
/// Or stream the app's stderr in Console.app while the bundle runs from Finder.
enum Log {
    /// Serializes writes so concurrent enrichment tasks don't interleave mid-line.
    private static let lock = NSLock()

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func debug(_ msg: String, elapsed start: Date? = nil) {
        let stamp = formatter.string(from: Date())
        let line: String
        if let start {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            line = "[\(stamp)] [gitpilot] \(msg) — \(ms)ms\n"
        } else {
            line = "[\(stamp)] [gitpilot] \(msg)\n"
        }
        lock.lock()
        FileHandle.standardError.write(Data(line.utf8))
        lock.unlock()
    }
}

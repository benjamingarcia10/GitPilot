import Foundation

/// Minimal stderr logger. Run the bundled binary directly to see output:
///   ./GitPilot.app/Contents/MacOS/GitPilot
/// Or stream the app's stderr in Console.app while the bundle runs from Finder.
enum Log {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func debug(_ msg: String, elapsed start: Date? = nil) {
        let stamp = formatter.string(from: Date())
        if let start {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            FileHandle.standardError.write(Data("[\(stamp)] [gitpilot] \(msg) — \(ms)ms\n".utf8))
        } else {
            FileHandle.standardError.write(Data("[\(stamp)] [gitpilot] \(msg)\n".utf8))
        }
    }
}

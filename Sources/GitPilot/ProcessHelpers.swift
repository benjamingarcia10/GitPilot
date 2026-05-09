import Foundation

extension Process {
    /// Augments the inherited environment with the standard Homebrew bin paths
    /// (`/opt/homebrew/bin` for Apple Silicon, `/usr/local/bin` for Intel)
    /// so subprocesses can find tools like `gh`, `cursor`, `code`, `subl`.
    ///
    /// **Why this is necessary**: GUI apps on macOS inherit a stripped-down
    /// PATH — usually just `/usr/bin:/bin:/usr/sbin:/sbin`. The user's
    /// interactive shell PATH (with Homebrew prefixes added) is not inherited
    /// unless the app was launched from a Terminal session that already had
    /// it. Sparkle's `Autoupdate` relauncher uses LaunchServices, which gives
    /// the new process the bare GUI PATH — so after a Sparkle update,
    /// `/usr/bin/env gh` produces "env: gh: No such file or directory" even
    /// though `gh` is installed and works in the user's shell.
    ///
    /// Call this *before* setting `executableURL` and `arguments`, or any
    /// time before `try run()`. It's idempotent and safe to call repeatedly.
    func useAugmentedPATH() {
        var env = ProcessInfo.processInfo.environment
        let homebrewPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
        ].joined(separator: ":")
        if let existing = env["PATH"], !existing.isEmpty {
            // Prepend so Homebrew tools win over any same-named system fallback
            // (matches the behavior of a typical `.zshrc` that adds Homebrew
            // ahead of /usr/bin). Idempotent because duplicates in PATH are
            // harmless — the shell stops at the first match.
            env["PATH"] = "\(homebrewPaths):\(existing)"
        } else {
            env["PATH"] = "\(homebrewPaths):/usr/bin:/bin:/usr/sbin:/sbin"
        }
        self.environment = env
    }
}

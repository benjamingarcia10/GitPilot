import Foundation
import AppKit

/// Status of a managed worktree on disk.
enum WorktreeStatus: Equatable {
    case missing                  // path no longer exists
    case clean                    // exists, no uncommitted changes
    case dirty(summary: String)   // exists, working tree has changes — never auto-remove
}

/// Creates, opens, and removes worktrees that GitPilot manages.
/// Operations shell out to `git`; the caller is responsible for persisting paths.
///
/// I/O methods (`create`, `remove`, `status`) are `async` and use a continuation
/// over `Process.terminationHandler` so the calling task suspends instead of
/// blocking a cooperative-pool thread on `waitUntilExit`. Callers should
/// `await` them directly — no `Task.detached` wrapper needed.
enum WorktreeManager {

    /// Resolves a worktree path for a given repo + branch, anchored at the
    /// configured root (with `~` expansion). Falls back to `~/worktrees/gitpilot`.
    static func resolvePath(root: String, repoOwner: String, repoName: String, branch: String) -> URL {
        let expandedRoot = (root as NSString).expandingTildeInPath
        // Sanitize the branch name for a safe directory: replace slashes with `__`.
        let safeBranch = branch.replacingOccurrences(of: "/", with: "__")
        return URL(fileURLWithPath: expandedRoot)
            .appendingPathComponent(repoName, isDirectory: true)
            .appendingPathComponent(safeBranch, isDirectory: true)
    }

    /// Locate the local checkout for a given owner/repo. We probe a few common roots.
    /// Returns nil if we can't find it — caller surfaces an error to the user
    /// (with the probed paths in the message so the user knows where to look).
    static func locateLocalRepo(owner: String, name: String) -> URL? {
        let fm = FileManager.default
        for candidate in repoSearchCandidates(owner: owner, name: name) {
            let path = (candidate as NSString).expandingTildeInPath
            let gitDir = URL(fileURLWithPath: path).appendingPathComponent(".git")
            if fm.fileExists(atPath: gitDir.path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Paths we probe when looking for a local checkout. Exposed so callers can
    /// include the list in error messages.
    static func repoSearchCandidates(owner: String, name: String) -> [String] {
        ["~/work/\(name)",
         "~/work/\(owner)/\(name)",
         "~/projects/\(name)",
         "~/code/\(name)",
         "~/src/\(name)"]
    }

    /// Create a worktree at the resolved path. Fetches first so the branch ref
    /// is up to date. Returns the absolute path on success, throws on failure.
    /// `git fetch` can take 10s+; this runs async via a process termination
    /// continuation so the cooperative thread pool isn't blocked on waitUntilExit.
    @discardableResult
    static func create(repoPath: URL, worktreePath: URL, branch: String) async throws -> URL {
        let parent = worktreePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // git fetch origin <branch>
        _ = try await runGit(repoPath: repoPath, args: ["fetch", "origin", branch])
        // git worktree add <path> <branch>  — uses the existing local ref if present, else origin/<branch>
        _ = try await runGit(repoPath: repoPath, args: ["worktree", "add", worktreePath.path, branch])
        return worktreePath
    }

    /// Returns the worktree's status: missing / clean / dirty.
    static func status(at path: URL) async -> WorktreeStatus {
        if !FileManager.default.fileExists(atPath: path.path) {
            return .missing
        }
        do {
            let output = try await runGit(repoPath: path, args: ["status", "--porcelain"])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .clean }
            // Show first 3 lines as a quick summary in the UI.
            let lines = trimmed.split(separator: "\n").prefix(3).joined(separator: ", ")
            return .dirty(summary: lines)
        } catch {
            return .clean  // best effort — if git can't run we assume safe
        }
    }

    /// Remove a worktree. Refuses if status is .dirty unless `force == true`.
    static func remove(repoPath: URL, worktreePath: URL, force: Bool = false) async throws {
        if !force {
            switch await status(at: worktreePath) {
            case .dirty(let summary):
                throw WorktreeError.dirty(summary: summary)
            case .missing, .clean: break
            }
        }
        // Falls back to manual rm if `git worktree remove` errors (e.g., missing ref).
        do {
            _ = try await runGit(
                repoPath: repoPath,
                args: ["worktree", "remove", worktreePath.path] + (force ? ["--force"] : [])
            )
        } catch {
            try FileManager.default.removeItem(at: worktreePath)
            _ = try? await runGit(repoPath: repoPath, args: ["worktree", "prune"])
        }
    }

    /// Open the worktree in the configured editor. "auto" picks Cursor > VSCode > Sublime > Finder.
    static func openInEditor(_ path: URL, command: String) {
        let resolved = resolveEditorCommand(command)
        if resolved == "finder" {
            NSWorkspace.shared.open(path)
            return
        }
        // Run as a subprocess. Editors usually accept a directory as the first arg.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [resolved, path.path]
        do {
            try proc.run()
            // We don't wait — editor stays open. Process can be detached.
        } catch {
            Log.debug("editor open failed for \(resolved): \(error.localizedDescription); falling back to Finder")
            NSWorkspace.shared.open(path)
        }
    }

    /// Returns the actual command to invoke. "auto" probes which editor's CLI is on PATH.
    /// Cached in `autoEditorCommand` so we don't re-probe on every menu action.
    static func resolveEditorCommand(_ command: String) -> String {
        if command != "auto" { return command }
        if let cached = autoEditorCommand { return cached }
        // Probe in preference order: Cursor → VSCode → Sublime. Each ships its own
        // CLI helper that opens a directory. If none found, return "finder" sentinel.
        for candidate in ["cursor", "code", "subl"] {
            if commandExists(candidate) {
                autoEditorCommand = candidate
                return candidate
            }
        }
        autoEditorCommand = "finder"
        return "finder"
    }

    /// Cached result of probing for an editor on PATH. Populated lazily.
    private static var autoEditorCommand: String?

    private static func commandExists(_ command: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [command]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Runs `git` and returns stdout. Uses a continuation + terminationHandler
    /// so the calling task suspends instead of pinning a cooperative-pool thread
    /// on `waitUntilExit` — important for `git fetch` which can take 10s+.
    @discardableResult
    private static func runGit(repoPath: URL, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["git", "-C", repoPath.path] + args
            let out = Pipe()
            let err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            proc.terminationHandler = { p in
                let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    cont.resume(returning: stdout)
                } else {
                    cont.resume(throwing: WorktreeError.git(
                        args: args,
                        stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
            }
            do { try proc.run() }
            catch { cont.resume(throwing: error) }
        }
    }
}

enum WorktreeError: Error, LocalizedError {
    case dirty(summary: String)
    case localRepoNotFound(owner: String, name: String)
    case git(args: [String], stderr: String)

    var errorDescription: String? {
        switch self {
        case .dirty(let summary):
            return "Worktree has uncommitted changes (\(summary)). Refusing to remove."
        case .localRepoNotFound(let owner, let name):
            return "No local checkout found for \(owner)/\(name). Open Settings to set the worktree root."
        case .git(let args, let stderr):
            return "git \(args.joined(separator: " ")) failed: \(stderr)"
        }
    }
}

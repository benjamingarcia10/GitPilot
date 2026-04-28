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
/// Not @MainActor because every method either is pure (path resolution) or
/// blocks on `Process()` — `git fetch` over the network can take 10s+, which
/// would freeze the menu UI if it ran on the main actor. Callers should
/// invoke I/O methods via `Task.detached` so the menu stays responsive.
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
    @discardableResult
    static func create(repoPath: URL, worktreePath: URL, branch: String) throws -> URL {
        let parent = worktreePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // git fetch origin <branch>
        try runGit(repoPath: repoPath, args: ["fetch", "origin", branch])
        // git worktree add <path> <branch>  — uses the existing local ref if present, else origin/<branch>
        try runGit(repoPath: repoPath, args: ["worktree", "add", worktreePath.path, branch])
        return worktreePath
    }

    /// Returns the worktree's status: missing / clean / dirty.
    static func status(at path: URL) -> WorktreeStatus {
        if !FileManager.default.fileExists(atPath: path.path) {
            return .missing
        }
        do {
            let output = try runGit(repoPath: path, args: ["status", "--porcelain"])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .clean }
            // Show first 3 lines as a quick summary in the UI.
            let lines = trimmed.split(separator: "\n").prefix(3).joined(separator: ", ")
            return .dirty(summary: lines)
        } catch {
            return .clean  // best effort — if git can't run we assume safe
        }
    }

    /// Remove a worktree. Refuses if status is .dirty. Caller should pre-check
    /// or pass force = true (only when the user has explicitly confirmed).
    static func remove(repoPath: URL, worktreePath: URL, force: Bool = false) throws {
        if !force {
            switch status(at: worktreePath) {
            case .dirty(let summary):
                throw WorktreeError.dirty(summary: summary)
            case .missing, .clean: break
            }
        }
        // git -C <repo> worktree remove <path>
        // Falls back to manual rm if `git worktree remove` errors (e.g., missing ref).
        do {
            try runGit(repoPath: repoPath, args: ["worktree", "remove", worktreePath.path] + (force ? ["--force"] : []))
        } catch {
            // Fallback: remove the dir directly + prune
            try FileManager.default.removeItem(at: worktreePath)
            _ = try? runGit(repoPath: repoPath, args: ["worktree", "prune"])
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

    @discardableResult
    private static func runGit(repoPath: URL, args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "-C", repoPath.path] + args
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            throw WorktreeError.git(args: args, stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
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

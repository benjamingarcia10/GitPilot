import Foundation

/// User-tunable settings, persisted to disk. All defaults match the previous
/// hard-coded behavior so existing users see no change after the upgrade.
/// One row in the activity timeline. Recorded as state transitions occur and as
/// the user takes actions; capped to keep the persisted file small.
struct ActivityEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case becameBehind        // PR transitioned to BEHIND
        case becameReady         // PR transitioned to CLEAN + APPROVED
        case becameTestsFailing  // PR transitioned to blockedByTests
        case becameConflicts     // PR transitioned to merge conflict
        case rebased             // user-initiated rebase succeeded
        case rebaseFailed        // user-initiated rebase failed
        case autoRebased         // auto-rebase succeeded
        case autoRebaseFailed    // auto-rebase mutation failed
        case merged              // client-side merge succeeded
        case autoMergeFailed     // auto-merge mutation or precondition failed
        case worktreeCreateFailed
        case worktreeRemoveFailed
        case pinned
        case unpinned
        case snoozed
        case unsnoozed
        case autoMergeEnabled
        case autoMergeDisabled
        case appeared            // PR first seen (entered the list)
        case disappeared         // PR no longer in the list (closed/merged elsewhere)
    }
    let id: UUID
    let timestamp: Date
    let prId: String
    let prNumber: Int
    let prTitle: String
    let kind: Kind
    let detail: String?  // optional extra context (e.g. error message on autoRebaseFailed)
}

/// Caps for the activity log. Surfaced in the Activity tab footer so users know
/// how far back the history goes.
enum ActivityRetention {
    static let maxEntries = 200
    static let maxAgeDays = 7
}

/// User-pickable sort orders for the PR list. Persisted across launches.
/// Pinned PRs always sort to the top regardless of this choice.
enum PRSortOption: String, Codable, CaseIterable {
    case updated         // GitHub default: most-recently-updated first
    case prNumberDesc    // newest PR first (within each repo)
    case prNumberAsc     // oldest PR first (within each repo)
    case titleAlpha      // title A→Z
    case statusPriority  // actionable items first

    var label: String {
        switch self {
        case .updated:        return "Updated"
        case .prNumberDesc:   return "PR # (newest)"
        case .prNumberAsc:    return "PR # (oldest)"
        case .titleAlpha:     return "Title (A–Z)"
        case .statusPriority: return "Status priority"
        }
    }
}

struct PersistedSettings: Codable, Equatable {
    var pollIntervalSeconds: Double = 30
    var enableRebaseNotification: Bool = true
    var enableReadyNotification: Bool = true
    var enableTestsFailingNotification: Bool = true
    var enableAutoRebaseFailureNotification: Bool = true
    /// Auto-merge failure has its own toggle so it can be muted independently of
    /// auto-rebase failure. Default on — failures here are usually actionable.
    var enableAutoMergeFailureNotification: Bool = true
    /// Opt-in success notification when auto-merge completes. Default off; the
    /// activity log already records every merge and the point of "auto" is to
    /// disappear. Useful for users who specifically want closure.
    var enableAutoMergeCompletedNotification: Bool = false
    /// Notify when a manual (button-click) rebase fails. Default off — when you
    /// click Rebase, the inline button gives you contextual feedback. Opt in if
    /// you tend to walk away after clicking.
    var enableManualRebaseFailureNotification: Bool = false
    /// Notify when a worktree create or remove fails. Default on — these failures
    /// usually mean real work is blocked (no local checkout, dirty worktree, etc.).
    var enableWorktreeFailureNotification: Bool = true
    /// Notify when a PR transitions to merge conflict. Default on — conflicts are
    /// actionable and require dropping into a local worktree to resolve.
    var enableConflictsNotification: Bool = true
    var defaultRepoFilter: String? = nil
    var sortOrder: PRSortOption = .updated
    /// Root directory for worktrees this app creates. Default expands to
    /// `~/worktrees/gitpilot`; per-PR worktrees go under <root>/<repo>/<branch>.
    var worktreeRoot: String = "~/worktrees/gitpilot"
    /// Preferred editor command. "auto" detects Cursor first, then VSCode, then falls back.
    var editorCommand: String = "auto"  // "auto" | "code" | "cursor" | "subl" | etc.

    init() {}

    /// Custom decoder that tolerates missing keys by falling back to property
    /// defaults. Without this, adding a new field would force every existing
    /// state.json to fail decoding (Swift's synthesized `init(from:)` does not
    /// consult property initializers), and the `PersistenceStore` catch block
    /// would then reset the user's pinned/snooze/etc. state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = try c.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds) { pollIntervalSeconds = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .enableRebaseNotification) { enableRebaseNotification = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .enableReadyNotification) { enableReadyNotification = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .enableTestsFailingNotification) { enableTestsFailingNotification = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .enableAutoRebaseFailureNotification) { enableAutoRebaseFailureNotification = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .enableAutoMergeFailureNotification) { enableAutoMergeFailureNotification = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .enableAutoMergeCompletedNotification) { enableAutoMergeCompletedNotification = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .enableManualRebaseFailureNotification) { enableManualRebaseFailureNotification = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .enableWorktreeFailureNotification) { enableWorktreeFailureNotification = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .enableConflictsNotification) { enableConflictsNotification = v }
        defaultRepoFilter = try c.decodeIfPresent(String.self, forKey: .defaultRepoFilter)
        if let v = try c.decodeIfPresent(PRSortOption.self, forKey: .sortOrder) { sortOrder = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .worktreeRoot) { worktreeRoot = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .editorCommand) { editorCommand = v }
    }
}

/// Single source of truth for everything we keep across launches:
///   - dedupe sets so app restart doesn't re-notify every behind/ready PR
///   - snooze map: PR id → snooze-until date
///   - pin set: PRs the user is actively focused on
///   - autoRebase set: PRs to rebase silently on transition to BEHIND
///   - user settings
///
/// Schema is versioned so future-incompatible changes can reset cleanly
/// instead of crashing on a stale file.
struct PersistedState: Codable, Equatable {
    var schemaVersion: Int = 1
    var notifiedNeedsUpdate: Set<String> = []
    var notifiedReadyToMerge: Set<String> = []
    var notifiedBlockedByTests: Set<String> = []
    var notifiedConflicts: Set<String> = []
    var snoozedUntil: [String: Date] = [:]
    var pinned: Set<String> = []
    var autoRebase: Set<String> = []
    /// PRs the user has opted into GitHub-native auto-merge for. Membership maps
    /// directly to the GitHub `enablePullRequestAutoMerge` mutation having been
    /// called for that PR.
    var autoMerge: Set<String> = []
    /// Per-repo merge method override, keyed by "owner/repo". Used by auto-merge
    /// when set; otherwise the global `settings.autoMergeMethod` default applies
    /// (with a fallback to whatever's allowed if neither matches the repo's settings).
    var perRepoMergeMethod: [String: String] = [:]  // value: "MERGE" / "SQUASH" / "REBASE"
    /// Worktrees this app created and is responsible for cleaning up. Keyed by PR id;
    /// value is the absolute worktree path on disk.
    var worktrees: [String: String] = [:]
    /// Activity timeline (newest last). Trimmed on every write to honor ActivityRetention.
    var activity: [ActivityEvent] = []
    /// User's explicit choice to filter to pinned only. Survives across launches.
    /// Only honored when `pinned` is non-empty (UI hides the toggle otherwise).
    var showPinnedOnly: Bool = false
    var settings: PersistedSettings = PersistedSettings()

    init() {}

    /// Custom decoder mirrors `PersistedSettings`: every field decodes via
    /// `decodeIfPresent` so adding a new field doesn't fail the whole file
    /// and reset everything in the catch block. The schemaVersion check still
    /// runs in `PersistenceStore.load` for breaking schema changes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) { schemaVersion = v }
        if let v = try c.decodeIfPresent(Set<String>.self, forKey: .notifiedNeedsUpdate) { notifiedNeedsUpdate = v }
        if let v = try c.decodeIfPresent(Set<String>.self, forKey: .notifiedReadyToMerge) { notifiedReadyToMerge = v }
        if let v = try c.decodeIfPresent(Set<String>.self, forKey: .notifiedBlockedByTests) { notifiedBlockedByTests = v }
        if let v = try c.decodeIfPresent(Set<String>.self, forKey: .notifiedConflicts) { notifiedConflicts = v }
        if let v = try c.decodeIfPresent([String: Date].self, forKey: .snoozedUntil) { snoozedUntil = v }
        if let v = try c.decodeIfPresent(Set<String>.self, forKey: .pinned) { pinned = v }
        if let v = try c.decodeIfPresent(Set<String>.self, forKey: .autoRebase) { autoRebase = v }
        if let v = try c.decodeIfPresent(Set<String>.self, forKey: .autoMerge) { autoMerge = v }
        if let v = try c.decodeIfPresent([String: String].self, forKey: .perRepoMergeMethod) { perRepoMergeMethod = v }
        if let v = try c.decodeIfPresent([String: String].self, forKey: .worktrees) { worktrees = v }
        if let v = try c.decodeIfPresent([ActivityEvent].self, forKey: .activity) { activity = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .showPinnedOnly) { showPinnedOnly = v }
        if let v = try c.decodeIfPresent(PersistedSettings.self, forKey: .settings) { settings = v }
    }
}

/// Loads/saves PersistedState from `~/Library/Application Support/GitPilot/state.json`.
/// Atomic writes; corrupt or schema-mismatched files reset to defaults.
enum PersistenceStore {
    static let fileURL: URL = {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true))
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("GitPilot", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    static func load() -> PersistedState {
        guard let data = try? Data(contentsOf: fileURL) else {
            Log.debug("persistence: no file at \(fileURL.path), starting fresh")
            return PersistedState()
        }
        do {
            let decoder = JSONDecoder()
            let state = try decoder.decode(PersistedState.self, from: data)
            if state.schemaVersion != 1 {
                Log.debug("persistence: schema \(state.schemaVersion) != 1, resetting")
                return PersistedState()
            }
            Log.debug("persistence: loaded from \(fileURL.path)")
            return state
        } catch {
            Log.debug("persistence: decode failed (\(error)), starting fresh")
            return PersistedState()
        }
    }

    /// Returns nil on success, an error message on failure. Caller surfaces the
    /// message in the UI so a save problem (full disk, permissions, etc.) doesn't
    /// silently lose the user's pinned/snooze/etc. state.
    @discardableResult
    static func save(_ state: PersistedState) -> String? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
            return nil
        } catch {
            // warn level so it's visible without GITPILOT_DEBUG=1.
            Log.warn("persistence: save failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}

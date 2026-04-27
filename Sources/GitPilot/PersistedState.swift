import Foundation

/// User-tunable settings, persisted to disk. All defaults match the previous
/// hard-coded behavior so existing users see no change after the upgrade.
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
    var defaultRepoFilter: String? = nil
    var sortOrder: PRSortOption = .updated
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
    /// User's explicit choice to filter to pinned only. Survives across launches.
    /// Only honored when `pinned` is non-empty (UI hides the toggle otherwise).
    var showPinnedOnly: Bool = false
    var settings: PersistedSettings = PersistedSettings()
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

    static func save(_ state: PersistedState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.debug("persistence: save failed: \(error)")
        }
    }
}

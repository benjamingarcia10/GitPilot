import Foundation

/// Whether we have working GitHub credentials.
/// `unknown` is the bootstrap state before the first auth check completes.
enum AuthStatus: Equatable {
    case unknown
    case authenticated(login: String)
    case needsReauth(reason: String)
}

/// Status of a single CI check or status context on a PR.
enum CheckState: String, Codable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case pending = "PENDING"
    case error = "ERROR"
    case unknown
}

/// GitHub's mergeStateStatus values that we care about.
/// See: https://docs.github.com/en/graphql/reference/enums#mergestatestatus
enum MergeStateStatus: String, Codable {
    case clean = "CLEAN"             // Ready to merge: green, approved, up to date.
    case blocked = "BLOCKED"         // Failing checks, missing review, or out of date.
    case behind = "BEHIND"           // Out of date with base branch.
    case unstable = "UNSTABLE"       // Mergeable but non-required checks failing.
    case dirty = "DIRTY"             // Merge conflicts.
    case hasHooks = "HAS_HOOKS"      // Mergeable, passing hooks.
    case unknown = "UNKNOWN"
}

struct PullRequest: Codable, Identifiable, Equatable {
    let nodeId: String              // GraphQL node ID, used for updatePullRequestBranch.
    let number: Int
    let title: String
    let url: URL
    let headRefName: String
    let baseRefName: String
    let isDraft: Bool
    let repoOwner: String
    let repoName: String

    // Filled in by the enrichment phase. Nil while loading so the row can render
    // immediately with a placeholder status icon.
    var mergeable: String?           // "MERGEABLE" | "CONFLICTING" | "UNKNOWN"
    var mergeStateStatus: MergeStateStatus?
    var reviewDecision: String?      // "APPROVED" | "REVIEW_REQUIRED" | "CHANGES_REQUESTED" | nil

    var id: String { "\(repoOwner)/\(repoName)#\(number)" }

    var isLoading: Bool { mergeStateStatus == nil }

    /// Whether the PR is in the narrow window where you can merge: green, approved, up to date.
    var isReadyToMerge: Bool {
        mergeStateStatus == .clean && reviewDecision == "APPROVED" && !isDraft
    }

    /// Whether the PR is behind base and a one-click update would unblock it.
    var needsBranchUpdate: Bool {
        mergeStateStatus == .behind || mergeStateStatus == .blocked
    }
}

/// Slow-to-compute fields fetched per-PR in the enrichment phase.
struct PREnrichment: Equatable {
    let mergeable: String
    let mergeStateStatus: MergeStateStatus
    let reviewDecision: String?
}

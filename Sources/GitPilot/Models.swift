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

/// Rollup of all check runs and status contexts on a PR's HEAD commit.
/// Returned by GitHub's GraphQL `statusCheckRollup.state`. Lets us tell why a PR
/// is blocked: failing tests vs. missing review vs. something else.
enum CheckRollupState: String, Codable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case pending = "PENDING"
    case error = "ERROR"
    case expected = "EXPECTED"
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

/// How a PR ended up in your "Reviewing" tab — directly assigned, or via team membership.
/// Carried so the row can show the user *why* it's there.
struct ReviewerSource: Codable, Equatable, Hashable {
    enum Kind: String, Codable { case direct, team }
    let kind: Kind
    let teamSlug: String?  // populated when kind == .team
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

    /// Diff size — surfaced inline on the row so you can size up a PR at a glance.
    var additions: Int = 0
    var deletions: Int = 0
    var changedFiles: Int = 0

    /// Populated only on PRs in the "Reviewing" tab. Empty otherwise. Multiple
    /// entries possible: direct request + several team requests.
    var reviewerSources: [ReviewerSource] = []

    // Filled in by the enrichment phase. Nil while loading so the row can render
    // immediately with a placeholder status icon.
    var mergeable: String?           // "MERGEABLE" | "CONFLICTING" | "UNKNOWN"
    var mergeStateStatus: MergeStateStatus?
    var reviewDecision: String?      // "APPROVED" | "REVIEW_REQUIRED" | "CHANGES_REQUESTED" | nil
    var checkRollupState: CheckRollupState?  // SUCCESS / FAILURE / PENDING / ERROR / EXPECTED
    var checks: [PRCheck] = []       // individual check rows, surfaced when the PR is expanded
    /// Merge methods this PR's repo allows. Populated from phase-1 query so we know
    /// which methods are valid before attempting auto-merge.
    var allowedMergeMethods: Set<String> = []  // "MERGE" / "SQUASH" / "REBASE"

    var id: String { "\(repoOwner)/\(repoName)#\(number)" }

    var isLoading: Bool { mergeStateStatus == nil }

    /// Whether the PR is in the narrow window where you can merge: green, approved, up to date.
    var isReadyToMerge: Bool {
        mergeStateStatus == .clean && reviewDecision == "APPROVED" && !isDraft
    }

    /// Strictly out-of-date with base. A rebase will help.
    /// Note: GitHub's BLOCKED state does NOT imply "behind" — it can mean failing
    /// checks, missing reviews, or missing required status. Rebasing won't fix
    /// those, so we don't include BLOCKED here.
    var needsBranchUpdate: Bool {
        mergeStateStatus == .behind
    }

    /// Mergeable in principle but stopped by failing checks, missing reviews, or
    /// other branch protection. User can't fix from this app — surfaces as info only.
    var isBlocked: Bool {
        mergeStateStatus == .blocked
    }

    /// Has merge conflicts. Requires manual resolution in a local checkout.
    var hasConflicts: Bool {
        mergeStateStatus == .dirty
    }
}

/// One-of representation used by the UI to pick icons, colors, and which buttons to show.
/// Blocked is split by reason so the UI can tell the user *why* it's stuck.
enum PRDisplayState {
    case loading
    case readyToMerge
    case behind
    case blockedByTests        // failing CI checks
    case blockedByReview       // approval missing or changes requested
    case blockedTestsRunning   // CI in flight, not yet failed
    case blocked               // some other branch-protection reason
    case conflicts
    case draft
    case other
}

extension PullRequest {
    var displayState: PRDisplayState {
        if isLoading { return .loading }
        if isReadyToMerge { return .readyToMerge }
        if hasConflicts { return .conflicts }
        if needsBranchUpdate { return .behind }
        if isBlocked {
            // Most actionable reason wins.
            if checkRollupState == .failure || checkRollupState == .error {
                return .blockedByTests
            }
            if reviewDecision == "REVIEW_REQUIRED" || reviewDecision == "CHANGES_REQUESTED" {
                return .blockedByReview
            }
            if checkRollupState == .pending || checkRollupState == .expected {
                return .blockedTestsRunning
            }
            return .blocked
        }
        if isDraft { return .draft }
        return .other
    }
}

/// One row in the inline-expanded check list. CI-provider-agnostic — the URL points
/// at whatever ran the check (Buildkite, GitHub Actions, CircleCI, etc.).
struct PRCheck: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    let state: CheckRollupState
    let url: URL?
}

/// Slow-to-compute fields fetched per-PR in the enrichment phase.
struct PREnrichment: Equatable {
    let mergeable: String
    let mergeStateStatus: MergeStateStatus
    let reviewDecision: String?
    let checkRollupState: CheckRollupState
    let checks: [PRCheck]
}

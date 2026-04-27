import Foundation

/// Distinct events the monitor emits when a PR's state crosses a threshold.
enum PRTransition {
    case needsBranchUpdate(PullRequest)   // PR has fallen behind base.
    case readyToMerge(PullRequest)        // PR has entered the merge window.
}

/// Polls GitHub on an interval, diffs state, and emits transition events.
/// Edge-triggered: emits only on state change so we don't spam notifications.
@MainActor
final class PRMonitor: ObservableObject {
    @Published private(set) var prs: [PullRequest] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefresh: Date?

    /// Set of PR ids we've already notified for each transition kind, so we don't re-fire
    /// on every poll while the PR sits in that state. Cleared when the PR leaves the state.
    private var notifiedNeedsUpdate: Set<String> = []
    private var notifiedReadyToMerge: Set<String> = []

    private let client: GitHubClient
    private let pollInterval: TimeInterval
    private var task: Task<Void, Never>?

    /// Set by AppState after construction so the closure can reference `self`.
    var onTransition: (PRTransition) async -> Void = { _ in }

    /// Called when refresh hits an auth error. AppState uses this to flip authStatus
    /// and stop the loop so we don't hammer GitHub with a stale token.
    var onAuthError: (String) -> Void = { _ in }

    init(client: GitHubClient, pollInterval: TimeInterval = 30) {
        self.client = client
        self.pollInterval = pollInterval
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Fetch PRs once and emit transitions for any that crossed a threshold since last refresh.
    func refresh() async {
        do {
            let fresh = try await client.fetchMyOpenPRs()

            for pr in fresh {
                if pr.needsBranchUpdate {
                    if !notifiedNeedsUpdate.contains(pr.id) {
                        notifiedNeedsUpdate.insert(pr.id)
                        await onTransition(.needsBranchUpdate(pr))
                    }
                } else {
                    notifiedNeedsUpdate.remove(pr.id)
                }

                if pr.isReadyToMerge {
                    if !notifiedReadyToMerge.contains(pr.id) {
                        notifiedReadyToMerge.insert(pr.id)
                        await onTransition(.readyToMerge(pr))
                    }
                } else {
                    notifiedReadyToMerge.remove(pr.id)
                }
            }

            // Drop notification state for PRs that are no longer in the list (closed/merged).
            let liveIds = Set(fresh.map { $0.id })
            notifiedNeedsUpdate.formIntersection(liveIds)
            notifiedReadyToMerge.formIntersection(liveIds)

            prs = fresh
            lastError = nil
            lastRefresh = Date()
        } catch let err as GitHubClientError where err.isAuthError {
            // Don't keep polling with bad creds; AppState will surface a banner.
            stop()
            onAuthError(err.localizedDescription)
        } catch {
            lastError = error.localizedDescription
        }
    }
}

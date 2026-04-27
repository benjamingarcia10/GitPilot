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
        // No-op if already running — protects against menu-open re-bootstrap kicking off duplicate fetches.
        if let existing = task, !existing.isCancelled { return }
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

    /// Two-phase refresh:
    ///   1. Fetch the list and publish immediately so the UI shows rows right away.
    ///   2. Enrich each PR in parallel; apply each result as it arrives.
    /// Transitions are evaluated in phase 2, after a PR has its merge state.
    func refresh() async {
        let refreshStart = Date()
        Log.debug("refresh start")
        do {
            let lightPRs = try await client.fetchMyOpenPRs()
            Log.debug("phase1 returned \(lightPRs.count) PRs", elapsed: refreshStart)

            // Preserve enrichment from the previous snapshot for any PR we still see —
            // avoids spinner flicker on PRs whose state hasn't changed.
            let previousById = Dictionary(uniqueKeysWithValues: prs.map { ($0.id, $0) })
            prs = lightPRs.map { fresh in
                guard let prev = previousById[fresh.id] else { return fresh }
                var merged = fresh
                merged.mergeable = prev.mergeable
                merged.mergeStateStatus = prev.mergeStateStatus
                merged.reviewDecision = prev.reviewDecision
                return merged
            }
            lastError = nil
            lastRefresh = Date()

            // Drop notification state for PRs that are no longer in the list.
            let liveIds = Set(lightPRs.map { $0.id })
            notifiedNeedsUpdate.formIntersection(liveIds)
            notifiedReadyToMerge.formIntersection(liveIds)

            // Enrich in parallel. Each task awaits one cheap GraphQL call and updates one row.
            let enrichStart = Date()
            await withTaskGroup(of: Void.self) { group in
                for pr in lightPRs {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            let enrichment = try await self.client.enrichPR(nodeId: pr.nodeId)
                            await self.applyEnrichment(prId: pr.id, enrichment: enrichment)
                        } catch let err as GitHubClientError where err.isAuthError {
                            await self.handleAuthError(err.localizedDescription)
                        } catch {
                            // Non-auth enrichment failures: leave the row in loading state.
                            // A future refresh will retry.
                        }
                    }
                }
            }
            Log.debug("phase2 enrichment complete", elapsed: enrichStart)
            Log.debug("refresh total", elapsed: refreshStart)
        } catch let err as GitHubClientError where err.isAuthError {
            stop()
            onAuthError(err.localizedDescription)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Apply an enrichment result to the matching PR and re-evaluate its transitions.
    private func applyEnrichment(prId: String, enrichment: PREnrichment) async {
        guard let idx = prs.firstIndex(where: { $0.id == prId }) else { return }
        var pr = prs[idx]
        pr.mergeable = enrichment.mergeable
        pr.mergeStateStatus = enrichment.mergeStateStatus
        pr.reviewDecision = enrichment.reviewDecision
        prs[idx] = pr

        // Edge-triggered transition checks for just this PR.
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

    private func handleAuthError(_ reason: String) {
        stop()
        onAuthError(reason)
    }
}

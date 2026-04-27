import Foundation

/// Polls GitHub on an interval and exposes the current PR snapshot.
/// Pure fetcher: no dedupe, no snooze, no pin logic. AppState owns those —
/// PRMonitor just emits per-PR enrichment events and post-refresh list snapshots.
@MainActor
final class PRMonitor: ObservableObject {
    @Published private(set) var prs: [PullRequest] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefresh: Date?
    /// True while a refresh is in flight (covers both phases). Drives the spinner
    /// in the menu and disables the refresh button to prevent spam-clicking.
    @Published private(set) var isRefreshing: Bool = false

    private let client: GitHubClient
    private(set) var pollInterval: TimeInterval
    private var task: Task<Void, Never>?

    /// Called immediately before each refresh starts. AppState uses this to clear
    /// expired snoozes so the upcoming pass treats those PRs as fresh.
    var willRefresh: () -> Void = {}

    /// Called after each per-PR enrichment is applied. AppState computes transitions,
    /// fires notifications, and runs auto-rebase logic in this callback.
    var onPRUpdated: (PullRequest) async -> Void = { _ in }

    /// Called once after a refresh completes, with the set of currently-live PR ids.
    /// AppState uses this to drop dedupe entries for PRs that closed/merged.
    var onListSettled: (Set<String>) -> Void = { _ in }

    init(client: GitHubClient, pollInterval: TimeInterval = 30) {
        self.client = client
        self.pollInterval = pollInterval
    }

    func setPollInterval(_ interval: TimeInterval) {
        pollInterval = interval
    }

    func start() {
        // No-op if already running — guards menu-open re-bootstrap from kicking off duplicate fetches.
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
    /// AppState's onPRUpdated callback runs after each apply, which is where
    /// transition / notification / auto-rebase decisions are made.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        willRefresh()

        let refreshStart = Date()
        Log.debug("refresh start")
        do {
            let lightPRs = try await client.fetchMyOpenPRs()
            Log.debug("phase1 returned \(lightPRs.count) PRs", elapsed: refreshStart)

            // Carry enrichment from the previous snapshot so rows don't flash to "loading".
            let previousById = Dictionary(uniqueKeysWithValues: prs.map { ($0.id, $0) })
            prs = lightPRs.map { fresh in
                guard let prev = previousById[fresh.id] else { return fresh }
                var merged = fresh
                merged.mergeable = prev.mergeable
                merged.mergeStateStatus = prev.mergeStateStatus
                merged.reviewDecision = prev.reviewDecision
                merged.checkRollupState = prev.checkRollupState
                merged.checks = prev.checks
                // allowedMergeMethods comes from the fresh phase-1 query, no carry-forward needed.
                return merged
            }
            lastError = nil
            lastRefresh = Date()

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

            // Post-refresh: tell AppState which ids are still live so it can clean dedupe sets.
            onListSettled(Set(lightPRs.map { $0.id }))
        } catch let err as GitHubClientError where err.isAuthError {
            stop()
            onAuthError(err.localizedDescription)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Apply an enrichment result to the matching PR, then notify AppState.
    private func applyEnrichment(prId: String, enrichment: PREnrichment) async {
        guard let idx = prs.firstIndex(where: { $0.id == prId }) else { return }
        var pr = prs[idx]
        pr.mergeable = enrichment.mergeable
        pr.mergeStateStatus = enrichment.mergeStateStatus
        pr.reviewDecision = enrichment.reviewDecision
        pr.checkRollupState = enrichment.checkRollupState
        pr.checks = enrichment.checks
        prs[idx] = pr
        await onPRUpdated(pr)
    }

    // MARK: - Auth error plumbing

    /// Set by AppState; flips authStatus and stops the loop on 401.
    var onAuthError: (String) -> Void = { _ in }

    private func handleAuthError(_ reason: String) {
        stop()
        onAuthError(reason)
    }
}

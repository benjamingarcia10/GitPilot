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
    /// Count of per-PR enrichment failures from the last refresh. Used to tooltip
    /// the refresh button so the user knows why some rows stay in "loading…".
    @Published private(set) var enrichmentFailureCount: Int = 0

    private let client: GitHubClient
    private(set) var pollInterval: TimeInterval
    private var task: Task<Void, Never>?
    /// Explicit running flag. Task.isCancelled isn't enough on its own —
    /// a finished-and-returned task is "not cancelled" but also not running,
    /// so checking that alone would let `start()` no-op when it shouldn't.
    private var isRunning = false
    /// Set when a refresh is requested while one is already in flight. After
    /// the in-flight refresh completes, we fire one more refresh to honor it.
    /// Solves the auto-rebase deadlock where `runAutoRebase` was awaiting
    /// inside the enrichment loop and then calling `monitor.refresh()`, which
    /// always hit the `isRefreshing` guard and no-op'd — leaving the user
    /// waiting until the next poll tick to see post-rebase state.
    private var pendingRefresh = false

    /// Called immediately before each refresh starts. AppState uses this to clear
    /// expired snoozes so the upcoming pass treats those PRs as fresh.
    /// Typed as @MainActor so the actor contract is part of the type — making
    /// it impossible to accidentally call from a background context.
    var willRefresh: @MainActor () -> Void = {}

    /// Called after each per-PR enrichment is applied. AppState computes transitions,
    /// fires notifications, and runs auto-rebase logic in this callback.
    var onPRUpdated: @MainActor (PullRequest) async -> Void = { _ in }

    /// Called once after a refresh completes, with the set of currently-live PR ids.
    /// AppState uses this to drop dedupe entries for PRs that closed/merged.
    var onListSettled: @MainActor (Set<String>) -> Void = { _ in }

    init(client: GitHubClient, pollInterval: TimeInterval = 30) {
        self.client = client
        self.pollInterval = pollInterval
    }

    func setPollInterval(_ interval: TimeInterval) {
        pollInterval = interval
    }

    func start() {
        // No-op if already running — guards menu-open re-bootstrap from kicking off duplicate fetches.
        if isRunning { return }
        isRunning = true
        task = Task { [weak self] in
            defer { Task { @MainActor in self?.isRunning = false } }
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
        isRunning = false
    }

    /// Schedules a refresh. If one is already in flight, sets a pending flag
    /// that fires another refresh as soon as the current one finishes — the
    /// only safe way to "refresh after this rebase" from inside the enrichment
    /// loop, where `await refresh()` would deadlock against its own guard.
    /// Idempotent: multiple requests during one refresh coalesce to a single
    /// follow-up refresh.
    func requestRefresh() {
        if isRefreshing {
            pendingRefresh = true
            return
        }
        Task { await self.refresh() }
    }

    /// Two-phase refresh:
    ///   1. Fetch the list and publish immediately so the UI shows rows right away.
    ///   2. Enrich each PR in parallel; apply each result as it arrives.
    /// AppState's onPRUpdated callback runs after each apply, which is where
    /// transition / notification / auto-rebase decisions are made.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await performRefresh()
        isRefreshing = false
        // Honor any refresh request that came in while we were running. Fired
        // as a Task so we don't recurse synchronously and so callers further
        // up the stack get to unwind first. Coalesces — a pending flag means
        // "one more refresh," not "one per requestRefresh() call."
        if pendingRefresh {
            pendingRefresh = false
            Task { await self.refresh() }
        }
    }

    /// Body of refresh — extracted so `refresh()` can wrap it with epilogue
    /// logic that runs even when this returns early (auth error, cancellation).
    private func performRefresh() async {
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
                merged.carryForwardEnrichment(from: prev)
                // allowedMergeMethods comes from the fresh phase-1 query, no carry-forward needed.
                return merged
            }
            lastError = nil
            lastRefresh = Date()

            // Batched enrichment: one GraphQL call (chunked to 25 if needed)
            // replaces the per-PR fan-out that was the dominant source of API
            // call volume and the cause of secondary rate-limit trips. Auth
            // errors surface once at the call site; partial failures show up as
            // missing keys in the result map.
            let enrichStart = Date()
            var failureCount = 0
            do {
                try Task.checkCancellation()
                let enrichments = try await client.enrichPRs(nodeIds: lightPRs.map { $0.nodeId })
                for pr in lightPRs {
                    if Task.isCancelled { break }
                    if let e = enrichments[pr.nodeId] {
                        await applyEnrichment(prId: pr.id, enrichment: e)
                    } else {
                        failureCount += 1
                    }
                }
            } catch let err as GitHubClientError where err.isAuthError {
                handleAuthError(err.localizedDescription)
                return
            } catch is CancellationError {
                return
            } catch {
                // Whole-batch failure: every row stays in loading. Surface count
                // so the refresh-button tooltip reflects it.
                failureCount = lightPRs.count
            }
            enrichmentFailureCount = failureCount
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
        pr.apply(enrichment)
        prs[idx] = pr
        await onPRUpdated(pr)
    }

    // MARK: - Auth error plumbing

    /// Set by AppState; flips authStatus and stops the loop on 401.
    var onAuthError: @MainActor (String) -> Void = { _ in }

    private func handleAuthError(_ reason: String) {
        stop()
        onAuthError(reason)
    }
}

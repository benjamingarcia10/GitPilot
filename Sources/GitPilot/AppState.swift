import Foundation
import AppKit

/// Single owner of all UX policy: transition detection, dedupe, snooze, pin,
/// auto-rebase, settings, persistence. PRMonitor is a pure fetcher; this glues
/// everything together.
@MainActor
final class AppState: ObservableObject {
    let client: GitHubClient
    let monitor: PRMonitor
    private(set) var notifications: NotificationService!

    /// Drives the auth banner in the menu UI.
    @Published var authStatus: AuthStatus = .unknown

    /// Selected repo filter for the menu. `nil` means "All".
    @Published var repoFilter: String? = nil

    /// Free-text search applied to PR title, number, repo, branch.
    @Published var searchText: String = ""

    /// When true, searchText is interpreted as a regex (case-insensitive).
    @Published var useRegex: Bool = false

    /// PR ids whose rebase is currently in flight.
    @Published private(set) var rebaseInFlight: Set<String> = []

    /// PR ids whose row is expanded to show check details. Ephemeral, not persisted —
    /// expansion state shouldn't follow the user across restarts.
    @Published var expandedPRs: Set<String> = []

    /// PR ids whose enable/disable auto-merge call is currently in flight.
    @Published private(set) var autoMergeInFlight: Set<String> = []

    /// Active top-level view in the menu. Persisted across launches via UserDefaults
    /// (lighter than another field on PersistedState since it's pure UI state).
    @Published var currentTab: AppTab = .myPRs

    /// PRs where the user is requested as a reviewer (direct or via team membership).
    @Published private(set) var reviewingPRs: [PullRequest] = []

    /// True while the reviewing-PRs query is in flight.
    @Published private(set) var isLoadingReviewing = false

    /// Whether reviewing PRs have been loaded at least once. Prevents the UI from
    /// putting `.task` on a flickering conditional and re-triggering loads in a loop.
    @Published private(set) var didLoadReviewingOnce = false

    /// Cached team slugs the viewer is a member of. Used to filter team-based
    /// reviewer pills on the Reviewing tab.
    private var viewerTeamSlugs: Set<String> = []

    /// When the team-slug cache was last refreshed. Team membership changes
    /// rarely (yearly for most users), so re-fetching every poll wastes ~2880
    /// calls/day. We refresh hourly instead — pill correctness lags by at most
    /// an hour, which is fine for a user-facing UI.
    private var teamSlugsLastRefreshed: Date?
    private static let teamSlugRefreshInterval: TimeInterval = 3600  // 1 hour

    /// Background polling task for the Reviewing tab. Mirrors the My PRs loop
    /// so reviewing data is always fresh by the time you switch tabs.
    private var reviewingPollTask: Task<Void, Never>?

    /// Cache of which worktree we're currently creating, by PR id.
    @Published private(set) var worktreeInFlight: Set<String> = []

    /// All persisted state. Mutated only via mutate(_:) which also schedules a save.
    @Published private(set) var persistedState: PersistedState = PersistedState()

    /// SwiftUI's `.task` re-fires when the popover reappears. Bootstrap must be idempotent.
    private var didBootstrap = false

    init() {
        let persisted = PersistenceStore.load()
        let client = GitHubClient()
        self.client = client
        self.monitor = PRMonitor(client: client, pollInterval: persisted.settings.pollIntervalSeconds)
        self.persistedState = persisted
        self.repoFilter = persisted.settings.defaultRepoFilter
        self.notifications = NotificationService { [weak self] response in
            Task { @MainActor in await self?.handle(response: response) }
        }
        // Wire monitor callbacks. AppState owns all the policy logic now.
        self.monitor.onAuthError = { [weak self] reason in
            Task { @MainActor in self?.authStatus = .needsReauth(reason: reason) }
        }
        self.monitor.willRefresh = { [weak self] in
            self?.cleanExpiredSnoozes()
        }
        self.monitor.onPRUpdated = { [weak self] pr in
            await self?.handle(prUpdated: pr)
        }
        self.monitor.onListSettled = { [weak self] liveIds in
            self?.cleanDedupeForClosedPRs(liveIds: liveIds)
        }
    }

    // MARK: - Bootstrap & auth

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await notifications.bootstrap()
        await checkAuth()
        // Pre-fetch the viewer's team memberships so reviewing pills are filtered
        // correctly on the very first refresh. Failure is non-fatal — refreshReviewing
        // will retry hourly.
        if case .authenticated = authStatus {
            await refreshTeamSlugsIfStale()
        }
        startReviewingPolling()
    }

    /// Re-fetches viewer's team slugs if the cache is older than `teamSlugRefreshInterval`
    /// (or never fetched). Hourly cadence is cheap and timely — team membership rarely
    /// changes, so polling every reviewing refresh would be ~99% wasted calls.
    private func refreshTeamSlugsIfStale() async {
        if let last = teamSlugsLastRefreshed,
           Date().timeIntervalSince(last) < Self.teamSlugRefreshInterval {
            return
        }
        do {
            viewerTeamSlugs = try await client.fetchViewerTeamSlugs()
            teamSlugsLastRefreshed = Date()
            Log.debug("viewer is on \(viewerTeamSlugs.count) teams")
        } catch {
            Log.debug("fetchViewerTeamSlugs failed: \(error.localizedDescription)")
        }
    }

    /// Long-running task that polls reviewing PRs at the same interval as monitor.
    /// Cancelled on auth failure (we already stop the My PRs monitor there too).
    private func startReviewingPolling() {
        reviewingPollTask?.cancel()
        reviewingPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshReviewing()
                let interval = self.persistedState.settings.pollIntervalSeconds
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func stopReviewingPolling() {
        reviewingPollTask?.cancel()
        reviewingPollTask = nil
    }

    func refreshNotificationAuth() async {
        await notifications.refreshAuthorizationStatus()
    }

    func checkAuth() async {
        do {
            let login = try await client.currentLogin()
            guard !login.isEmpty else {
                authStatus = .needsReauth(reason: "gh returned empty login. Run `gh auth login`.")
                monitor.stop()
                return
            }
            authStatus = .authenticated(login: login)
            monitor.start()
        } catch let err as GitHubClientError {
            authStatus = .needsReauth(reason: err.localizedDescription)
            monitor.stop()
        } catch {
            authStatus = .needsReauth(reason: error.localizedDescription)
            monitor.stop()
        }
    }

    // MARK: - Persisted-state mutation helpers

    /// Single mutation entry point. All state changes go through this so we
    /// always save afterward and bump the @Published cleanly for SwiftUI.
    private func mutate(_ block: (inout PersistedState) -> Void) {
        var s = persistedState
        block(&s)
        persistedState = s
        PersistenceStore.save(s)
    }

    // MARK: - Pin / snooze / auto-rebase API for the UI

    func togglePin(_ prId: String) {
        let wasPinned = persistedState.pinned.contains(prId)
        mutate { s in
            if wasPinned { s.pinned.remove(prId) }
            else { s.pinned.insert(prId) }
        }
        if let pr = lookupPR(prId) {
            record(wasPinned ? .unpinned : .pinned, pr: pr)
        }
    }

    private func lookupPR(_ prId: String) -> PullRequest? {
        monitor.prs.first(where: { $0.id == prId })
            ?? reviewingPRs.first(where: { $0.id == prId })
    }

    func unpinAll() {
        mutate { s in
            s.pinned.removeAll()
            s.showPinnedOnly = false  // turning the toggle off avoids a stale "show nothing" state
        }
    }

    func setShowPinnedOnly(_ on: Bool) {
        mutate { $0.showPinnedOnly = on }
    }

    func snooze(_ prId: String, for duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        mutate { s in
            s.snoozedUntil[prId] = until
            // Clear dedupe so the post-snooze refresh fires a notification if state warrants.
            s.notifiedNeedsUpdate.remove(prId)
            s.notifiedReadyToMerge.remove(prId)
            s.notifiedBlockedByTests.remove(prId)
        }
        if let pr = lookupPR(prId) {
            let mins = Int(duration / 60)
            record(.snoozed, pr: pr, detail: "for \(mins) min")
        }
    }

    func unsnooze(_ prId: String) {
        mutate { s in s.snoozedUntil.removeValue(forKey: prId) }
        if let pr = lookupPR(prId) { record(.unsnoozed, pr: pr) }
    }

    func toggleAutoRebase(_ prId: String) {
        mutate { s in
            if s.autoRebase.contains(prId) { s.autoRebase.remove(prId) }
            else { s.autoRebase.insert(prId) }
        }
    }

    /// Enable or disable auto-merge for a PR.
    ///
    /// Enabling: try GitHub-native auto-merge first (`enablePullRequestAutoMerge`).
    /// If GitHub rejects — usually because the repo doesn't allow auto-merge — we
    /// still mark the PR as auto-merge in our own state and fall back to
    /// **client-side auto-merge**: each refresh, when the PR is ready (CLEAN +
    /// APPROVED + not draft), we call `mergePullRequest` directly. From the user's
    /// perspective the behavior is the same; just the merge happens from this app
    /// instead of GitHub's server.
    ///
    /// Disabling: try GitHub-native disable (no-op if it wasn't armed) and clear
    /// our flag regardless.
    func toggleAutoMerge(_ prId: String) async {
        guard !autoMergeInFlight.contains(prId) else { return }
        guard let pr = monitor.prs.first(where: { $0.id == prId }) else { return }
        autoMergeInFlight.insert(prId)
        defer { autoMergeInFlight.remove(prId) }
        let isEnabling = !persistedState.autoMerge.contains(prId)
        if isEnabling {
            // Pick the right method for this repo: per-repo override > global default
            // > first allowed. The repo's allowed methods come from the phase-1 query.
            guard let method = chosenMergeMethod(for: pr) else {
                Log.debug("auto-merge \(prId) skipped: repo allows no merge methods")
                await notifications.notifyAutoRebaseFailed(
                    pr: pr,
                    reason: "Repo \(pr.repoOwner)/\(pr.repoName) allows no merge methods."
                )
                return
            }
            // Always set the flag — the client-side fallback handles the case where
            // GitHub-side auto-merge isn't available for this repo.
            mutate { $0.autoMerge.insert(prId) }
            do {
                try await client.enableAutoMerge(prNodeId: pr.nodeId, method: method)
                Log.debug("auto-merge \(prId) enabled GitHub-side using \(method.rawValue)")
                record(.autoMergeEnabled, pr: pr, detail: method.rawValue)
            } catch {
                // GitHub-side isn't available; we'll merge from this app when ready.
                Log.debug("auto-merge \(prId) GitHub-side unavailable, falling back: \(error.localizedDescription)")
                record(.autoMergeEnabled, pr: pr, detail: "client-side, \(method.rawValue)")
                if pr.isReadyToMerge {
                    await runClientSideMergeIfFlagged(pr)
                }
            }
        } else {
            mutate { $0.autoMerge.remove(prId) }
            record(.autoMergeDisabled, pr: pr)
            // Best-effort cancel of GitHub-side auto-merge. Errors silently if
            // it wasn't armed there in the first place.
            do {
                try await client.disableAutoMerge(prNodeId: pr.nodeId)
            } catch {
                Log.debug("auto-merge \(prId) GitHub-side disable: \(error.localizedDescription)")
            }
        }
    }

    /// Called from the transition handler whenever a PR becomes ready while the
    /// auto-merge flag is set. Merges via `mergePullRequest`. Safe to call when
    /// GitHub-side auto-merge is also armed: GitHub will likely have merged it
    /// already, in which case our mutation errors with "already merged" and we
    /// drop the flag.
    private func runClientSideMergeIfFlagged(_ pr: PullRequest) async {
        guard persistedState.autoMerge.contains(pr.id),
              !autoMergeInFlight.contains(pr.id),
              pr.isReadyToMerge else { return }
        autoMergeInFlight.insert(pr.id)
        defer { autoMergeInFlight.remove(pr.id) }

        guard let method = chosenMergeMethod(for: pr) else {
            Log.debug("auto-merge \(pr.id) client-side: no allowed merge method, dropping flag")
            mutate { $0.autoMerge.remove(pr.id) }
            return
        }
        do {
            try await client.mergePullRequest(prNodeId: pr.nodeId, method: method)
            Log.debug("auto-merge \(pr.id) merged client-side")
            record(.merged, pr: pr, detail: method.rawValue)
            // Clear the flag now that the PR is gone from the open list.
            mutate { $0.autoMerge.remove(pr.id) }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await monitor.refresh()
        } catch {
            // "already merged" — GitHub-side auto-merge or a manual click won the race. Clean up.
            let msg = error.localizedDescription.lowercased()
            if msg.contains("already merged") || msg.contains("not mergeable") {
                Log.debug("auto-merge \(pr.id) already merged elsewhere, clearing flag")
                mutate { $0.autoMerge.remove(pr.id) }
                return
            }
            Log.debug("auto-merge \(pr.id) client-side merge failed: \(error.localizedDescription)")
            if persistedState.settings.enableAutoRebaseFailureNotification {
                await notifications.notifyAutoRebaseFailed(
                    pr: pr,
                    reason: "Auto-merge failed: \(error.localizedDescription)"
                )
            }
        }
    }

    func toggleExpanded(_ prId: String) {
        if expandedPRs.contains(prId) { expandedPRs.remove(prId) }
        else { expandedPRs.insert(prId) }
    }

    func isAutoMerge(_ prId: String) -> Bool { persistedState.autoMerge.contains(prId) }

    // MARK: - Activity log

    /// Append an event and trim per ActivityRetention. Call from transition handlers
    /// and action handlers; never from the read path.
    private func recordActivity(prId: String, prNumber: Int, prTitle: String, kind: ActivityEvent.Kind, detail: String? = nil) {
        let event = ActivityEvent(
            id: UUID(), timestamp: Date(),
            prId: prId, prNumber: prNumber, prTitle: prTitle,
            kind: kind, detail: detail
        )
        mutate { s in
            s.activity.append(event)
            // Cap by max age
            let cutoff = Date().addingTimeInterval(-Double(ActivityRetention.maxAgeDays * 86400))
            s.activity.removeAll { $0.timestamp < cutoff }
            // Cap by max entries (keep newest)
            if s.activity.count > ActivityRetention.maxEntries {
                let drop = s.activity.count - ActivityRetention.maxEntries
                s.activity.removeFirst(drop)
            }
        }
    }

    private func record(_ kind: ActivityEvent.Kind, pr: PullRequest, detail: String? = nil) {
        recordActivity(prId: pr.id, prNumber: pr.number, prTitle: pr.title, kind: kind, detail: detail)
    }

    // MARK: - Reviewer PRs

    func refreshReviewing() async {
        guard !isLoadingReviewing else { return }
        isLoadingReviewing = true
        defer {
            isLoadingReviewing = false
            didLoadReviewingOnce = true
        }
        // Refresh team membership at most hourly. GitHub evaluates
        // `review-requested:@me` server-side dynamically, so the PR list itself
        // is always correct — this only governs how fresh the local pill filter is.
        await refreshTeamSlugsIfStale()
        do {
            let prs = try await client.fetchReviewingPRs(viewerTeamSlugs: viewerTeamSlugs)
            try Task.checkCancellation()
            var enriched = prs
            await withTaskGroup(of: (Int, PREnrichment?).self) { group in
                for (idx, pr) in prs.enumerated() {
                    group.addTask { [client = self.client] in
                        do {
                            let e = try await client.enrichPR(nodeId: pr.nodeId)
                            return (idx, e)
                        } catch {
                            return (idx, nil)
                        }
                    }
                }
                for await (idx, e) in group {
                    guard let e else { continue }
                    enriched[idx].mergeable = e.mergeable
                    enriched[idx].mergeStateStatus = e.mergeStateStatus
                    enriched[idx].reviewDecision = e.reviewDecision
                    enriched[idx].checkRollupState = e.checkRollupState
                    enriched[idx].checks = e.checks
                }
            }
            reviewingPRs = enriched
        } catch is CancellationError {
            // Outer task was cancelled — happens when SwiftUI views re-render or
            // the user switches tabs mid-fetch. Not a real error; stay silent.
        } catch let err as GitHubClientError where err.isAuthError {
            stopReviewingPolling()
            authStatus = .needsReauth(reason: err.localizedDescription)
        } catch {
            // URLSession also surfaces cancellation as -999. Silence those too.
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
            Log.debug("refreshReviewing failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Worktree actions

    /// Create + open a worktree for the PR. Called from row's "Create worktree" action.
    func createAndOpenWorktree(for pr: PullRequest) async {
        guard !worktreeInFlight.contains(pr.id) else { return }
        worktreeInFlight.insert(pr.id)
        defer { worktreeInFlight.remove(pr.id) }

        guard let repoPath = WorktreeManager.locateLocalRepo(owner: pr.repoOwner, name: pr.repoName) else {
            await notifications.notifyAutoRebaseFailed(
                pr: pr,
                reason: "No local checkout found for \(pr.repoOwner)/\(pr.repoName)."
            )
            return
        }
        let worktreePath = WorktreeManager.resolvePath(
            root: persistedState.settings.worktreeRoot,
            repoOwner: pr.repoOwner, repoName: pr.repoName, branch: pr.headRefName
        )
        do {
            try WorktreeManager.create(repoPath: repoPath, worktreePath: worktreePath, branch: pr.headRefName)
            mutate { $0.worktrees[pr.id] = worktreePath.path }
            WorktreeManager.openInEditor(worktreePath, command: persistedState.settings.editorCommand)
        } catch {
            Log.debug("createWorktree \(pr.id) failed: \(error.localizedDescription)")
            await notifications.notifyAutoRebaseFailed(pr: pr, reason: error.localizedDescription)
        }
    }

    /// Open an already-created worktree in the configured editor.
    func openWorktreeInEditor(prId: String) {
        guard let pathString = persistedState.worktrees[prId] else { return }
        WorktreeManager.openInEditor(URL(fileURLWithPath: pathString), command: persistedState.settings.editorCommand)
    }

    /// Remove a worktree. `force` only set after the user confirms past a dirty state.
    func removeWorktree(prId: String, force: Bool = false) {
        guard let pathString = persistedState.worktrees[prId] else { return }
        guard let pr = monitor.prs.first(where: { $0.id == prId })
              ?? reviewingPRs.first(where: { $0.id == prId })
        else {
            // PR no longer in either list; we can still remove the worktree if we know the path.
            removeWorktreeAtPath(pathString, prId: prId, repoOwner: nil, repoName: nil, force: force)
            return
        }
        guard let repoPath = WorktreeManager.locateLocalRepo(owner: pr.repoOwner, name: pr.repoName) else {
            mutate { $0.worktrees.removeValue(forKey: prId) }
            return
        }
        do {
            try WorktreeManager.remove(repoPath: repoPath, worktreePath: URL(fileURLWithPath: pathString), force: force)
            mutate { $0.worktrees.removeValue(forKey: prId) }
        } catch {
            Log.debug("removeWorktree \(prId) failed: \(error.localizedDescription)")
        }
    }

    private func removeWorktreeAtPath(_ pathString: String, prId: String, repoOwner: String?, repoName: String?, force: Bool) {
        // Best-effort path-only removal when we no longer have the PR in our state.
        let path = URL(fileURLWithPath: pathString)
        do {
            try FileManager.default.removeItem(at: path)
            mutate { $0.worktrees.removeValue(forKey: prId) }
        } catch {
            Log.debug("removeWorktreeAtPath \(prId) failed: \(error.localizedDescription)")
        }
    }

    func updateWorktreeRoot(_ root: String) {
        mutate { $0.settings.worktreeRoot = root }
    }

    func updateEditorCommand(_ command: String) {
        mutate { $0.settings.editorCommand = command }
    }

    // MARK: - Per-repo merge method selection

    /// Hardcoded preference order used for the auto-pick fallback. SQUASH first
    /// because it produces the cleanest default history; REBASE last because some
    /// repos enable it without intending it as the default.
    private static let methodFallbackOrder = ["SQUASH", "MERGE", "REBASE"]

    /// Picks the merge method to use for a given PR's repo. Order:
    ///   1. Explicit per-repo override, if it's still in the repo's allowed set
    ///   2. First allowed method in preference order: SQUASH > MERGE > REBASE
    /// Returns nil if the repo allows no merge methods at all.
    func chosenMergeMethod(for pr: PullRequest) -> GitHubClient.MergeMethod? {
        let repoKey = "\(pr.repoOwner)/\(pr.repoName)"
        if let override = persistedState.perRepoMergeMethod[repoKey],
           pr.allowedMergeMethods.contains(override) {
            return GitHubClient.MergeMethod(rawValue: override)
        }
        return autoPickedMethod(allowed: pr.allowedMergeMethods)
    }

    /// What "Default" resolves to for a given allowed-set. Surfaced in the per-repo
    /// settings picker so the user can see exactly which method will be used.
    func autoPickedMethod(allowed: Set<String>) -> GitHubClient.MergeMethod? {
        for raw in Self.methodFallbackOrder where allowed.contains(raw) {
            return GitHubClient.MergeMethod(rawValue: raw)
        }
        return nil
    }

    func setPerRepoMergeMethod(_ repoKey: String, method: String?) {
        mutate { s in
            if let method { s.perRepoMergeMethod[repoKey] = method }
            else { s.perRepoMergeMethod.removeValue(forKey: repoKey) }
        }
    }

    /// All repos we've seen PRs for, with their allowed methods. For settings UI.
    var seenRepos: [(key: String, allowed: Set<String>)] {
        var byKey: [String: Set<String>] = [:]
        for pr in monitor.prs {
            let k = "\(pr.repoOwner)/\(pr.repoName)"
            byKey[k] = pr.allowedMergeMethods
        }
        return byKey.map { (key: $0.key, allowed: $0.value) }.sorted { $0.key < $1.key }
    }

    func updateSettings(_ block: (inout PersistedSettings) -> Void) {
        mutate { s in block(&s.settings) }
        // Apply runtime side effects.
        monitor.setPollInterval(persistedState.settings.pollIntervalSeconds)
    }

    /// Called every refresh tick before the fetch. Removes expired snoozes so
    /// the upcoming refresh treats those PRs as fresh and notifies if state warrants.
    private func cleanExpiredSnoozes() {
        let now = Date()
        let expired = persistedState.snoozedUntil.filter { $0.value <= now }.map(\.key)
        guard !expired.isEmpty else { return }
        mutate { s in
            for id in expired { s.snoozedUntil.removeValue(forKey: id) }
        }
        Log.debug("snooze: expired \(expired.count) — will re-evaluate next refresh")
    }

    /// Drop dedupe entries for PRs that no longer appear in the list (closed/merged).
    /// Pin/snooze/autoRebase entries are intentionally preserved across close-and-reopen.
    private func cleanDedupeForClosedPRs(liveIds: Set<String>) {
        let staleKeys = persistedState.notifiedNeedsUpdate.union(
                          persistedState.notifiedReadyToMerge).union(
                          persistedState.notifiedBlockedByTests)
            .subtracting(liveIds)
        guard !staleKeys.isEmpty else { return }
        mutate { s in
            s.notifiedNeedsUpdate.subtract(staleKeys)
            s.notifiedReadyToMerge.subtract(staleKeys)
            s.notifiedBlockedByTests.subtract(staleKeys)
        }
    }

    // MARK: - PR-update reactor

    /// Called by PRMonitor after each per-PR enrichment. Computes transitions,
    /// applies dedupe + snooze + pin + auto-rebase rules, and fires notifications
    /// or rebase actions accordingly.
    private func handle(prUpdated pr: PullRequest) async {
        // Snooze suppresses everything — no notifications, no auto-rebase. Dedupe
        // entries are intentionally untouched while snoozed; if state changes
        // during the snooze, the post-snooze refresh fires the right notification.
        if isSnoozed(pr.id) { return }

        // Pin filter: when any PR is pinned, only pinned PRs get notifications.
        if !persistedState.pinned.isEmpty && !persistedState.pinned.contains(pr.id) {
            return
        }

        // BEHIND
        if pr.needsBranchUpdate {
            if !persistedState.notifiedNeedsUpdate.contains(pr.id) {
                mutate { $0.notifiedNeedsUpdate.insert(pr.id) }
                record(.becameBehind, pr: pr)
                if persistedState.autoRebase.contains(pr.id) {
                    await runAutoRebase(pr: pr)
                } else if persistedState.settings.enableRebaseNotification {
                    await notifications.notifyNeedsUpdate(pr: pr)
                }
            }
        } else {
            if persistedState.notifiedNeedsUpdate.contains(pr.id) {
                mutate { $0.notifiedNeedsUpdate.remove(pr.id) }
            }
        }

        // READY TO MERGE
        if pr.isReadyToMerge {
            if !persistedState.notifiedReadyToMerge.contains(pr.id) {
                mutate { $0.notifiedReadyToMerge.insert(pr.id) }
                record(.becameReady, pr: pr)
                if persistedState.settings.enableReadyNotification {
                    await notifications.notifyReadyToMerge(pr: pr)
                }
            }
            // Auto-merge fallback: if user opted in but GitHub-side wasn't armed,
            // we merge from here. Safe even if GitHub-side IS armed — GitHub usually
            // wins the race and we get an "already merged" no-op.
            if persistedState.autoMerge.contains(pr.id) {
                await runClientSideMergeIfFlagged(pr)
            }
        } else {
            if persistedState.notifiedReadyToMerge.contains(pr.id) {
                mutate { $0.notifiedReadyToMerge.remove(pr.id) }
            }
        }

        // CI FAILING
        if pr.displayState == .blockedByTests {
            if !persistedState.notifiedBlockedByTests.contains(pr.id) {
                mutate { $0.notifiedBlockedByTests.insert(pr.id) }
                record(.becameTestsFailing, pr: pr)
                if persistedState.settings.enableTestsFailingNotification {
                    await notifications.notifyTestsFailing(pr: pr)
                }
            }
        } else {
            if persistedState.notifiedBlockedByTests.contains(pr.id) {
                mutate { $0.notifiedBlockedByTests.remove(pr.id) }
            }
        }
    }

    /// Auto-rebase path: try the mutation; on failure, notify (if enabled) and
    /// let the user handle it manually. The notifiedNeedsUpdate flag stays set
    /// so we don't auto-rebase repeatedly until the PR leaves and re-enters BEHIND.
    private func runAutoRebase(pr: PullRequest) async {
        guard !rebaseInFlight.contains(pr.id) else { return }
        rebaseInFlight.insert(pr.id)
        defer { rebaseInFlight.remove(pr.id) }
        do {
            try await client.updateBranch(prNodeId: pr.nodeId, method: .rebase)
            record(.autoRebased, pr: pr)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await monitor.refresh()
            Log.debug("auto-rebase \(pr.id) succeeded")
        } catch {
            Log.debug("auto-rebase \(pr.id) failed: \(error.localizedDescription)")
            record(.autoRebaseFailed, pr: pr, detail: error.localizedDescription)
            if persistedState.settings.enableAutoRebaseFailureNotification {
                await notifications.notifyAutoRebaseFailed(pr: pr, reason: error.localizedDescription)
            }
        }
    }

    // MARK: - User-initiated rebase

    /// Manual rebase via the inline button or the notification action.
    func rebase(prId: String) async {
        guard !rebaseInFlight.contains(prId) else { return }
        guard let pr = monitor.prs.first(where: { $0.id == prId }) else { return }
        rebaseInFlight.insert(prId)
        defer { rebaseInFlight.remove(prId) }
        do {
            try await client.updateBranch(prNodeId: pr.nodeId, method: .rebase)
            record(.rebased, pr: pr)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await monitor.refresh()
        } catch {
            Log.debug("rebase \(prId) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Test notifications

    func fireTestNotifications() async {
        let pr = PullRequest(
            nodeId: "__gitpilot_test_node__",
            number: 0,
            title: "Test notification — synthetic PR, no real action",
            url: URL(string: "https://github.com")!,
            headRefName: "test-branch",
            baseRefName: "main",
            isDraft: false,
            repoOwner: "__gitpilot_test__",
            repoName: "test",
            mergeable: "MERGEABLE",
            mergeStateStatus: .clean,
            reviewDecision: "APPROVED",
            checkRollupState: .success
        )
        await notifications.notifyNeedsUpdate(pr: pr)
        await notifications.notifyReadyToMerge(pr: pr)
        await notifications.notifyTestsFailing(pr: pr)
    }

    // MARK: - UI derivations

    var availableRepos: [String] {
        let keys = monitor.prs.map { "\($0.repoOwner)/\($0.repoName)" }
        return Array(Set(keys)).sorted()
    }

    /// PRs to display, applying:
    ///   - "Only show pinned" toggle: when on AND pinned set is non-empty, restrict
    ///     to pinned PRs across every filter. When off, all PRs are visible regardless
    ///     of the pinned set.
    ///   - Repo filter, search query (plain or regex)
    /// Pinned PRs always sort to the top of the result whenever the pinned set is
    /// non-empty, so they're easy to spot in any filter mode.
    /// Notifications still fire only for pinned PRs whenever the pinned set is non-empty
    /// — this UI logic affects visibility only.
    var visiblePRs: [PullRequest] {
        let query = searchText.trimmingCharacters(in: .whitespaces)

        var result = monitor.prs

        if !persistedState.pinned.isEmpty && persistedState.showPinnedOnly {
            result = result.filter { persistedState.pinned.contains($0.id) }
        }

        if let filter = repoFilter {
            result = result.filter { "\($0.repoOwner)/\($0.repoName)" == filter }
        }
        if !query.isEmpty {
            if useRegex {
                guard let regex = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) else {
                    return []
                }
                result = result.filter { pr in
                    let haystack = "#\(pr.number) \(pr.title) \(pr.repoName) \(pr.headRefName)"
                    let range = NSRange(haystack.startIndex..., in: haystack)
                    return regex.firstMatch(in: haystack, options: [], range: range) != nil
                }
            } else {
                result = result.filter { pr in
                    pr.title.localizedCaseInsensitiveContains(query) ||
                    "#\(pr.number)".contains(query) ||
                    pr.repoName.localizedCaseInsensitiveContains(query) ||
                    pr.headRefName.localizedCaseInsensitiveContains(query)
                }
            }
        }

        // Apply user-chosen sort. The .updated default preserves GitHub's response
        // order (we already query orderBy: UPDATED_AT DESC).
        result = applySort(result)

        // Stable sort with pinned PRs to the top whenever a pin exists. Runs after
        // the main sort so within each tier (pinned / unpinned), the chosen order holds.
        if !persistedState.pinned.isEmpty {
            let pinned = persistedState.pinned
            result = result.enumerated().sorted { lhs, rhs in
                let lp = pinned.contains(lhs.element.id)
                let rp = pinned.contains(rhs.element.id)
                if lp != rp { return lp }       // pinned first
                return lhs.offset < rhs.offset // preserve sort within each tier
            }.map(\.element)
        }
        return result
    }

    private func applySort(_ prs: [PullRequest]) -> [PullRequest] {
        switch persistedState.settings.sortOrder {
        case .updated:
            // GitHub's response is already updated-desc; preserve it.
            return prs
        case .prNumberDesc:
            // Group by repo first so cross-repo numbers don't interleave nonsensically.
            return prs.sorted { lhs, rhs in
                if lhs.repoName != rhs.repoName { return lhs.repoName < rhs.repoName }
                return lhs.number > rhs.number
            }
        case .prNumberAsc:
            return prs.sorted { lhs, rhs in
                if lhs.repoName != rhs.repoName { return lhs.repoName < rhs.repoName }
                return lhs.number < rhs.number
            }
        case .titleAlpha:
            return prs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .statusPriority:
            return prs.sorted { lhs, rhs in
                statusRank(lhs) < statusRank(rhs)
            }
        }
    }

    /// Lower rank = higher priority in the list. "Actionable" things first.
    private func statusRank(_ pr: PullRequest) -> Int {
        switch pr.displayState {
        case .readyToMerge:        return 0
        case .behind:              return 1
        case .conflicts:           return 2
        case .blockedByTests:      return 3
        case .blockedByReview:     return 4
        case .blockedTestsRunning: return 5
        case .blocked:             return 6
        case .other:               return 7
        case .draft:               return 8
        case .loading:             return 9
        }
    }

    var regexError: String? {
        guard useRegex, !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: searchText, options: [.caseInsensitive])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Reviewing-tab PR list with repo + search filters applied. No pin/sort because
    /// those concepts don't make sense for the reviewing surface (you're not
    /// "focused" on someone else's PR the same way).
    var filteredReviewingPRs: [PullRequest] {
        var result = reviewingPRs
        if let filter = repoFilter {
            result = result.filter { "\($0.repoOwner)/\($0.repoName)" == filter }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return result }
        if useRegex {
            guard let regex = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) else { return [] }
            return result.filter { pr in
                let h = "#\(pr.number) \(pr.title) \(pr.repoName) \(pr.headRefName)"
                return regex.firstMatch(in: h, options: [], range: NSRange(h.startIndex..., in: h)) != nil
            }
        }
        return result.filter { pr in
            pr.title.localizedCaseInsensitiveContains(query) ||
            "#\(pr.number)".contains(query) ||
            pr.repoName.localizedCaseInsensitiveContains(query) ||
            pr.headRefName.localizedCaseInsensitiveContains(query)
        }
    }

    func isSnoozed(_ prId: String) -> Bool {
        guard let until = persistedState.snoozedUntil[prId] else { return false }
        return until > Date()
    }

    func snoozedUntil(_ prId: String) -> Date? {
        persistedState.snoozedUntil[prId]
    }

    func isPinned(_ prId: String) -> Bool { persistedState.pinned.contains(prId) }
    func isAutoRebase(_ prId: String) -> Bool { persistedState.autoRebase.contains(prId) }

    // MARK: - Notification responses

    private func handle(response: NotificationResponse) async {
        switch response {
        case .updateBranch(let prId):
            await rebase(prId: prId)
        case .openPR(let prId):
            if let pr = monitor.prs.first(where: { $0.id == prId }) {
                NSWorkspace.shared.open(pr.url)
            }
        case .dismiss:
            break
        }
    }
}

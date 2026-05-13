import Foundation
import AppKit

/// Single owner of all UX policy: transition detection, dedupe, snooze, pin,
/// auto-rebase, settings, persistence. PRMonitor is a pure fetcher; this glues
/// everything together.
@MainActor
final class AppState: ObservableObject {
    let client: GitHubClient
    let monitor: PRMonitor
    /// Plain `let` — initialized in init with a placeholder closure, then we
    /// reassign its onResponse handler after super-init when self is available.
    let notifications: NotificationService

    /// Drives the auth banner in the menu UI.
    @Published var authStatus: AuthStatus = .unknown

    /// Selected repo filter for the menu. `nil` means "All". didSet persists the
    /// choice into `settings.defaultRepoFilter` so the filter survives restarts —
    /// the previous behavior had it read on init but never written, so the field
    /// was effectively dead.
    @Published var repoFilter: String? = nil {
        didSet {
            guard didInit, oldValue != repoFilter else { return }
            mutate { $0.settings.defaultRepoFilter = repoFilter }
        }
    }

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
    /// (lighter than another field on PersistedState since it's pure UI state — no
    /// debounce/atomic-write cost for a tab change).
    @Published var currentTab: AppTab = .myPRs {
        didSet {
            guard didInit, oldValue != currentTab else { return }
            UserDefaults.standard.set(currentTab.rawValue, forKey: Self.currentTabKey)
        }
    }
    private static let currentTabKey = "GitPilot.currentTab"

    /// PRs where the user is requested as a reviewer (direct or via team membership).
    @Published private(set) var reviewingPRs: [PullRequest] = []

    /// True while the reviewing-PRs query is in flight.
    @Published private(set) var isLoadingReviewing = false

    /// Whether reviewing PRs have been loaded at least once. Prevents the UI from
    /// putting `.task` on a flickering conditional and re-triggering loads in a loop.
    @Published private(set) var didLoadReviewingOnce = false

    /// True while `checkAuth()` is running. Drives the auth-banner Retry button so
    /// a spam-click doesn't fan out N concurrent `gh` invocations + monitor restarts.
    @Published private(set) var isCheckingAuth = false

    /// True while a test-notification batch is being scheduled. Without this, a
    /// spam-click on "Send test notification" would queue 3·N notifications.
    @Published private(set) var isFiringTestNotifications = false

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

    /// Worktree-remove in flight, by PR id. Separate from the create set because
    /// the two can't both be in flight for the same PR (existence of a worktree
    /// determines which button the UI shows), but keeping them distinct lets the
    /// labels read accurately ("Removing…" vs "Creating…").
    @Published private(set) var worktreeRemoveInFlight: Set<String> = []

    /// Last error from `refreshReviewing`. Mirrors PRMonitor.lastError so the
    /// Reviewing tab has the same kind of in-tab error banner that My PRs has.
    /// Cleared on a successful refresh.
    @Published private(set) var reviewingLastError: String? = nil

    /// Most recent persistence-save failure message, if any. Surfaced as a small
    /// banner in the Settings disclosure so users know their pinned/snooze/etc.
    /// state isn't actually being saved to disk. Cleared on the next successful save.
    @Published private(set) var lastSaveError: String? = nil

    /// All persisted state. Mutated only via mutate(_:) which also schedules a save.
    @Published private(set) var persistedState: PersistedState = PersistedState()

    /// SwiftUI's `.task` re-fires when the popover reappears. Bootstrap must be idempotent.
    private var didBootstrap = false

    /// Bootstrap-time guard so the @Published `repoFilter` initializer below
    /// doesn't trigger a save during init (we're just hydrating from disk).
    private var didInit = false

    init() {
        let persisted = PersistenceStore.load()
        let client = GitHubClient()
        self.client = client
        self.monitor = PRMonitor(client: client, pollInterval: persisted.settings.pollIntervalSeconds)
        self.persistedState = persisted
        self.repoFilter = persisted.settings.defaultRepoFilter
        if let raw = UserDefaults.standard.string(forKey: Self.currentTabKey),
           let tab = AppTab(rawValue: raw) {
            self.currentTab = tab
        }
        self.notifications = NotificationService()

        // Wire callbacks now that all stored properties are initialized and
        // capturing `self` is safe.
        self.notifications.onResponse = { [weak self] response in
            Task { @MainActor in await self?.handle(response: response) }
        }
        self.monitor.onAuthError = { [weak self] reason in
            Task { @MainActor in self?.applyAuthFailure(reason) }
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
        // After all stored properties are set, mark init done. Subsequent
        // assignments to `repoFilter` will now persist via its didSet.
        didInit = true
    }

    // MARK: - Bootstrap & auth

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await notifications.bootstrap()
        await checkAuth()  // checkAuth starts both monitor and reviewing polling on success
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
        guard !isCheckingAuth else { return }
        isCheckingAuth = true
        defer { isCheckingAuth = false }
        do {
            let login = try await client.currentLogin()
            guard !login.isEmpty else {
                applyAuthFailure("gh returned empty login. Run `gh auth login`.")
                return
            }
            authStatus = .authenticated(login: login)
            await refreshTeamSlugsIfStale()
            monitor.start()
            startReviewingPolling()
        } catch let err as GitHubClientError {
            applyAuthFailure(err.localizedDescription)
        } catch {
            applyAuthFailure(error.localizedDescription)
        }
    }

    /// Centralizes the auth-failure side effects so we don't forget to stop
    /// either polling loop. Also clears team-slug cache so a re-auth as a
    /// different account doesn't reuse the previous user's team filter.
    private func applyAuthFailure(_ reason: String) {
        authStatus = .needsReauth(reason: reason)
        monitor.stop()
        stopReviewingPolling()
        viewerTeamSlugs.removeAll()
        teamSlugsLastRefreshed = nil
    }

    // MARK: - Persisted-state mutation helpers

    /// Single mutation entry point. All state changes go through this so we
    /// always publish + schedule a save. Saves are coalesced — multiple mutate
    /// calls in the same ~250ms window write to disk once, instead of 25× on
    /// a refresh that updates dozens of dedupe + activity entries.
    private func mutate(_ block: (inout PersistedState) -> Void) {
        var s = persistedState
        block(&s)
        persistedState = s
        scheduleSave()
    }

    /// Save coalescing. The actual disk write happens at most once per saveDebounce
    /// interval, plus once on app termination so nothing in flight is dropped.
    private static let saveDebounce: TimeInterval = 0.25
    private var pendingSaveTask: Task<Void, Never>?

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.saveDebounce * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self else { return }
            let snapshot = self.persistedState
            // Move the encode + write off the main actor.
            let result = await Task.detached { PersistenceStore.save(snapshot) }.value
            self.lastSaveError = result
        }
    }

    /// Synchronous flush — called from app termination so nothing pending is dropped.
    func flushPendingSave() {
        pendingSaveTask?.cancel()
        lastSaveError = PersistenceStore.save(persistedState)
    }

    /// User-facing dismiss for the save-error banner. The banner re-appears if
    /// the next save also fails.
    func dismissSaveError() { lastSaveError = nil }

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

    /// Single source of truth for "find a PR by id" — checks My PRs first, then
    /// Reviewing. Use this everywhere, including from the actions menu so the
    /// context menu on a Reviewing-tab row can act on its PR (the previous
    /// `monitor.prs.first(where:)`-only callers silently no-op'd on Reviewing PRs).
    func lookupPR(_ prId: String) -> PullRequest? {
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
            s.notifiedConflicts.remove(prId)
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

    /// Toggle auto-rebase. When enabling and the PR is currently behind base,
    /// kick off the rebase immediately — previously the flag would only act on
    /// the next BEHIND transition, so a PR already in that state would just sit
    /// there waiting indefinitely.
    func toggleAutoRebase(_ prId: String) async {
        let willEnable = !persistedState.autoRebase.contains(prId)
        mutate { s in
            if willEnable { s.autoRebase.insert(prId) }
            else { s.autoRebase.remove(prId) }
        }
        guard willEnable, let pr = lookupPR(prId) else { return }
        // Mark dedupe so the post-rebase refresh doesn't immediately re-notify
        // about the same BEHIND state and potentially run a second auto-rebase.
        if pr.needsBranchUpdate {
            mutate { $0.notifiedNeedsUpdate.insert(prId) }
            await runAutoRebase(pr: pr)
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
        guard let pr = lookupPR(prId) else { return }
        autoMergeInFlight.insert(prId)
        defer { autoMergeInFlight.remove(prId) }
        let isEnabling = !persistedState.autoMerge.contains(prId)
        if isEnabling {
            // Pick the right method for this repo: per-repo override > global default
            // > first allowed. The repo's allowed methods come from the phase-1 query.
            guard let method = chosenMergeMethod(for: pr) else {
                let reason = "Repo \(pr.repoOwner)/\(pr.repoName) allows no merge methods."
                Log.debug("auto-merge \(prId) skipped: \(reason)")
                record(.autoMergeFailed, pr: pr, detail: reason)
                if persistedState.settings.enableAutoMergeFailureNotification {
                    await notifications.notifyAutoMergeFailed(pr: pr, reason: reason)
                }
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
            // Best-effort cancel of GitHub-side auto-merge. If GitHub-side wasn't
            // armed in the first place this errors with a benign "not enabled"
            // message — common, no need to surface in activity.
            do {
                try await client.disableAutoMerge(prNodeId: pr.nodeId)
            } catch {
                let msg = error.localizedDescription.lowercased()
                if !msg.contains("not enabled") && !msg.contains("not auto") {
                    record(.autoMergeFailed, pr: pr, detail: "GitHub-side disable: \(error.localizedDescription)")
                    if persistedState.settings.enableAutoMergeFailureNotification {
                        await notifications.notifyAutoMergeFailed(
                            pr: pr,
                            reason: "GitHub-side disable failed: \(error.localizedDescription)"
                        )
                    }
                }
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
            let reason = "Repo \(pr.repoOwner)/\(pr.repoName) allows no merge methods."
            Log.debug("auto-merge \(pr.id) client-side: \(reason), dropping flag")
            record(.autoMergeFailed, pr: pr, detail: reason)
            if persistedState.settings.enableAutoMergeFailureNotification {
                await notifications.notifyAutoMergeFailed(pr: pr, reason: reason)
            }
            mutate { $0.autoMerge.remove(pr.id) }
            return
        }
        do {
            try await client.mergePullRequest(prNodeId: pr.nodeId, method: method)
            Log.debug("auto-merge \(pr.id) merged client-side")
            record(.merged, pr: pr, detail: method.rawValue)
            if persistedState.settings.enableAutoMergeCompletedNotification {
                await notifications.notifyAutoMergeCompleted(pr: pr, method: method.label)
            }
            // Clear the flag now that the PR is gone from the open list.
            mutate { $0.autoMerge.remove(pr.id) }
            // Same deadlock concern as auto-rebase — when this is called from
            // handle(prUpdated:) we're inside the refresh chain, so an inline
            // `await refresh()` would no-op against its own guard.
            scheduleDelayedRefresh()
        } catch {
            let msg = error.localizedDescription.lowercased()
            if msg.contains("already merged") {
                // GitHub-side auto-merge or a manual click won the race. From the
                // user's perspective this is still a successful auto-merge — record
                // and notify accordingly.
                Log.debug("auto-merge \(pr.id) already merged elsewhere, clearing flag")
                record(.merged, pr: pr, detail: "\(method.rawValue) (server-side)")
                if persistedState.settings.enableAutoMergeCompletedNotification {
                    await notifications.notifyAutoMergeCompleted(pr: pr, method: method.label)
                }
                mutate { $0.autoMerge.remove(pr.id) }
                return
            }
            if msg.contains("not mergeable") {
                // GitHub disagreed with our local `isReadyToMerge` at merge time.
                // Drop the flag rather than retry every refresh — re-enabling
                // auto-merge is one click if the user still wants it. Recording
                // here so the user can see why their auto-merge stopped firing.
                Log.debug("auto-merge \(pr.id) not mergeable at merge time, dropping flag")
                record(.autoMergeFailed, pr: pr, detail: "GitHub reports not mergeable; auto-merge cleared")
                if persistedState.settings.enableAutoMergeFailureNotification {
                    await notifications.notifyAutoMergeFailed(
                        pr: pr,
                        reason: "GitHub reports not mergeable. Re-enable auto-merge if you want to retry."
                    )
                }
                mutate { $0.autoMerge.remove(pr.id) }
                return
            }
            Log.debug("auto-merge \(pr.id) client-side merge failed: \(error.localizedDescription)")
            record(.autoMergeFailed, pr: pr, detail: error.localizedDescription)
            if persistedState.settings.enableAutoMergeFailureNotification {
                await notifications.notifyAutoMergeFailed(pr: pr, reason: error.localizedDescription)
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
    private func recordActivity(prId: String, prNumber: Int, prTitle: String, prURL: URL?, kind: ActivityEvent.Kind, detail: String? = nil) {
        let event = ActivityEvent(
            id: UUID(), timestamp: Date(),
            prId: prId, prNumber: prNumber, prTitle: prTitle,
            prURL: prURL,
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
        recordActivity(prId: pr.id, prNumber: pr.number, prTitle: pr.title, prURL: pr.url, kind: kind, detail: detail)
    }

    // MARK: - Reviewer PRs

    /// Number of per-PR enrichment failures from the most recent reviewing refresh.
    /// Surfaced via the refresh button tooltip when the user hovers, so they know
    /// why some Reviewing rows might be stuck in "loading…".
    @Published private(set) var reviewingEnrichmentFailureCount: Int = 0

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
            // A fetch made it through — clear any prior error banner.
            reviewingLastError = nil
            // Carry forward enrichment from the previous snapshot so rows don't
            // flash to "loading" while phase-2 fetches in the background.
            reviewingPRs = PullRequest.mergePreservingEnrichment(fresh: prs, previous: reviewingPRs)
            // Batched enrichment: one GraphQL call (chunked to 25 if needed)
            // replaces the per-PR fan-out. Lookup is by `prId` (not array index)
            // so concurrent edits to reviewingPRs don't corrupt the apply.
            var failureCount = 0
            let enrichments = try await client.enrichPRs(nodeIds: prs.map { $0.nodeId })
            try Task.checkCancellation()
            for pr in prs {
                guard let e = enrichments[pr.nodeId] else {
                    failureCount += 1
                    continue
                }
                if let idx = reviewingPRs.firstIndex(where: { $0.id == pr.id }) {
                    reviewingPRs[idx].apply(e)
                }
            }
            reviewingEnrichmentFailureCount = failureCount
        } catch is CancellationError {
            // Outer task was cancelled — happens when SwiftUI views re-render or
            // the user switches tabs mid-fetch. Not a real error; stay silent.
        } catch let err as GitHubClientError where err.isAuthError {
            applyAuthFailure(err.localizedDescription)
        } catch {
            // URLSession also surfaces cancellation as -999. Silence those too.
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
            Log.debug("refreshReviewing failed: \(error.localizedDescription)")
            reviewingLastError = error.localizedDescription
        }
    }

    // MARK: - Worktree actions

    /// Create + open a worktree for the PR. The actual `git fetch` + `git worktree
    /// add` runs on a detached task so the menu UI stays responsive — these can
    /// take 10s+ on slow connections. The `worktreeInFlight` flag keeps the
    /// context-menu button disabled while the create runs.
    func createAndOpenWorktree(for pr: PullRequest) async {
        guard !worktreeInFlight.contains(pr.id) else { return }
        worktreeInFlight.insert(pr.id)
        defer { worktreeInFlight.remove(pr.id) }

        guard let repoPath = WorktreeManager.locateLocalRepo(owner: pr.repoOwner, name: pr.repoName) else {
            let probed = WorktreeManager.repoSearchCandidates(owner: pr.repoOwner, name: pr.repoName)
            let reason = "No local checkout for \(pr.repoOwner)/\(pr.repoName). Probed: \(probed.joined(separator: ", "))"
            record(.worktreeCreateFailed, pr: pr, detail: reason)
            if persistedState.settings.enableWorktreeFailureNotification {
                await notifications.notifyWorktreeFailed(pr: pr, reason: reason)
            }
            return
        }
        let worktreePath = WorktreeManager.resolvePath(
            root: persistedState.settings.worktreeRoot,
            repoOwner: pr.repoOwner, repoName: pr.repoName, branch: pr.headRefName
        )
        let branch = pr.headRefName
        let editor = persistedState.settings.editorCommand
        do {
            // create / remove are async with continuation-based git wrapping, so
            // they suspend instead of blocking a cooperative-pool thread on
            // `git fetch`. No Task.detached needed.
            _ = try await WorktreeManager.create(repoPath: repoPath, worktreePath: worktreePath, branch: branch)
            mutate { $0.worktrees[pr.id] = worktreePath.path }
            WorktreeManager.openInEditor(worktreePath, command: editor)
        } catch {
            Log.debug("createWorktree \(pr.id) failed: \(error.localizedDescription)")
            record(.worktreeCreateFailed, pr: pr, detail: error.localizedDescription)
            if persistedState.settings.enableWorktreeFailureNotification {
                await notifications.notifyWorktreeFailed(pr: pr, reason: error.localizedDescription)
            }
        }
    }

    /// Open an already-created worktree in the configured editor.
    /// `openInEditor` only calls `Process.run()` (no waitUntilExit) so it doesn't
    /// block; the editor stays open as a child process.
    func openWorktreeInEditor(prId: String) {
        guard let pathString = persistedState.worktrees[prId] else { return }
        let url = URL(fileURLWithPath: pathString)
        WorktreeManager.openInEditor(url, command: persistedState.settings.editorCommand)
    }

    /// Remove a worktree. `force` only set after the user confirms past a dirty state.
    func removeWorktree(prId: String, force: Bool = false) async {
        guard !worktreeRemoveInFlight.contains(prId) else { return }
        guard let pathString = persistedState.worktrees[prId] else { return }
        worktreeRemoveInFlight.insert(prId)
        defer { worktreeRemoveInFlight.remove(prId) }
        let worktreeURL = URL(fileURLWithPath: pathString)

        guard let pr = lookupPR(prId) else {
            // PR no longer in either list; remove the worktree by path only.
            try? FileManager.default.removeItem(at: worktreeURL)
            mutate { $0.worktrees.removeValue(forKey: prId) }
            return
        }
        guard let repoPath = WorktreeManager.locateLocalRepo(owner: pr.repoOwner, name: pr.repoName) else {
            mutate { $0.worktrees.removeValue(forKey: prId) }
            return
        }
        do {
            try await WorktreeManager.remove(repoPath: repoPath, worktreePath: worktreeURL, force: force)
            mutate { $0.worktrees.removeValue(forKey: prId) }
        } catch {
            Log.debug("removeWorktree \(prId) failed: \(error.localizedDescription)")
            record(.worktreeRemoveFailed, pr: pr, detail: error.localizedDescription)
            if persistedState.settings.enableWorktreeFailureNotification {
                await notifications.notifyWorktreeFailed(pr: pr, reason: error.localizedDescription)
            }
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
    /// Backed by a @Published mirror so SwiftUI re-renders cleanly when the set
    /// changes (the previous computed-property version recomputed on every body
    /// invocation and didn't trigger when monitor.prs changed because the publisher
    /// nesting wasn't observed by SettingsSection).
    @Published private(set) var seenRepos: [(key: String, allowed: Set<String>)] = []

    private func recomputeSeenRepos() {
        var byKey: [String: Set<String>] = [:]
        for pr in monitor.prs {
            let k = "\(pr.repoOwner)/\(pr.repoName)"
            byKey[k] = pr.allowedMergeMethods
        }
        seenRepos = byKey.map { (key: $0.key, allowed: $0.value) }
            .sorted { $0.key < $1.key }
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

    /// Records an activity entry for each PR that just appeared or disappeared
    /// from the My PRs list. Skipped on the very first refresh to avoid flooding
    /// the timeline with "appeared" entries for every existing PR at app launch.
    /// We track full PRs (not just ids) so the "disappeared" event still has the
    /// title/number — by the time we detect the disappearance, the PR is no
    /// longer in monitor.prs.
    private var firstListSettleSeen = false
    private var lastSeenPRsById: [String: PullRequest] = [:]

    private func recordListChurn(liveIds: Set<String>) {
        let currentPRs = Dictionary(monitor.prs.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        defer {
            firstListSettleSeen = true
            lastSeenPRsById = currentPRs
        }
        guard firstListSettleSeen else { return }

        let appearedIds = liveIds.subtracting(lastSeenPRsById.keys)
        for id in appearedIds {
            if let pr = currentPRs[id] {
                record(.appeared, pr: pr)
            }
        }
        let disappearedIds = Set(lastSeenPRsById.keys).subtracting(liveIds)
        for id in disappearedIds {
            // Use the last observed PR snapshot so the activity row has a real
            // title and number (not a synthetic "#0" placeholder).
            if let pr = lastSeenPRsById[id] {
                record(.disappeared, pr: pr)
            }
        }
    }

    /// Drop dedupe entries for PRs that no longer appear in the list (closed/merged).
    /// Pins are also dropped — a merged/closed PR isn't coming back as the same row,
    /// and leaving the pin behind silently shrinks the "Only show pinned" view to
    /// empty. Snooze/autoRebase entries are still preserved across close-and-reopen.
    /// Also prunes the ephemeral expanded-row set so it doesn't grow unboundedly
    /// over a long session.
    private func cleanDedupeForClosedPRs(liveIds: Set<String>) {
        recordListChurn(liveIds: liveIds)
        // Refresh the cached repo list so settings sees the new shape immediately.
        recomputeSeenRepos()
        let staleKeys = persistedState.notifiedNeedsUpdate.union(
                          persistedState.notifiedReadyToMerge).union(
                          persistedState.notifiedBlockedByTests).union(
                          persistedState.notifiedConflicts)
            .subtracting(liveIds)
        let stalePins = persistedState.pinned.subtracting(liveIds)
        if !staleKeys.isEmpty || !stalePins.isEmpty {
            mutate { s in
                s.notifiedNeedsUpdate.subtract(staleKeys)
                s.notifiedReadyToMerge.subtract(staleKeys)
                s.notifiedBlockedByTests.subtract(staleKeys)
                s.notifiedConflicts.subtract(staleKeys)
                s.pinned.subtract(stalePins)
                // Mirror unpinAll: with no pins left, the toggle would just
                // produce a stale "show nothing" view, so flip it off.
                if s.pinned.isEmpty { s.showPinnedOnly = false }
            }
        }
        expandedPRs.formIntersection(liveIds.union(reviewingPRs.map(\.id)))
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
            let isAutoMerging = persistedState.autoMerge.contains(pr.id)
            if !persistedState.notifiedReadyToMerge.contains(pr.id) {
                mutate { $0.notifiedReadyToMerge.insert(pr.id) }
                record(.becameReady, pr: pr)
                // Suppress the "Ready to merge" ping when auto-merge is on for
                // this PR — the user opted in to silent merging; pinging them
                // about something they've delegated away is exactly the noise
                // they're trying to escape. The activity entry above still
                // records the transition, and the merge result (success or
                // failure) gets its own activity entry below.
                if persistedState.settings.enableReadyNotification && !isAutoMerging {
                    await notifications.notifyReadyToMerge(pr: pr)
                }
            }
            // Auto-merge fallback: if user opted in but GitHub-side wasn't armed,
            // we merge from here. Safe even if GitHub-side IS armed — GitHub usually
            // wins the race and we get an "already merged" no-op.
            if isAutoMerging {
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

        // MERGE CONFLICTS — actionable: requires a local checkout + manual resolve.
        // The activity kind was declared and the row UI rendered it, but no path
        // recorded it. Now mirrors the structure of the other transitions: dedupe
        // set, transition activity, optional notification.
        if pr.hasConflicts {
            if !persistedState.notifiedConflicts.contains(pr.id) {
                mutate { $0.notifiedConflicts.insert(pr.id) }
                record(.becameConflicts, pr: pr)
                if persistedState.settings.enableConflictsNotification {
                    await notifications.notifyConflicts(pr: pr)
                }
            }
        } else {
            if persistedState.notifiedConflicts.contains(pr.id) {
                mutate { $0.notifiedConflicts.remove(pr.id) }
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
            // Schedule a follow-up refresh in a detached Task so it runs after
            // the current refresh chain unwinds — `await monitor.refresh()`
            // here would deadlock against its own `isRefreshing` guard, since
            // auto-rebase is invoked from inside the enrichment loop. The 2s
            // delay gives GitHub time to recompute mergeStateStatus.
            scheduleDelayedRefresh()
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

    /// Fires a refresh ~2s from now via `monitor.requestRefresh()` so:
    ///   - the call doesn't block the current refresh chain (no inline await),
    ///   - the 2s gives GitHub time to recompute mergeStateStatus after the
    ///     mutation we just sent,
    ///   - if a refresh is in flight when the timer fires, it queues via the
    ///     pendingRefresh flag instead of being dropped.
    private func scheduleDelayedRefresh() {
        // Task spawned from a @MainActor context inherits the actor, so the
        // body already runs on @MainActor — no MainActor.run hop needed.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.monitor.requestRefresh()
        }
    }

    /// Manual rebase via the inline button or the notification action.
    func rebase(prId: String) async {
        guard !rebaseInFlight.contains(prId) else { return }
        guard let pr = lookupPR(prId) else { return }
        rebaseInFlight.insert(prId)
        defer { rebaseInFlight.remove(prId) }
        do {
            try await client.updateBranch(prNodeId: pr.nodeId, method: .rebase)
            record(.rebased, pr: pr)
            // Hold the button at "Rebasing…" through GitHub's mergeStateStatus
            // recompute and the post-mutation refresh — otherwise the flag
            // clears here and the button flickers back to "Rebase" before the
            // refreshed PR state hides it, inviting duplicate clicks. 5s is a
            // best-effort window; the recompute time isn't deterministic, but
            // a wider sleep makes the flicker rare in practice.
            // Drain any in-flight refresh first so our explicit refresh() isn't
            // no-op'd by the isRefreshing guard.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            while monitor.isRefreshing {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await monitor.refresh()
        } catch {
            // Surface the failure in activity so the user can see why nothing
            // happened — the inline button just snapping back to "Rebase" with
            // only a stderr log was the previous (silent) failure mode.
            Log.debug("rebase \(prId) failed: \(error.localizedDescription)")
            record(.rebaseFailed, pr: pr, detail: error.localizedDescription)
            if persistedState.settings.enableManualRebaseFailureNotification {
                await notifications.notifyManualRebaseFailed(pr: pr, reason: error.localizedDescription)
            }
        }
    }

    // MARK: - Test notifications

    /// Fires every notification kind against a synthetic PR. Used by the Settings
    /// "Send test notification" button to verify the notification pipeline.
    /// The synthetic ids never match anything in monitor.prs or reviewingPRs, so
    /// lookupPR returns nil for all action paths and no real PR is affected if
    /// the user clicks an action button. If you ever add a network-lookup fallback,
    /// gate it on a non-test id prefix so we don't 404 on a synthetic.
    func fireTestNotifications() async {
        guard !isFiringTestNotifications else { return }
        isFiringTestNotifications = true
        defer { isFiringTestNotifications = false }
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
        await notifications.notifyConflicts(pr: pr)
        await notifications.notifyAutoRebaseFailed(pr: pr, reason: "Test")
        await notifications.notifyAutoMergeFailed(pr: pr, reason: "Test")
        await notifications.notifyAutoMergeCompleted(pr: pr, method: "Squash")
        await notifications.notifyManualRebaseFailed(pr: pr, reason: "Test")
        await notifications.notifyWorktreeFailed(pr: pr, reason: "Test")
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
            if let pr = lookupPR(prId) {
                NSWorkspace.shared.open(pr.url)
            }
        case .dismiss:
            break
        }
    }
}

import SwiftUI
import AppKit

// MARK: - App entry

@main
struct GitPilotApp: App {
    @StateObject private var state = AppState()
    private let terminationObserver: TerminationObserver

    init() {
        // Hide Dock icon — this is a menu bar app.
        NSApp?.setActivationPolicy(.accessory)
        terminationObserver = TerminationObserver()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
                .onAppear { terminationObserver.bind(to: state) }
        } label: {
            MenuBarLabel(monitor: state.monitor)
        }
        .menuBarExtraStyle(.window)
        .commands {}

        // Native Settings window — bound to Cmd+, by SwiftUI. Opened
        // programmatically from the popover footer via `SettingsWindowOpener`.
        Settings {
            SettingsView(state: state)
        }
    }
}

/// Observes app-termination notifications so we can flush any pending save
/// to disk before the process exits. Without this, a quit during the 250ms
/// debounce window would lose the most recent state change.
private final class TerminationObserver {
    private weak var state: AppState?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // The notification fires synchronously on the main thread during
            // app termination. Hop to MainActor explicitly so the call to
            // flushPendingSave (which writes the JSON file) blocks termination
            // until it returns — losing the most recent state change to a
            // 250ms debounce would be worse than a brief delay.
            MainActor.assumeIsolated { self?.state?.flushPendingSave() }
        }
    }

    func bind(to state: AppState) { self.state = state }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

// MARK: - Menu bar label

/// Menu bar surface: a pull-request glyph plus an "attention count" badge so
/// you can see at a glance how many PRs are either ready, behind, or otherwise
/// need a glance. The base icon swaps to a checkmark / refresh / warning glyph
/// when state warrants it, while always reading as a PR tool.
private struct MenuBarLabel: View {
    @ObservedObject var monitor: PRMonitor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
            if attentionCount > 0 {
                Text("\(attentionCount)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
        }
    }

    /// PRs that warrant a glance: anything you can act on or should know about.
    private var attentionCount: Int {
        monitor.prs.filter {
            $0.isReadyToMerge || $0.needsBranchUpdate || $0.isBlocked || $0.hasConflicts
        }.count
    }

    /// Picks the most attention-worthy state. Priority: ready > behind > conflicts >
    /// blocked > default.
    private var iconName: String {
        if monitor.prs.contains(where: { $0.isReadyToMerge }) {
            return "checkmark.seal.fill"
        }
        if monitor.prs.contains(where: { $0.needsBranchUpdate }) {
            return "arrow.triangle.2.circlepath"
        }
        if monitor.prs.contains(where: { $0.hasConflicts }) {
            return "exclamationmark.triangle.fill"
        }
        if monitor.prs.contains(where: { $0.isBlocked }) {
            return "lock.fill"
        }
        return "arrow.triangle.pull"
    }
}

// MARK: - Menu container

/// Top-level menu content. Composes:
///   - Header (title + auth user + Refresh)
///   - Tab switcher
///   - Filters (Search / Repo / Sort) — visible only on PR-list tabs
///   - Tab body (My PRs / Reviewing / Activity / Worktrees)
///   - Footer (notifications-denied banner, last-updated label, Settings, Quit)
private struct MenuContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var monitor: PRMonitor
    @ObservedObject var notifications: NotificationService

    init(state: AppState) {
        self.state = state
        self.monitor = state.monitor
        self.notifications = state.notifications
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if state.authStatus.isAuthenticated {
                TabSwitcher(state: state)
            }
            if state.authStatus.isAuthenticated,
               isPRListTab,
               !currentTabPRs.isEmpty {
                SearchBar(state: state)
                if !currentTabRepos.isEmpty {
                    filtersRow
                }
            }
            Divider()

            switch state.authStatus {
            case .unknown:
                Text("Checking GitHub auth…").foregroundStyle(.secondary)
            case .needsReauth(let reason):
                AuthBanner(
                    reason: reason,
                    isChecking: state.isCheckingAuth,
                    onRetry: { Task { await state.checkAuth() } }
                )
            case .authenticated:
                tabBody
            }

            Divider()
            if notifications.authorizationStatus == .denied {
                notificationsDeniedBanner
            }
            footerRow
        }
        .padding(12)
        .frame(width: 440)
        .task {
            await state.bootstrap()
            // macOS doesn't push notification-permission changes — we have to ask.
            // Refresh on every menu open so the banner clears once the user grants access.
            await state.refreshNotificationAuth()
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        HStack {
            Text("GitPilot").font(.headline)
            if case .authenticated(let login) = state.authStatus {
                Text("@\(login)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            RefreshButton(
                isRefreshing: monitor.isRefreshing || state.isLoadingReviewing,
                isEnabled: state.authStatus.isAuthenticated,
                enrichmentFailureCount: state.currentTab == .reviewing
                    ? state.reviewingEnrichmentFailureCount
                    : monitor.enrichmentFailureCount,
                action: {
                    Task {
                        switch state.currentTab {
                        case .reviewing: await state.refreshReviewing()
                        default:         await monitor.refresh()
                        }
                    }
                }
            )
        }
    }

    private var filtersRow: some View {
        HStack(spacing: 6) {
            Text("Repo").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { state.repoFilter ?? "" },
                set: { state.repoFilter = $0.isEmpty ? nil : $0 }
            )) {
                Text("All (\(currentTabPRs.count))").tag("")
                ForEach(currentTabRepos, id: \.self) { repo in
                    let count = currentTabPRs.filter { "\($0.repoOwner)/\($0.repoName)" == repo }.count
                    Text("\(repo) (\(count))").tag(repo)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)

            Text("Sort").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { state.persistedState.settings.sortOrder },
                set: { newValue in state.updateSettings { $0.sortOrder = newValue } }
            )) {
                ForEach(PRSortOption.allCases, id: \.self) { opt in
                    Text(opt.label).tag(opt)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 130)
        }
    }

    @ViewBuilder
    private var tabBody: some View {
        switch state.currentTab {
        case .myPRs:     myPRsTab
        case .reviewing: reviewingTab
        case .activity:  ActivityTabContent(state: state)
        case .worktrees: WorktreesTabContent(state: state)
        }
    }

    @ViewBuilder
    private var myPRsTab: some View {
        if let err = monitor.lastError {
            Text(err).foregroundStyle(.red).font(.caption)
        }
        if !state.persistedState.pinned.isEmpty {
            PinnedBanner(state: state)
        }
        let visible = state.visiblePRs
        if monitor.prs.isEmpty {
            Text("No open PRs").foregroundStyle(.secondary)
        } else if visible.isEmpty {
            Text(state.persistedState.pinned.isEmpty ? "No PRs match" : "No pinned PRs match")
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { pr in
                        PRRow(pr: pr, state: state)
                    }
                }
            }
            .frame(maxHeight: 500)
        }
    }

    @ViewBuilder
    private var reviewingTab: some View {
        // Loading is driven from bootstrap and the Refresh button; never attach
        // `.task` to a conditional view that the load itself would flicker out
        // of existence (causes an infinite cancel/retry loop).
        if let err = state.reviewingLastError {
            Text(err).foregroundStyle(.red).font(.caption)
        }
        if state.reviewingPRs.isEmpty {
            if state.isLoadingReviewing || !state.didLoadReviewingOnce {
                Text("Loading…").foregroundStyle(.secondary)
            } else {
                Text("No PRs awaiting your review").foregroundStyle(.secondary)
            }
        } else {
            let visible = state.filteredReviewingPRs
            if visible.isEmpty {
                Text("No PRs match").foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { pr in
                            PRRow(pr: pr, state: state)
                        }
                    }
                }
                .frame(maxHeight: 500)
            }
        }
    }

    private var notificationsDeniedBanner: some View {
        // macOS won't re-prompt after the first decision; the only path back is Settings.
        HStack(spacing: 6) {
            Image(systemName: "bell.slash.fill").foregroundStyle(.orange).font(.caption)
            Text("Notifications denied").font(.caption).foregroundStyle(.orange)
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            if let last = monitor.lastRefresh {
                // Wrap in TimelineView so the "Xs ago" string re-evaluates against
                // wall-clock time. Without this, SwiftUI never re-renders the label.
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Text("Updated \(relative(last, now: context.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Tip the user off when persistence is failing — they'll find the
            // full message inside the Settings window where it can be dismissed.
            if state.lastSaveError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .help("Settings failed to save — open Settings to see why.")
            }
            OpenSettingsButton {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.hover)
            .font(.caption)
            .help("Open Settings (⌘,)")

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.hover)
                .font(.caption)
        }
    }

    // MARK: - Helpers

    /// True when the active tab shows a PR list (and thus filters apply).
    private var isPRListTab: Bool {
        state.currentTab == .myPRs || state.currentTab == .reviewing
    }

    /// PRs to draw filter/repo lists from on the active tab.
    private var currentTabPRs: [PullRequest] {
        switch state.currentTab {
        case .reviewing: return state.reviewingPRs
        default:         return monitor.prs
        }
    }

    private var currentTabRepos: [String] {
        Array(Set(currentTabPRs.map { "\($0.repoOwner)/\($0.repoName)" })).sorted()
    }

    /// `now` is passed in so the string re-evaluates against the TimelineView's tick,
    /// not a captured `Date()` from when the view was first laid out.
    private func relative(_ date: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }
}

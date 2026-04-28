import SwiftUI
import AppKit

@main
struct GitPilotApp: App {
    @StateObject private var state = AppState()
    private let terminationObserver: TerminationObserver

    init() {
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
            // app termination. We hop onto the MainActor explicitly so the
            // call to flushPendingSave (which writes the JSON file) blocks
            // termination until it returns — losing the most recent state
            // change to a 250ms debounce would be worse than a brief delay.
            MainActor.assumeIsolated { self?.state?.flushPendingSave() }
        }
    }

    func bind(to state: AppState) { self.state = state }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// Menu bar surface: a pull-request glyph plus an "attention count" badge so
/// you can see at a glance how many PRs are either behind or ready to merge.
/// The base icon swaps to a checkmark or refresh glyph when state warrants it,
/// keeping the visual identity tied to "pull request" while telegraphing status.
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
    /// blocked > default. All three glyphs are pull-request themed so the menu bar
    /// always reads as a PR tool.
    private var iconName: String {
        if monitor.prs.contains(where: { $0.isReadyToMerge }) {
            return "checkmark.seal.fill"          // approved + green-state ready to merge
        }
        if monitor.prs.contains(where: { $0.needsBranchUpdate }) {
            return "arrow.triangle.2.circlepath" // out-of-date, needs rebase
        }
        if monitor.prs.contains(where: { $0.hasConflicts }) {
            return "exclamationmark.triangle.fill" // merge conflicts
        }
        if monitor.prs.contains(where: { $0.isBlocked }) {
            return "lock.fill"                   // blocked by checks/review
        }
        return "arrow.triangle.pull"             // default: GitHub pull-request glyph
    }
}

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
            HStack {
                Text("GitPilot").font(.headline)
                if case .authenticated(let login) = state.authStatus {
                    Text("@\(login)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                RefreshButton(
                    isRefreshing: monitor.isRefreshing || state.isLoadingReviewing,
                    isEnabled: state.authStatus.isAuthenticated,
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

            if case .authenticated = state.authStatus {
                TabSwitcher(state: state)
            }

            // Filters only show on the PR-list tabs.
            if case .authenticated = state.authStatus,
               state.currentTab == .myPRs || state.currentTab == .reviewing,
               !currentTabPRs.isEmpty {
                SearchBar(state: state)
                if !currentTabRepos.isEmpty {
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
            }
            Divider()

            switch state.authStatus {
            case .unknown:
                Text("Checking GitHub auth…").foregroundStyle(.secondary)
            case .needsReauth(let reason):
                AuthBanner(reason: reason, onRetry: { Task { await state.checkAuth() } })
            case .authenticated:
                tabBody
            }

            Divider()
            // Notification permission warning — shown only when the OS is dropping notifications.
            // macOS won't re-prompt after the first decision; the only path back is Settings.
            if notifications.authorizationStatus == .denied {
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
            HStack {
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
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.hover)
                    .font(.caption)
            }
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

    /// PRs to draw filter/repo lists from on the active tab. Reviewing tab uses
    /// state.reviewingPRs; everything else uses monitor.prs.
    private var currentTabPRs: [PullRequest] {
        switch state.currentTab {
        case .reviewing: return state.reviewingPRs
        default:         return monitor.prs
        }
    }

    private var currentTabRepos: [String] {
        Array(Set(currentTabPRs.map { "\($0.repoOwner)/\($0.repoName)" })).sorted()
    }

    @ViewBuilder
    private var tabBody: some View {
        switch state.currentTab {
        case .myPRs:     myPRsTab
        case .reviewing: reviewingTab
        case .activity:  ActivityTabContent(state: state)
        case .worktrees: WorktreesTabContent(state: state)
        }
        // Settings stays below regardless of tab so it's always reachable.
        SettingsSection(state: state)
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
        // No `.task` on a conditional view — that pattern flickers between branches
        // mid-fetch, cancels the in-flight task, and triggers an infinite retry.
        // Loading is driven from bootstrap and the Refresh button instead.
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

    /// `now` is passed in so the string re-evaluates against the TimelineView's tick,
    /// not a captured `Date()` from when the view was first laid out.
    private func relative(_ date: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }
}

/// Search field with a regex toggle. Filters the visible PR list by title/number/repo/branch.
private struct SearchBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search PRs", text: $state.searchText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !state.searchText.isEmpty {
                Button(action: { state.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Clear")
            }
            // Regex toggle. Highlighted background when active so the mode is visible at a glance.
            Button(action: { state.useRegex.toggle() }) {
                Text(".*")
                    .font(.system(.caption, design: .monospaced).weight(state.useRegex ? .bold : .regular))
                    .foregroundStyle(state.useRegex ? Color.accentColor : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(state.useRegex ? Color.accentColor.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.borderless)
            .help(state.useRegex ? "Regex search (on)" : "Regex search (off)")
            // Inline regex compile error indicator.
            if let regexErr = state.regexError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .help("Invalid regex: \(regexErr)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Circular-arrow button that spins while a refresh is in flight and is
/// disabled while either refreshing or unauthenticated, so users can't spam-click.
private struct RefreshButton: View {
    let isRefreshing: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var degrees: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .imageScale(.medium)
                .rotationEffect(.degrees(degrees))
        }
        .buttonStyle(.hover)
        .disabled(!isEnabled || isRefreshing)
        .help(isRefreshing ? "Refreshing…" : "Refresh")
        .onChange(of: isRefreshing) { refreshing in
            if refreshing {
                // Repeat-forever animation drives a continuous spin until isRefreshing flips false.
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    degrees = 360
                }
            } else {
                // Stop any in-flight animation immediately and snap back to upright.
                withAnimation(.linear(duration: 0.15)) {
                    degrees = 0
                }
            }
        }
    }
}

private struct AuthBanner: View {
    let reason: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("GitHub sign-in required", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.weight(.semibold))
            Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Text("Run this in a terminal:").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            HStack(spacing: 6) {
                Text("gh auth login")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Button("Copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString("gh auth login", forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            HStack {
                Spacer()
                Button("I've signed in — retry", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct PRRow: View {
    let pr: PullRequest
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if state.expandedPRs.contains(pr.id) {
                ChecksList(pr: pr).padding(.leading, 36).padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        // Lets the entire row body act as a click target for expand. SwiftUI
        // gives child buttons priority, so Rebase / Open / ⋯ keep working.
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: 6)
        .onTapGesture { state.toggleExpanded(pr.id) }
        .contextMenu { contextMenuContent }
    }

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 6) {
            // Disclosure chevron at the very left — Mac-native expand affordance.
            // Rotates 90° instead of swapping symbols so the transition reads as
            // a single control. Fixed-height frame keeps it vertically centered on
            // the title's first line regardless of how many lines the title wraps to.
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 18, alignment: .center)
                .rotationEffect(.degrees(state.expandedPRs.contains(pr.id) ? 90 : 0))
                .animation(.easeOut(duration: 0.15), value: state.expandedPRs.contains(pr.id))
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16, height: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(pr.title)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if state.isPinned(pr.id) {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color.accentColor)
                            .help("Pinned — only pinned PRs notify")
                    }
                    if state.isAutoRebase(pr.id) {
                        Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.yellow)
                            .help("Auto-rebase enabled")
                    }
                    if state.isAutoMerge(pr.id) {
                        Image(systemName: "arrow.triangle.merge").font(.caption2).foregroundStyle(.green)
                            .help("Auto-merge enabled — GitHub will merge once requirements are met")
                    }
                    if state.persistedState.worktrees[pr.id] != nil {
                        Image(systemName: "folder.fill").font(.caption2).foregroundStyle(.brown)
                            .help("Worktree active")
                    }
                }
                // Reviewer-source badges only render on rows that have them (Reviewing tab).
                if !pr.reviewerSources.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(pr.reviewerSources, id: \.self) { source in
                            Text(reviewerSourceLabel(source))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                                )
                        }
                    }
                    .padding(.top, 1)
                }
                // Metadata + actions on a compact line below.
                HStack(spacing: 6) {
                    // Use verbatim to bypass SwiftUI's locale-aware integer formatting.
                    // GitHub PR numbers are never displayed with thousand separators.
                    Text(verbatim: "#\(pr.number)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.secondary).font(.caption)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if pr.changedFiles > 0 {
                        Text("·").foregroundStyle(.secondary).font(.caption)
                        Text(verbatim: "+\(pr.additions) −\(pr.deletions) · \(pr.changedFiles)f")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if let until = state.snoozedUntil(pr.id), until > Date() {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            let remaining = max(0, until.timeIntervalSince(context.date))
                            HStack(spacing: 2) {
                                Image(systemName: "moon.zzz.fill").font(.caption2)
                                Text(formatDuration(remaining)).font(.caption)
                            }
                            .foregroundStyle(.purple)
                        }
                    }
                    Spacer()
                    if !pr.isLoading && pr.needsBranchUpdate {
                        let isRebasing = state.rebaseInFlight.contains(pr.id)
                        Button(isRebasing ? "Rebasing…" : "Rebase") {
                            Task { await state.rebase(prId: pr.id) }
                        }
                        .buttonStyle(.hover)
                        .font(.caption)
                        .disabled(isRebasing)
                    }
                    Button("Open") { NSWorkspace.shared.open(pr.url) }
                        .buttonStyle(.hover)
                        .font(.caption)
                    // Overflow menu — same content as the right-click context menu, but
                    // discoverable. Mac convention is to offer both right-click and an
                    // explicit affordance like this for the same menu.
                    Menu {
                        contextMenuContent
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .hoverHighlight(cornerRadius: 4)
                }
            }
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button(state.isPinned(pr.id) ? "Unpin" : "Pin") {
            state.togglePin(pr.id)
        }
        Divider()
        if state.isSnoozed(pr.id) {
            Button("Cancel snooze") { state.unsnooze(pr.id) }
        } else {
            Menu("Snooze") {
                Button("30 minutes") { state.snooze(pr.id, for: 30 * 60) }
                Button("2 hours")    { state.snooze(pr.id, for: 2 * 3600) }
                Button("Until tomorrow 9 AM") {
                    state.snooze(pr.id, for: secondsUntilTomorrow9AM())
                }
            }
        }
        Divider()
        Button(state.isAutoRebase(pr.id) ? "Disable auto-rebase" : "Enable auto-rebase") {
            state.toggleAutoRebase(pr.id)
        }
        let inFlight = state.autoMergeInFlight.contains(pr.id)
        Button(autoMergeMenuLabel(inFlight: inFlight)) {
            Task { await state.toggleAutoMerge(pr.id) }
        }
        .disabled(inFlight)
        Divider()
        // Worktree actions. "Create worktree" creates a worktree at the configured root
        // and opens it in the editor; "Open worktree" reopens an existing one.
        if state.persistedState.worktrees[pr.id] != nil {
            Button("Open worktree in editor") {
                state.openWorktreeInEditor(prId: pr.id)
            }
            Button("Remove worktree") {
                Task { await state.removeWorktree(prId: pr.id) }
            }
        } else {
            let inFlight = state.worktreeInFlight.contains(pr.id)
            Button(inFlight ? "Creating worktree…" : "Create worktree") {
                Task { await state.createAndOpenWorktree(for: pr) }
            }
            .disabled(inFlight)
        }
        Divider()
        Button("Open in browser") { NSWorkspace.shared.open(pr.url) }
        Button("Copy URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
        }
    }

    private func secondsUntilTomorrow9AM() -> TimeInterval {
        let cal = Calendar.current
        let now = Date()
        var components = cal.dateComponents([.year, .month, .day], from: now)
        components.day = (components.day ?? 0) + 1
        components.hour = 9
        components.minute = 0
        let target = cal.date(from: components) ?? now.addingTimeInterval(8 * 3600)
        return max(60, target.timeIntervalSince(now))
    }

    /// Human label for a reviewer-source entry — shown as a small pill on the row.
    private func reviewerSourceLabel(_ source: ReviewerSource) -> String {
        switch source.kind {
        case .direct: return "you"
        case .team:   return "@\(source.teamSlug ?? "team")"
        }
    }

    private func autoMergeMenuLabel(inFlight: Bool) -> String {
        if inFlight {
            return state.isAutoMerge(pr.id) ? "Disabling auto-merge…" : "Enabling auto-merge…"
        }
        return state.isAutoMerge(pr.id) ? "Disable auto-merge" : "Enable auto-merge"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private var icon: String {
        switch pr.displayState {
        case .loading:              return "circle.dotted"
        case .readyToMerge:         return "checkmark.circle.fill"
        case .behind:               return "arrow.triangle.2.circlepath"
        case .conflicts:            return "exclamationmark.triangle.fill"
        case .blockedByTests:       return "xmark.octagon.fill"
        case .blockedByReview:      return "person.crop.circle.badge.exclamationmark"
        case .blockedTestsRunning:  return "clock.fill"
        case .blocked:              return "lock.fill"
        case .draft:                return "pencil.circle"
        case .other:                return "circle"
        }
    }

    private var color: Color {
        switch pr.displayState {
        case .loading, .other, .draft: return .secondary
        case .readyToMerge:            return .green
        case .behind:                  return .orange
        case .conflicts, .blockedByTests: return .red
        case .blockedByReview:         return .blue
        case .blockedTestsRunning:     return .yellow
        case .blocked:                 return .yellow
        }
    }

    private var statusText: String {
        if pr.isLoading {
            return pr.isDraft ? "loading · draft" : "loading…"
        }
        var parts: [String] = []
        switch pr.displayState {
        case .readyToMerge:        parts.append("ready to merge")
        case .behind:              parts.append("behind base")
        case .blockedByTests:      parts.append("tests failing")
        case .blockedByReview:     parts.append("needs review")
        case .blockedTestsRunning: parts.append("tests running")
        case .blocked:             parts.append("blocked")
        case .conflicts:           parts.append("merge conflict")
        case .draft:               parts.append("draft")
        case .other:               parts.append(friendlyMergeState(pr.mergeStateStatus ?? .unknown))
        case .loading:             break
        }
        // Add review decision unless it's already implied by the display state.
        if let r = pr.reviewDecision,
           pr.displayState != .readyToMerge,
           pr.displayState != .blockedByReview {
            parts.append(friendlyReviewDecision(r))
        }
        if pr.isDraft && pr.displayState != .draft { parts.append("draft") }
        return parts.joined(separator: " · ")
    }

    /// Maps GitHub's `PullRequestReviewDecision` enum into something a human reads.
    private func friendlyReviewDecision(_ raw: String) -> String {
        switch raw {
        case "APPROVED":          return "approved"
        case "REVIEW_REQUIRED":   return "needs review"
        case "CHANGES_REQUESTED": return "changes requested"
        default:                  return raw.lowercased().replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Friendly labels for `MergeStateStatus` values that don't get a dedicated
    /// displayState branch but might still surface (e.g. UNSTABLE, HAS_HOOKS).
    private func friendlyMergeState(_ state: MergeStateStatus) -> String {
        switch state {
        case .clean:    return "clean"
        case .blocked:  return "blocked"
        case .behind:   return "behind base"
        case .unstable: return "non-required checks failing"
        case .dirty:    return "merge conflict"
        case .hasHooks: return "ready (with hooks)"
        case .unknown:  return "checking…"
        }
    }
}

/// Top-level tab switcher. Four tabs, one row, hover-highlighted, accent-tinted
/// when active. Switches state.currentTab.
private struct TabSwitcher: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
    }

    private func tabButton(for tab: AppTab) -> some View {
        let isActive = state.currentTab == tab
        return Button(action: { state.currentTab = tab }) {
            HStack(spacing: 4) {
                Image(systemName: tab.icon).font(.caption)
                Text(tab.label).font(.caption)
            }
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            // Force the entire pill rect to be the hit-testing area. Without this,
            // SwiftUI's default for Button-with-HStack-label is "tight" — only the
            // text + icon glyphs accept clicks, with the surrounding padding inert.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 5)
    }
}

/// Activity tab — chronological event log (newest first), capped per ActivityRetention.
private struct ActivityTabContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.persistedState.activity.isEmpty {
                Text("No activity yet — events show up as PRs change state and you take actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                let events = Array(state.persistedState.activity.reversed())
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { event in
                            ActivityRow(event: event, state: state)
                        }
                    }
                }
                .frame(maxHeight: 460)
                Text("Showing last \(events.count) events · capped at \(ActivityRetention.maxEntries) entries / \(ActivityRetention.maxAgeDays) days")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent
    @ObservedObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16, height: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: "#\(event.prNumber)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(label).font(.caption)
                    Spacer()
                    Text(timeFormatter.string(from: event.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(event.prTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail = event.detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: 4)
        .onTapGesture {
            // Jump to the PR if it's still in the list.
            if let pr = state.monitor.prs.first(where: { $0.id == event.prId })
                ?? state.reviewingPRs.first(where: { $0.id == event.prId }) {
                NSWorkspace.shared.open(pr.url)
            }
        }
    }

    private var label: String {
        switch event.kind {
        case .becameBehind:        return "behind base"
        case .becameReady:         return "ready to merge"
        case .becameTestsFailing:  return "tests failing"
        case .becameConflicts:     return "merge conflict"
        case .rebased:             return "rebased"
        case .autoRebased:         return "auto-rebased"
        case .autoRebaseFailed:    return "auto-rebase failed"
        case .merged:              return "merged"
        case .pinned:              return "pinned"
        case .unpinned:            return "unpinned"
        case .snoozed:             return "snoozed"
        case .unsnoozed:           return "snooze cancelled"
        case .autoMergeEnabled:    return "auto-merge enabled"
        case .autoMergeDisabled:   return "auto-merge disabled"
        case .appeared:            return "appeared"
        case .disappeared:         return "left list"
        }
    }

    private var icon: String {
        switch event.kind {
        case .becameBehind, .rebased, .autoRebased: return "arrow.triangle.2.circlepath"
        case .becameReady:                          return "checkmark.circle.fill"
        case .becameTestsFailing, .autoRebaseFailed: return "xmark.octagon.fill"
        case .becameConflicts:                      return "exclamationmark.triangle.fill"
        case .merged:                               return "arrow.triangle.merge"
        case .pinned, .unpinned:                    return "pin.fill"
        case .snoozed, .unsnoozed:                  return "moon.zzz.fill"
        case .autoMergeEnabled, .autoMergeDisabled: return "bolt.fill"
        case .appeared:                             return "plus.circle"
        case .disappeared:                          return "minus.circle"
        }
    }

    private var color: Color {
        switch event.kind {
        case .becameReady, .merged, .rebased, .autoRebased: return .green
        case .becameTestsFailing, .autoRebaseFailed, .becameConflicts: return .red
        case .becameBehind: return .orange
        case .pinned: return Color.accentColor
        case .snoozed: return .purple
        default: return .secondary
        }
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }
}

/// Worktrees tab — lists all managed worktrees with status (clean / dirty / missing)
/// and remove buttons. Source of truth is persistedState.worktrees.
private struct WorktreesTabContent: View {
    @ObservedObject var state: AppState
    /// Status snapshot per PR id. Re-checked on tab open and after operations.
    @State private var statusByPRId: [String: WorktreeStatus] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.persistedState.worktrees.isEmpty {
                Text("No worktrees yet — use the ⋯ menu on a PR to create one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(state.persistedState.worktrees.keys.sorted()), id: \.self) { prId in
                            if let path = state.persistedState.worktrees[prId] {
                                WorktreeRow(
                                    prId: prId,
                                    path: path,
                                    status: statusByPRId[prId] ?? .clean,
                                    state: state,
                                    onRefresh: { refreshStatus(prId: prId, path: path) }
                                )
                            }
                        }
                    }
                }
                .frame(maxHeight: 460)
                Text("Cleanup: dirty worktrees are never auto-removed; merged PRs prompt you to clean up.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task { refreshAllStatuses() }
    }

    private func refreshAllStatuses() {
        var snapshot: [String: WorktreeStatus] = [:]
        for (prId, path) in state.persistedState.worktrees {
            snapshot[prId] = WorktreeManager.status(at: URL(fileURLWithPath: path))
        }
        statusByPRId = snapshot
    }

    private func refreshStatus(prId: String, path: String) {
        statusByPRId[prId] = WorktreeManager.status(at: URL(fileURLWithPath: path))
    }
}

private struct WorktreeRow: View {
    let prId: String
    let path: String
    let status: WorktreeStatus
    @ObservedObject var state: AppState
    let onRefresh: () -> Void
    @State private var confirmingDirtyRemove = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16, height: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(prTitle).font(.caption).lineLimit(1).truncationMode(.tail)
                Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if case .dirty(let summary) = status {
                    Text("dirty: \(summary)").font(.caption2).foregroundStyle(.red).lineLimit(1)
                }
            }
            Spacer()
            Button("Open") {
                state.openWorktreeInEditor(prId: prId)
            }
            .buttonStyle(.hover)
            .font(.caption)
            Button(role: .destructive) {
                // Dirty worktrees require explicit confirmation to avoid losing
                // uncommitted changes. Clean ones remove immediately.
                if case .dirty = status {
                    confirmingDirtyRemove = true
                } else {
                    Task {
                        await state.removeWorktree(prId: prId, force: false)
                        onRefresh()
                    }
                }
            } label: {
                Text("Remove")
            }
            .buttonStyle(.hover)
            .font(.caption)
            .confirmationDialog(
                "Worktree has uncommitted changes. Remove anyway?",
                isPresented: $confirmingDirtyRemove
            ) {
                Button("Remove and discard changes", role: .destructive) {
                    Task {
                        await state.removeWorktree(prId: prId, force: true)
                        onRefresh()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(dirtyMessage)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .hoverHighlight(cornerRadius: 5)
    }

    private var dirtyMessage: String {
        if case .dirty(let summary) = status {
            return "Discarding will permanently delete uncommitted changes: \(summary)"
        }
        return ""
    }

    private var prTitle: String {
        // Look up the PR by id if it's still in our list, else show the path's last component.
        if let pr = state.monitor.prs.first(where: { $0.id == prId })
            ?? state.reviewingPRs.first(where: { $0.id == prId }) {
            return "#\(pr.number) · \(pr.title)"
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var icon: String {
        switch status {
        case .clean:   return "folder.fill"
        case .dirty:   return "exclamationmark.triangle.fill"
        case .missing: return "questionmark.folder"
        }
    }

    private var color: Color {
        switch status {
        case .clean:   return .green
        case .dirty:   return .red
        case .missing: return .secondary
        }
    }
}

/// Adds a subtle hover background so the user can see what's clickable.
/// Works in both light and dark mode by using a primary-color tint with low opacity.
private struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 5) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}

/// Borderless-style button that adds a hover background and a press-state dim,
/// so action buttons (Rebase / Open / Refresh / etc.) feel responsive on Mac.
private struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverButtonContent(configuration: configuration)
    }
}

private struct HoverButtonContent: View {
    let configuration: HoverButtonStyle.Configuration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundFill)
            )
            .opacity(configuration.isPressed ? 0.55 : 1.0)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var backgroundFill: Color {
        if configuration.isPressed { return Color.primary.opacity(0.15) }
        if hovering { return Color.primary.opacity(0.10) }
        return Color.clear
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    static var hover: HoverButtonStyle { HoverButtonStyle() }
}

/// Inline check list, rendered when a row is expanded. Each row maps directly
/// to a GitHub status context or check run and links to wherever it ran —
/// Buildkite, GitHub Actions, or anything else GitHub knows about.
private struct ChecksList: View {
    let pr: PullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if pr.checks.isEmpty {
                Text(pr.isLoading ? "Loading checks…" : "No checks reported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedChecks) { check in
                    CheckRow(check: check)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    /// Order: failures and errors first, then pending/expected, then successes.
    /// Within each tier, alphabetical by name.
    private var sortedChecks: [PRCheck] {
        pr.checks.sorted { lhs, rhs in
            let lhsRank = rank(for: lhs.state)
            let rhsRank = rank(for: rhs.state)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func rank(for state: CheckRollupState) -> Int {
        switch state {
        case .failure, .error:    return 0
        case .pending, .expected: return 1
        case .success:            return 2
        case .unknown:            return 3
        }
    }
}

private struct CheckRow: View {
    let check: PRCheck

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            Text(check.name).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let url = check.url {
                Button(action: { NSWorkspace.shared.open(url) }) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Open this check (\(url.host ?? "external"))")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: 4)
        .onTapGesture {
            if let url = check.url { NSWorkspace.shared.open(url) }
        }
    }

    private var icon: String {
        switch check.state {
        case .success:            return "checkmark.circle.fill"
        case .failure, .error:    return "xmark.octagon.fill"
        case .pending, .expected: return "clock.fill"
        case .unknown:            return "circle.dotted"
        }
    }

    private var color: Color {
        switch check.state {
        case .success:            return .green
        case .failure, .error:    return .red
        case .pending, .expected: return .yellow
        case .unknown:            return .secondary
        }
    }
}

/// Banner shown at the top of the PR list whenever any PR is pinned.
/// Communicates the "only pinned PRs notify" rule and offers a one-click escape.
/// Shown only when at least one PR is pinned. Hosts the "Only show pinned" toggle
/// (which is the user's explicit visibility filter) and the "Unpin all" escape hatch.
/// The toggle is intentionally separate from notification scoping: notifications
/// always fire only for pinned PRs whenever any are pinned.
private struct PinnedBanner: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill").foregroundStyle(Color.accentColor).font(.caption)
                Text("\(state.persistedState.pinned.count) pinned · only pinned PRs notify")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Unpin all") { state.unpinAll() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            Toggle(isOn: Binding(
                get: { state.persistedState.showPinnedOnly },
                set: { state.setShowPinnedOnly($0) }
            )) {
                Text("Only show pinned").font(.caption)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Collapsible settings section. Lives at the bottom of the menu so it doesn't
/// dominate visually when collapsed but is one click away when needed.
private struct SettingsSection: View {
    @ObservedObject var state: AppState
    /// Also observe the monitor so the per-repo list re-renders when PRs load.
    /// `seenRepos` reads from monitor.prs, which lives on a separate ObservableObject;
    /// without this, the picker stays empty until something else on AppState publishes.
    @ObservedObject var monitor: PRMonitor
    @State private var isExpanded = false

    init(state: AppState) {
        self.state = state
        self.monitor = state.monitor
    }

    private static let pollOptions: [(label: String, seconds: Double)] = [
        ("10s", 10), ("30s", 30), ("1m", 60), ("2m", 120), ("5m", 300),
    ]

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            settingsContent
        } label: {
            // SwiftUI's DisclosureGroup label isn't fully clickable on macOS — only
            // the chevron toggles. Add an explicit tap gesture so clicking the label
            // text also expands/collapses, which matches the intuitive behavior.
            Text("Settings")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .hoverHighlight(cornerRadius: 4)
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                }
        }
    }

    /// Label for the per-repo "Default" option, showing what method will actually be
    /// used so the user doesn't have to guess. e.g. "Default (Squash)" or just
    /// "Default" if the repo allows nothing.
    private func defaultLabel(for allowed: Set<String>) -> String {
        if let method = state.autoPickedMethod(allowed: allowed) {
            return "Default (\(method.label))"
        }
        return "Default (no method allowed)"
    }

    @ViewBuilder
    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Poll interval").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { state.persistedState.settings.pollIntervalSeconds },
                        set: { newValue in
                            state.updateSettings { $0.pollIntervalSeconds = newValue }
                        }
                    )) {
                        ForEach(Self.pollOptions, id: \.seconds) { opt in
                            Text(opt.label).tag(opt.seconds)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 90)
                }
                Toggle("Notify on rebase needed", isOn: Binding(
                    get: { state.persistedState.settings.enableRebaseNotification },
                    set: { v in state.updateSettings { $0.enableRebaseNotification = v } }
                ))
                .font(.caption)
                Toggle("Notify when ready to merge", isOn: Binding(
                    get: { state.persistedState.settings.enableReadyNotification },
                    set: { v in state.updateSettings { $0.enableReadyNotification = v } }
                ))
                .font(.caption)
                Toggle("Notify on CI failure", isOn: Binding(
                    get: { state.persistedState.settings.enableTestsFailingNotification },
                    set: { v in state.updateSettings { $0.enableTestsFailingNotification = v } }
                ))
                .font(.caption)
                Toggle("Notify on auto-rebase failure", isOn: Binding(
                    get: { state.persistedState.settings.enableAutoRebaseFailureNotification },
                    set: { v in state.updateSettings { $0.enableAutoRebaseFailureNotification = v } }
                ))
                .font(.caption)
                // Auto-merge method per repo. Default = auto-pick using SQUASH > MERGE > REBASE
                // among whatever the repo allows. Each option in the picker shows the resolved
                // method so the user sees exactly what will run.
                if !state.seenRepos.isEmpty {
                    Text("Auto-merge method per repo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(state.seenRepos, id: \.key) { repo in
                        HStack {
                            Text(repo.key).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { state.persistedState.perRepoMergeMethod[repo.key] ?? "" },
                                set: { newValue in
                                    state.setPerRepoMergeMethod(repo.key, method: newValue.isEmpty ? nil : newValue)
                                }
                            )) {
                                Text(defaultLabel(for: repo.allowed)).tag("")
                                ForEach(GitHubClient.MergeMethod.allCases, id: \.rawValue) { m in
                                    if repo.allowed.contains(m.rawValue) {
                                        Text(m.label).tag(m.rawValue)
                                    }
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 160)
                        }
                    }
                }
                Divider().padding(.vertical, 2)
                HStack {
                    Text("Worktree root").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    TextField("~/worktrees/gitpilot", text: Binding(
                        get: { state.persistedState.settings.worktreeRoot },
                        set: { state.updateWorktreeRoot($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 220)
                }
                HStack {
                    Text("Editor").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { state.persistedState.settings.editorCommand },
                        set: { state.updateEditorCommand($0) }
                    )) {
                        Text("Auto").tag("auto")
                        Text("Cursor").tag("cursor")
                        Text("VSCode").tag("code")
                        Text("Sublime").tag("subl")
                        Text("Finder").tag("finder")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 130)
                }
                Divider().padding(.vertical, 2)
                HStack {
                    Text("Verify notification setup").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Send test notification") {
                        Task { await state.fireTestNotifications() }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
        }
        .padding(.top, 4)
    }
}

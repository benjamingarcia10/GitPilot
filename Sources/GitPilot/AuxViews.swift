import SwiftUI
import AppKit

// MARK: - Search bar

/// Search field with a regex toggle. Filters the visible PR list by title/number/repo/branch.
struct SearchBar: View {
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

// MARK: - Refresh button

/// Circular-arrow button that spins while a refresh is in flight and is
/// disabled while either refreshing or unauthenticated, so users can't spam-click.
/// The hover tooltip surfaces the per-PR enrichment failure count when non-zero —
/// otherwise users would see rows stuck in "loading…" with no signal as to why.
struct RefreshButton: View {
    let isRefreshing: Bool
    let isEnabled: Bool
    /// Number of per-PR enrichment failures from the last refresh. Displayed as
    /// a small red badge if > 0, with a tooltip explaining what it means.
    var enrichmentFailureCount: Int = 0
    let action: () -> Void

    @State private var degrees: Double = 0

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.medium)
                    .rotationEffect(.degrees(degrees))
                if enrichmentFailureCount > 0 {
                    // Small red dot — visible without dominating the menu bar header.
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .offset(x: 4, y: -2)
                }
            }
        }
        .buttonStyle(.hover)
        .disabled(!isEnabled || isRefreshing)
        .help(tooltip)
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

    private var tooltip: String {
        if isRefreshing { return "Refreshing…" }
        if enrichmentFailureCount > 0 {
            let plural = enrichmentFailureCount == 1 ? "PR" : "PRs"
            return "Refresh — \(enrichmentFailureCount) \(plural) failed to load detail. Retry."
        }
        return "Refresh"
    }
}

// MARK: - Pinned banner

/// Shown only when at least one PR is pinned. Hosts the "Only show pinned" toggle
/// (the user's explicit visibility filter) and the "Unpin all" escape hatch.
/// The toggle is intentionally separate from notification scoping: notifications
/// always fire only for pinned PRs whenever any are pinned, regardless of the toggle.
struct PinnedBanner: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill").foregroundStyle(Color.accentColor).font(.caption)
                Text(headerText)
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

    /// Header text mentions both pinned count and any active snoozes so users
    /// can see why notifications might appear silent.
    private var headerText: String {
        let pinned = state.persistedState.pinned.count
        let snoozedActive = state.persistedState.snoozedUntil
            .filter { $0.value > Date() }
            .count
        var parts: [String] = ["\(pinned) pinned · only pinned PRs notify"]
        if snoozedActive > 0 {
            parts.append("\(snoozedActive) snoozed")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Auth banner

/// Shown when GitHub credentials aren't usable. macOS won't re-prompt after
/// the first decision, so we offer a `gh auth login` shortcut and a retry button.
struct AuthBanner: View {
    let reason: String
    let isChecking: Bool
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
                Button(isChecking ? "Checking…" : "I've signed in — retry", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isChecking)
            }
            .padding(.top, 4)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Settings disclosure

/// Collapsible settings section. Lives at the bottom of the menu so it doesn't
/// dominate visually when collapsed but is one click away when needed.
struct SettingsSection: View {
    @ObservedObject var state: AppState
    /// Also observe the monitor so the per-repo list re-renders when PRs load.
    /// `seenRepos` is published from AppState but driven by monitor updates;
    /// observing both keeps the UI in sync after the first refresh completes.
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
            // text also expands/collapses, matching the intuitive behavior.
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
            if let err = state.lastSaveError {
                saveErrorBanner(err)
            }
            pollIntervalRow
            notificationToggles
            perRepoMergeMethods
            Divider().padding(.vertical, 2)
            worktreeRootRow
            editorPickerRow
            Divider().padding(.vertical, 2)
            testNotificationRow
        }
        .padding(.top, 4)
    }

    /// Inline warning shown when the most recent persistence write failed —
    /// without this, a save problem (full disk, permissions) would silently
    /// drop your pinned/snooze/auto-* state with no user-visible signal.
    private func saveErrorBanner(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings failed to save").font(.caption.weight(.semibold))
                Text(err).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(err)
            }
            Spacer()
            Button(action: { state.dismissSaveError() }) {
                Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss (will reappear if the next save also fails)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var pollIntervalRow: some View {
        HStack {
            Text("Poll interval").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: Binding(
                get: { state.persistedState.settings.pollIntervalSeconds },
                set: { newValue in state.updateSettings { $0.pollIntervalSeconds = newValue } }
            )) {
                ForEach(Self.pollOptions, id: \.seconds) { opt in
                    Text(opt.label).tag(opt.seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 90)
        }
    }

    @ViewBuilder
    private var notificationToggles: some View {
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
        Toggle("Notify on merge conflict", isOn: Binding(
            get: { state.persistedState.settings.enableConflictsNotification },
            set: { v in state.updateSettings { $0.enableConflictsNotification = v } }
        ))
        .font(.caption)
        .help("Fires when a PR transitions to merge conflict — actionable, since it requires a local resolve.")
        Toggle("Notify on auto-rebase failure", isOn: Binding(
            get: { state.persistedState.settings.enableAutoRebaseFailureNotification },
            set: { v in state.updateSettings { $0.enableAutoRebaseFailureNotification = v } }
        ))
        .font(.caption)
        Toggle("Notify on auto-merge failure", isOn: Binding(
            get: { state.persistedState.settings.enableAutoMergeFailureNotification },
            set: { v in state.updateSettings { $0.enableAutoMergeFailureNotification = v } }
        ))
        .font(.caption)
        Toggle("Notify when auto-merge completes", isOn: Binding(
            get: { state.persistedState.settings.enableAutoMergeCompletedNotification },
            set: { v in state.updateSettings { $0.enableAutoMergeCompletedNotification = v } }
        ))
        .font(.caption)
        .help("Off by default — activity log already records every merge.")
        Toggle("Notify on manual rebase failure", isOn: Binding(
            get: { state.persistedState.settings.enableManualRebaseFailureNotification },
            set: { v in state.updateSettings { $0.enableManualRebaseFailureNotification = v } }
        ))
        .font(.caption)
        .help("Off by default — the inline button gives you contextual feedback. Opt in if you tend to walk away after clicking Rebase.")
        Toggle("Notify on worktree failure", isOn: Binding(
            get: { state.persistedState.settings.enableWorktreeFailureNotification },
            set: { v in state.updateSettings { $0.enableWorktreeFailureNotification = v } }
        ))
        .font(.caption)
    }

    /// Auto-merge method per repo. Default = auto-pick using SQUASH > MERGE > REBASE
    /// among whatever the repo allows. Each option in the picker shows the resolved
    /// method so the user sees exactly what will run. Single-method repos render
    /// as a static label since there's nothing to override.
    @ViewBuilder
    private var perRepoMergeMethods: some View {
        if !state.seenRepos.isEmpty {
            Text("Auto-merge method per repo")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(state.seenRepos, id: \.key) { repo in
                HStack {
                    Text(repo.key).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    repoMethodControl(for: repo)
                }
            }
        }
    }

    /// Static label when only one method is allowed (nothing to override);
    /// otherwise a picker with Default + each explicit alternative.
    @ViewBuilder
    private func repoMethodControl(for repo: (key: String, allowed: Set<String>)) -> some View {
        if repo.allowed.count <= 1 {
            Text(defaultLabel(for: repo.allowed))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
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

    private var worktreeRootRow: some View {
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
    }

    private var editorPickerRow: some View {
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
    }

    private var testNotificationRow: some View {
        HStack {
            Text("Verify notification setup").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(state.isFiringTestNotifications ? "Sending…" : "Send test notification") {
                Task { await state.fireTestNotifications() }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(state.isFiringTestNotifications)
        }
    }
}

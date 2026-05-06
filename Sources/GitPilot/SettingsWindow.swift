import SwiftUI
import AppKit

// MARK: - Settings window

/// Top-level Settings window. Hosted by the `Settings { }` scene in
/// `GitPilotApp` so macOS gives us Cmd+, and the standard window chrome
/// for free. Tabs follow the native pattern (icon + title across the top).
struct SettingsView: View {
    @ObservedObject var state: AppState

    /// Tab identity — drives the toolbar selection and lets us switch
    /// programmatically (e.g. footer "Settings…" button could deep-link to
    /// a tab in the future).
    enum Tab: Hashable {
        case general, notifications, repos
    }

    @State private var selection: Tab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsTab(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)

            NotificationsSettingsTab(state: state)
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
                .tag(Tab.notifications)

            ReposSettingsTab(state: state)
                .tabItem { Label("Repos", systemImage: "square.stack.3d.up") }
                .tag(Tab.repos)
        }
        .frame(width: 520, height: 540)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var state: AppState

    private static let pollOptions: [(label: String, seconds: Double)] = [
        ("10 seconds", 10), ("30 seconds", 30), ("1 minute", 60),
        ("2 minutes", 120), ("5 minutes", 300),
    ]

    var body: some View {
        Form {
            if let err = state.lastSaveError {
                Section {
                    SaveErrorBanner(message: err) { state.dismissSaveError() }
                }
            }

            Section {
                Picker("Poll interval", selection: Binding(
                    get: { state.persistedState.settings.pollIntervalSeconds },
                    set: { v in state.updateSettings { $0.pollIntervalSeconds = v } }
                )) {
                    ForEach(Self.pollOptions, id: \.seconds) { opt in
                        Text(opt.label).tag(opt.seconds)
                    }
                }

                Picker("Sort order", selection: Binding(
                    get: { state.persistedState.settings.sortOrder },
                    set: { v in state.updateSettings { $0.sortOrder = v } }
                )) {
                    ForEach(PRSortOption.allCases, id: \.self) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
            } header: {
                Text("PRs")
            }

            Section {
                TextField("Worktree root", text: Binding(
                    get: { state.persistedState.settings.worktreeRoot },
                    set: { state.updateWorktreeRoot($0) }
                ), prompt: Text("~/worktrees/gitpilot"))

                Picker("Editor", selection: Binding(
                    get: { state.persistedState.settings.editorCommand },
                    set: { state.updateEditorCommand($0) }
                )) {
                    Text("Auto").tag("auto")
                    Text("Cursor").tag("cursor")
                    Text("VSCode").tag("code")
                    Text("Sublime").tag("subl")
                    Text("Finder").tag("finder")
                }
            } header: {
                Text("Worktrees")
            } footer: {
                Text("\"Auto\" prefers Cursor, then VSCode, then Sublime — falling back to Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notifications

private struct NotificationsSettingsTab: View {
    @ObservedObject var state: AppState
    @ObservedObject var notifications: NotificationService

    init(state: AppState) {
        self.state = state
        self.notifications = state.notifications
    }

    var body: some View {
        Form {
            if let err = state.lastSaveError {
                Section {
                    SaveErrorBanner(message: err) { state.dismissSaveError() }
                }
            }

            if notifications.authorizationStatus == .denied {
                Section {
                    NotificationsDeniedBanner()
                }
            }

            Section {
                toggle("Rebase needed",
                       help: "Fires when a PR's base branch advances and the PR needs an update.",
                       keyPath: \.enableRebaseNotification)
                toggle("Ready to merge",
                       help: nil,
                       keyPath: \.enableReadyNotification)
                toggle("CI failure",
                       help: nil,
                       keyPath: \.enableTestsFailingNotification)
                toggle("Merge conflict",
                       help: "Fires when a PR transitions to merge conflict — actionable, since it requires a local resolve.",
                       keyPath: \.enableConflictsNotification)
            } header: {
                Text("PR status")
            }

            Section {
                toggle("Auto-rebase failure",
                       help: nil,
                       keyPath: \.enableAutoRebaseFailureNotification)
                toggle("Auto-merge failure",
                       help: nil,
                       keyPath: \.enableAutoMergeFailureNotification)
                toggle("Auto-merge completed",
                       help: "Off by default — activity log already records every merge.",
                       keyPath: \.enableAutoMergeCompletedNotification)
                toggle("Manual rebase failure",
                       help: "Off by default — the inline button gives you contextual feedback. Opt in if you tend to walk away after clicking Rebase.",
                       keyPath: \.enableManualRebaseFailureNotification)
                toggle("Worktree failure",
                       help: nil,
                       keyPath: \.enableWorktreeFailureNotification)
            } header: {
                Text("Automation")
            }

            Section {
                HStack {
                    Text("Verify notification setup")
                    Spacer()
                    Button(state.isFiringTestNotifications ? "Sending…" : "Send test notification") {
                        Task { await state.fireTestNotifications() }
                    }
                    .disabled(state.isFiringTestNotifications)
                }
            } footer: {
                Text("Posts a sample notification of each enabled type so you can confirm they reach Notification Center.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func toggle(_ title: String, help: String?, keyPath: WritableKeyPath<PersistedSettings, Bool>) -> some View {
        let binding = Binding(
            get: { state.persistedState.settings[keyPath: keyPath] },
            set: { v in state.updateSettings { $0[keyPath: keyPath] = v } }
        )
        if let help {
            Toggle(title, isOn: binding).help(help)
        } else {
            Toggle(title, isOn: binding)
        }
    }
}

// MARK: - Repos

private struct ReposSettingsTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            if let err = state.lastSaveError {
                Section {
                    SaveErrorBanner(message: err) { state.dismissSaveError() }
                }
            }

            Section {
                if state.seenRepos.isEmpty {
                    Text("No repos yet — refresh the menu bar to populate this list.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(state.seenRepos, id: \.key) { repo in
                        repoRow(repo)
                    }
                }
            } header: {
                Text("Auto-merge method")
            } footer: {
                Text("\"Default\" picks the highest-priority method allowed by the repo (Squash > Merge > Rebase). Override per repo when the default isn't what you want.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func repoRow(_ repo: (key: String, allowed: Set<String>)) -> some View {
        if repo.allowed.count <= 1 {
            HStack {
                Text(repo.key).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(defaultLabel(for: repo.allowed))
                    .foregroundStyle(.secondary)
            }
        } else {
            Picker(selection: Binding(
                get: { state.persistedState.perRepoMergeMethod[repo.key] ?? "" },
                set: { v in state.setPerRepoMergeMethod(repo.key, method: v.isEmpty ? nil : v) }
            )) {
                Text(defaultLabel(for: repo.allowed)).tag("")
                ForEach(GitHubClient.MergeMethod.allCases, id: \.rawValue) { m in
                    if repo.allowed.contains(m.rawValue) {
                        Text(m.label).tag(m.rawValue)
                    }
                }
            } label: {
                Text(repo.key).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func defaultLabel(for allowed: Set<String>) -> String {
        if let method = state.autoPickedMethod(allowed: allowed) {
            return "Default (\(method.label))"
        }
        return "Default (no method allowed)"
    }
}

// MARK: - Shared banners

/// Inline warning shown when persistence write failed. Lives here (not in
/// AuxViews) so each settings tab can render it independently — the user is
/// most likely to see it after toggling something here.
private struct SaveErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings failed to save").font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .help(message)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Dismiss (will reappear if the next save also fails)")
        }
    }
}

private struct NotificationsDeniedBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications denied").font(.callout.weight(.semibold))
                Text("macOS won't deliver notifications until you re-enable GitPilot in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

// MARK: - Opening the Settings window from elsewhere

/// Button that opens the Settings scene from inside a MenuBarExtra popover.
///
/// Why this is its own view instead of a plain Button calling `NSApp.sendAction`:
///   - `MenuBarExtra(.window)` hosts its content in a non-app panel. When a
///     button there fires `sendAction(_:to:nil, from:nil)`, the responder
///     chain walked starts at the popover panel, which does NOT contain the
///     hidden controller SwiftUI installs for `showSettingsWindow:`. The
///     action lands on no one and nothing happens.
///   - macOS 14 introduced `SettingsLink`, which SwiftUI implements to handle
///     this case correctly. We use it when available.
///   - On macOS 13 we fall back to dispatching the legacy selector
///     asynchronously so it runs *after* the popover has dismissed and the
///     responder chain has been re-rooted on the application.
struct OpenSettingsButton<Label: View>: View {
    @ViewBuilder let label: () -> Label

    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink(label: label)
        } else {
            Button(action: Self.openLegacy, label: label)
        }
    }

    private static func openLegacy() {
        NSApp.activate(ignoringOtherApps: true)
        // Defer until the popover dismisses — see comment above for why.
        DispatchQueue.main.async {
            if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
    }
}

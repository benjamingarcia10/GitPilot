import SwiftUI
import AppKit

// MARK: - Tab switcher

/// Top-level tab switcher. One row of pill buttons, hover-highlighted, accent-tinted
/// when active. Switches state.currentTab.
struct TabSwitcher: View {
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

// MARK: - Activity tab

/// Activity tab — chronological event log (newest first), capped per ActivityRetention.
struct ActivityTabContent: View {
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
                    Text(Self.timeFormatter.string(from: event.timestamp))
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
            if let pr = state.lookupPR(event.prId) {
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

    /// Formatter is static so we don't pay the construction cost on every row redraw.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()
}

// MARK: - Worktrees tab

/// Worktrees tab — lists all managed worktrees with status (clean / dirty / missing)
/// and remove buttons. Source of truth is persistedState.worktrees.
struct WorktreesTabContent: View {
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
        .task { await refreshAllStatuses() }
    }

    /// Status checks shell out to git (not free). They're now async via a
    /// continuation in WorktreeManager so they don't pin a cooperative-pool thread.
    private func refreshAllStatuses() async {
        let entries = state.persistedState.worktrees
        var snapshot: [String: WorktreeStatus] = [:]
        for (prId, path) in entries {
            snapshot[prId] = await WorktreeManager.status(at: URL(fileURLWithPath: path))
        }
        statusByPRId = snapshot
    }

    private func refreshStatus(prId: String, path: String) {
        Task {
            let status = await WorktreeManager.status(at: URL(fileURLWithPath: path))
            statusByPRId[prId] = status
        }
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
            Button("Open") { state.openWorktreeInEditor(prId: prId) }
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
        if let pr = state.lookupPR(prId) {
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

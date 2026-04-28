import SwiftUI
import AppKit

/// One row in the My PRs / Reviewing list. Owns the inline expand affordance, the
/// status-badge cluster, the action buttons (Rebase/Open/⋯), the right-click and
/// overflow context menus, and the optional inline checks panel when expanded.
struct PRRow: View {
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

    // MARK: - Main row

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
                titleRow
                if !pr.reviewerSources.isEmpty {
                    reviewerPills
                }
                metadataAndActionsRow
            }
        }
    }

    /// Title + the cluster of small status icons (pinned, auto-rebase, auto-merge,
    /// worktree). Each only renders when the corresponding flag/state is active.
    private var titleRow: some View {
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
    }

    /// Reviewer-source pills only appear on Reviewing-tab rows ('you' for direct,
    /// '@team-slug' for team membership).
    private var reviewerPills: some View {
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

    /// PR number, status text, optional diff size and snooze countdown, plus the
    /// trailing action buttons (Rebase / Open / overflow).
    private var metadataAndActionsRow: some View {
        HStack(spacing: 6) {
            // verbatim bypasses SwiftUI's locale-aware integer formatting; GitHub
            // PR numbers are never displayed with thousand separators.
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
                snoozeCountdown(until: until)
            }
            Spacer()
            actionButtons
        }
    }

    private func snoozeCountdown(until: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let remaining = max(0, until.timeIntervalSince(context.date))
            HStack(spacing: 2) {
                Image(systemName: "moon.zzz.fill").font(.caption2)
                Text(formatDuration(remaining)).font(.caption)
            }
            .foregroundStyle(.purple)
        }
    }

    private var actionButtons: some View {
        Group {
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
            // discoverable. Mac convention is to offer both for the same actions.
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

    // MARK: - Context menu

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
        // Worktree actions. "Create worktree" creates a worktree at the configured
        // root and opens it in the editor; "Open worktree" reopens an existing one.
        if state.persistedState.worktrees[pr.id] != nil {
            Button("Open worktree in editor") {
                state.openWorktreeInEditor(prId: pr.id)
            }
            Button("Remove worktree") {
                Task { await state.removeWorktree(prId: pr.id) }
            }
        } else {
            let creating = state.worktreeInFlight.contains(pr.id)
            Button(creating ? "Creating worktree…" : "Create worktree") {
                Task { await state.createAndOpenWorktree(for: pr) }
            }
            .disabled(creating)
        }
        Divider()
        Button("Open in browser") { NSWorkspace.shared.open(pr.url) }
        Button("Copy URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
        }
    }

    // MARK: - Visual helpers

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

    /// Fallback is a conservative 1 hour (not 8) — if Calendar can't construct
    /// tomorrow-at-9-AM the user will hit the snooze sooner and notice rather
    /// than be silently ignored for most of a day.
    private func secondsUntilTomorrow9AM() -> TimeInterval {
        let cal = Calendar.current
        let now = Date()
        var components = cal.dateComponents([.year, .month, .day], from: now)
        components.day = (components.day ?? 0) + 1
        components.hour = 9
        components.minute = 0
        let target = cal.date(from: components) ?? now.addingTimeInterval(3600)
        return max(60, target.timeIntervalSince(now))
    }
}

// MARK: - Inline check list

/// Inline check list rendered when a row is expanded. Each row maps directly
/// to a GitHub status context or check run and links to wherever it ran —
/// Buildkite, GitHub Actions, or anything else GitHub knows about.
struct ChecksList: View {
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

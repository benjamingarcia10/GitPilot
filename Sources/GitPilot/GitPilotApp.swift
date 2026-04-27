import SwiftUI
import AppKit

@main
struct GitPilotApp: App {
    @StateObject private var state = AppState()

    init() {
        // Hide Dock icon — this is a menu bar app.
        NSApp?.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            MenuBarLabel(monitor: state.monitor)
        }
        .menuBarExtraStyle(.window)
        .commands {}
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
                    isRefreshing: monitor.isRefreshing,
                    isEnabled: state.authStatus == authenticatedShape(state.authStatus),
                    action: { Task { await monitor.refresh() } }
                )
            }

            if case .authenticated = state.authStatus, !monitor.prs.isEmpty {
                SearchBar(state: state)
            }

            if case .authenticated = state.authStatus, !state.availableRepos.isEmpty {
                HStack(spacing: 6) {
                    Text("Repo").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { state.repoFilter ?? "" },
                        set: { state.repoFilter = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("All (\(state.monitor.prs.count))").tag("")
                        ForEach(state.availableRepos, id: \.self) { repo in
                            let count = state.monitor.prs.filter { "\($0.repoOwner)/\($0.repoName)" == repo }.count
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
            Divider()

            switch state.authStatus {
            case .unknown:
                Text("Checking GitHub auth…").foregroundStyle(.secondary)
            case .needsReauth(let reason):
                AuthBanner(reason: reason, onRetry: { Task { await state.checkAuth() } })
            case .authenticated:
                authenticatedBody
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

    @ViewBuilder
    private var authenticatedBody: some View {
        if let err = monitor.lastError {
            Text(err).foregroundStyle(.red).font(.caption)
        }
        // Pin filter banner stays above the scroll area so the focus mode and
        // "Unpin all" escape are always visible regardless of scroll position.
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
            // Only the PR list scrolls. maxHeight is set so the menu never overflows
            // the screen, and so the rest of the menu chrome (header, filters, settings,
            // footer) stays put as the list grows.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { pr in
                        PRRow(pr: pr, state: state)
                    }
                }
            }
            .frame(maxHeight: 500)
        }
        // Settings disclosure stays below the scroll area so it's always one click away.
        SettingsSection(state: state)
    }

    /// Helper so the disabled-binding above type-checks; SwiftUI doesn't like
    /// pattern matching inside a boolean expression directly.
    private func authenticatedShape(_ status: AuthStatus) -> AuthStatus {
        if case .authenticated = status { return status }
        return .unknown
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

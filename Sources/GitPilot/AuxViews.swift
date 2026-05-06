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


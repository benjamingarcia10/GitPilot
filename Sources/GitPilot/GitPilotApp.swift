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
            Label("GitPilot", systemImage: menuBarIcon(for: state))
        }
        .menuBarExtraStyle(.window)
        .commands {}
    }

    /// Pick an SF Symbol that reflects the most-attention-worthy state across all PRs.
    private func menuBarIcon(for state: AppState) -> String {
        if state.monitor.prs.contains(where: { $0.isReadyToMerge }) {
            return "checkmark.circle.fill"
        }
        if state.monitor.prs.contains(where: { $0.needsBranchUpdate }) {
            return "arrow.triangle.2.circlepath"
        }
        return "circle.dashed"
    }
}

private struct MenuContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var monitor: PRMonitor

    init(state: AppState) {
        self.state = state
        self.monitor = state.monitor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GitPilot").font(.headline)
                if case .authenticated(let login) = state.authStatus {
                    Text("@\(login)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") {
                    Task { await monitor.refresh() }
                }
                .buttonStyle(.borderless)
                .disabled(state.authStatus != authenticatedShape(state.authStatus))
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
            HStack {
                if let last = monitor.lastRefresh {
                    Text("Updated \(relative(last))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(width: 360)
        .task { await state.bootstrap() }
    }

    @ViewBuilder
    private var authenticatedBody: some View {
        if let err = monitor.lastError {
            Text(err).foregroundStyle(.red).font(.caption)
        }
        if monitor.prs.isEmpty {
            Text("No open PRs").foregroundStyle(.secondary)
        } else {
            ForEach(monitor.prs) { pr in
                PRRow(pr: pr, state: state)
            }
        }
    }

    /// Helper so the disabled-binding above type-checks; SwiftUI doesn't like
    /// pattern matching inside a boolean expression directly.
    private func authenticatedShape(_ status: AuthStatus) -> AuthStatus {
        if case .authenticated = status { return status }
        return .unknown
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text("#\(pr.number)").font(.system(.body, design: .monospaced))
                Text(pr.title).lineLimit(1).truncationMode(.tail)
            }
            HStack(spacing: 8) {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !pr.isLoading && pr.needsBranchUpdate {
                    Button("Rebase") {
                        Task { await rebase() }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                Button("Open") { NSWorkspace.shared.open(pr.url) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        if pr.isLoading { return "circle.dotted" }
        if pr.isReadyToMerge { return "checkmark.circle.fill" }
        if pr.needsBranchUpdate { return "arrow.triangle.2.circlepath" }
        if pr.mergeStateStatus == .dirty { return "exclamationmark.triangle.fill" }
        return "circle"
    }

    private var color: Color {
        if pr.isLoading { return .secondary }
        if pr.isReadyToMerge { return .green }
        if pr.mergeStateStatus == .dirty { return .red }
        if pr.needsBranchUpdate { return .orange }
        return .secondary
    }

    private var statusText: String {
        if pr.isLoading {
            return pr.isDraft ? "loading · draft" : "loading…"
        }
        var parts: [String] = [(pr.mergeStateStatus ?? .unknown).rawValue.lowercased()]
        if let r = pr.reviewDecision { parts.append(r.lowercased()) }
        if pr.isDraft { parts.append("draft") }
        return parts.joined(separator: " · ")
    }

    private func rebase() async {
        do {
            try await state.client.updateBranch(prNodeId: pr.nodeId, method: .rebase)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await state.monitor.refresh()
        } catch {
            print("Rebase failed: \(error.localizedDescription)")
        }
    }
}

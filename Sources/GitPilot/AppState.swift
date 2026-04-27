import Foundation
import AppKit

/// Owns the wires between Monitor, NotificationService, and GitHub.
/// Notification taps land here, then are dispatched to the right service.
@MainActor
final class AppState: ObservableObject {
    let client: GitHubClient
    let monitor: PRMonitor
    private(set) var notifications: NotificationService!

    /// Drives the auth banner in the menu UI. Updated by checkAuth() and by the
    /// monitor's onAuthError callback when polling hits a 401.
    @Published var authStatus: AuthStatus = .unknown

    /// Selected repo filter for the menu. `nil` means "All".
    /// Filtering is purely UI; the monitor still polls + enriches every PR.
    @Published var repoFilter: String? = nil

    /// Free-text search applied to PR title, number, and repo name.
    @Published var searchText: String = ""

    /// When true, searchText is interpreted as a regex (case-insensitive). Otherwise
    /// it's a plain case-insensitive substring match.
    @Published var useRegex: Bool = false

    /// SwiftUI's `.task` modifier re-fires when the menu popover reappears.
    /// Without this guard, every open would kick off a fresh fetch and blank the list.
    private var didBootstrap = false

    init() {
        let client = GitHubClient()
        self.client = client
        self.monitor = PRMonitor(client: client)
        self.notifications = NotificationService { [weak self] response in
            Task { @MainActor in await self?.handle(response: response) }
        }
        self.monitor.onTransition = { [weak self] transition in
            await self?.handle(transition: transition)
        }
        self.monitor.onAuthError = { [weak self] reason in
            Task { @MainActor in self?.authStatus = .needsReauth(reason: reason) }
        }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await notifications.bootstrap()
        await checkAuth()
    }

    /// Sorted unique `owner/name` keys present in the current PR set, for the filter picker.
    var availableRepos: [String] {
        let keys = monitor.prs.map { "\($0.repoOwner)/\($0.repoName)" }
        return Array(Set(keys)).sorted()
    }

    /// PRs to display, after applying the active repo filter and search query.
    var visiblePRs: [PullRequest] {
        var result = monitor.prs
        if let filter = repoFilter {
            result = result.filter { "\($0.repoOwner)/\($0.repoName)" == filter }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return result }

        if useRegex {
            // Invalid regex matches nothing; the UI surfaces the error inline.
            guard let regex = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) else {
                return []
            }
            return result.filter { pr in
                let haystack = "#\(pr.number) \(pr.title) \(pr.repoName) \(pr.headRefName)"
                let range = NSRange(haystack.startIndex..., in: haystack)
                return regex.firstMatch(in: haystack, options: [], range: range) != nil
            }
        } else {
            return result.filter { pr in
                pr.title.localizedCaseInsensitiveContains(query) ||
                "#\(pr.number)".contains(query) ||
                pr.repoName.localizedCaseInsensitiveContains(query) ||
                pr.headRefName.localizedCaseInsensitiveContains(query)
            }
        }
    }

    /// Non-nil when useRegex is on and searchText doesn't compile. Drives the inline
    /// error indicator next to the regex toggle.
    var regexError: String? {
        guard useRegex, !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: searchText, options: [.caseInsensitive])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Validates credentials by reading the user's login. Starts the monitor only on success.
    /// Call this after the user runs `gh auth login` to retry.
    func checkAuth() async {
        do {
            let login = try await client.currentLogin()
            guard !login.isEmpty else {
                authStatus = .needsReauth(reason: "gh returned empty login. Run `gh auth login`.")
                monitor.stop()
                return
            }
            authStatus = .authenticated(login: login)
            monitor.start()
        } catch let err as GitHubClientError {
            if err.isAuthError {
                authStatus = .needsReauth(reason: err.localizedDescription)
            } else {
                authStatus = .needsReauth(reason: err.localizedDescription)
            }
            monitor.stop()
        } catch {
            authStatus = .needsReauth(reason: error.localizedDescription)
            monitor.stop()
        }
    }

    private func handle(transition: PRTransition) async {
        switch transition {
        case .needsBranchUpdate(let pr):
            await notifications.notifyNeedsUpdate(pr: pr)
        case .readyToMerge(let pr):
            await notifications.notifyReadyToMerge(pr: pr)
        }
    }

    private func handle(response: NotificationResponse) async {
        switch response {
        case .updateBranch(let prId):
            guard let pr = monitor.prs.first(where: { $0.id == prId }) else { return }
            do {
                try await client.updateBranch(prNodeId: pr.nodeId, method: .rebase)
                // Re-check shortly so the menu bar reflects the new state.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await monitor.refresh()
            } catch {
                print("Rebase failed: \(error.localizedDescription)")
            }
        case .openPR(let prId):
            if let pr = monitor.prs.first(where: { $0.id == prId }) {
                NSWorkspace.shared.open(pr.url)
            }
        case .dismiss:
            break
        }
    }
}

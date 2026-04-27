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
        await notifications.bootstrap()
        await checkAuth()
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

import Foundation
import AppKit

/// Owns the wires between Monitor, NotificationService, and GitHub.
/// Notification taps land here, then are dispatched to the right service.
@MainActor
final class AppState: ObservableObject {
    let client: GitHubClient
    let monitor: PRMonitor
    private(set) var notifications: NotificationService!

    init() {
        let client = GitHubClient()
        self.client = client
        self.monitor = PRMonitor(client: client)
        self.notifications = NotificationService { [weak self] response in
            Task { @MainActor in await self?.handle(response: response) }
        }
        // Wire transitions back now that both exist (closure can reference self safely).
        self.monitor.onTransition = { [weak self] transition in
            await self?.handle(transition: transition)
        }
    }

    func bootstrap() async {
        await notifications.bootstrap()
        monitor.start()
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

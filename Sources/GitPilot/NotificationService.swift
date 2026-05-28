import Foundation
import UserNotifications

/// Identifiers shared between scheduling and the delegate that handles taps.
enum NotificationCategory {
    static let needsUpdate = "GP_NEEDS_UPDATE"
    static let readyToMerge = "GP_READY_TO_MERGE"
    static let testsFailing = "GP_TESTS_FAILING"
    static let autoRebaseFailed = "GP_AUTO_REBASE_FAILED"
    static let autoMergeFailed = "GP_AUTO_MERGE_FAILED"
    static let autoMergeCompleted = "GP_AUTO_MERGE_COMPLETED"
    static let manualRebaseFailed = "GP_MANUAL_REBASE_FAILED"
    static let worktreeFailed = "GP_WORKTREE_FAILED"
    static let conflicts = "GP_CONFLICTS"
    static let authFailed = "GP_AUTH_FAILED"
}

enum NotificationAction {
    static let updateBranch = "GP_ACTION_UPDATE_BRANCH"
    static let openPR = "GP_ACTION_OPEN_PR"
    static let dismiss = "GP_ACTION_DISMISS"
}

/// Routed back to the app when the user picks a notification action button.
enum NotificationResponse {
    case updateBranch(prId: String)
    case openPR(prId: String)
    case dismiss(prId: String)
}

/// Wraps UNUserNotificationCenter. Categories with action buttons are registered once at launch.
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    /// Set by AppState after construction so the closure can capture `self`
    /// without requiring the AppState property to be implicitly-unwrapped.
    var onResponse: (NotificationResponse) -> Void = { _ in }

    /// Mirrors UNAuthorizationStatus so the UI can show a banner when notifications
    /// are denied and silently dropping. Updated after request and on demand.
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        center.delegate = self
    }

    func bootstrap() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Log.debug("Notification authorization error: \(error)")
        }
        registerCategories()
        await refreshAuthorizationStatus()
    }

    @MainActor
    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        self.authorizationStatus = settings.authorizationStatus
        Log.debug("notification authorizationStatus: \(settings.authorizationStatus.rawValue)")
    }

    private func registerCategories() {
        let updateAction = UNNotificationAction(
            identifier: NotificationAction.updateBranch,
            title: "Rebase",
            options: [.authenticationRequired]
        )
        let dismissUpdate = UNNotificationAction(
            identifier: NotificationAction.dismiss,
            title: "Skip",
            options: []
        )
        let needsUpdate = UNNotificationCategory(
            identifier: NotificationCategory.needsUpdate,
            actions: [updateAction, dismissUpdate],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let openAction = UNNotificationAction(
            identifier: NotificationAction.openPR,
            title: "Open PR",
            options: [.foreground]
        )
        let readyToMerge = UNNotificationCategory(
            identifier: NotificationCategory.readyToMerge,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )

        let testsFailing = UNNotificationCategory(
            identifier: NotificationCategory.testsFailing,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )

        let autoRebaseFailed = UNNotificationCategory(
            identifier: NotificationCategory.autoRebaseFailed,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )

        let autoMergeFailed = UNNotificationCategory(
            identifier: NotificationCategory.autoMergeFailed,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )

        let autoMergeCompleted = UNNotificationCategory(
            identifier: NotificationCategory.autoMergeCompleted,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )

        let manualRebaseFailed = UNNotificationCategory(
            identifier: NotificationCategory.manualRebaseFailed,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )

        let worktreeFailed = UNNotificationCategory(
            identifier: NotificationCategory.worktreeFailed,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )

        let conflicts = UNNotificationCategory(
            identifier: NotificationCategory.conflicts,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )

        // No action buttons — there's nothing GitPilot can do from a button to
        // re-auth; the user has to run `gh auth login`. Tapping just dismisses.
        let authFailed = UNNotificationCategory(
            identifier: NotificationCategory.authFailed,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([
            needsUpdate, readyToMerge, testsFailing,
            autoRebaseFailed, autoMergeFailed, autoMergeCompleted,
            manualRebaseFailed, worktreeFailed, conflicts, authFailed,
        ])
    }

    func notifyNeedsUpdate(pr: PullRequest) async {
        await notify(
            pr: pr,
            idPrefix: "needs-update",
            title: "Rebase PR?",
            subtitle: "PR #\(pr.number) is behind \(pr.baseRefName)",
            body: pr.title,
            category: NotificationCategory.needsUpdate
        )
    }

    func notifyReadyToMerge(pr: PullRequest) async {
        await notify(
            pr: pr,
            idPrefix: "ready",
            title: "Ready to merge",
            subtitle: "PR #\(pr.number)",
            body: pr.title,
            category: NotificationCategory.readyToMerge
        )
    }

    func notifyTestsFailing(pr: PullRequest) async {
        await notify(
            pr: pr,
            idPrefix: "tests",
            title: "CI failing",
            subtitle: "PR #\(pr.number)",
            body: pr.title,
            category: NotificationCategory.testsFailing
        )
    }

    func notifyAutoRebaseFailed(pr: PullRequest, reason: String) async {
        await notify(
            pr: pr,
            idPrefix: "auto-rebase-failed",
            title: "Auto-rebase failed",
            subtitle: "PR #\(pr.number)",
            body: "\(pr.title)\n\(reason)",
            category: NotificationCategory.autoRebaseFailed
        )
    }

    func notifyAutoMergeFailed(pr: PullRequest, reason: String) async {
        await notify(
            pr: pr,
            idPrefix: "auto-merge-failed",
            title: "Auto-merge failed",
            subtitle: "PR #\(pr.number)",
            body: "\(pr.title)\n\(reason)",
            category: NotificationCategory.autoMergeFailed
        )
    }

    func notifyAutoMergeCompleted(pr: PullRequest, method: String) async {
        await notify(
            pr: pr,
            idPrefix: "auto-merge-completed",
            title: "Auto-merge complete",
            subtitle: "PR #\(pr.number)",
            body: "\(pr.title)\nMerged via \(method.lowercased())",
            category: NotificationCategory.autoMergeCompleted
        )
    }

    func notifyManualRebaseFailed(pr: PullRequest, reason: String) async {
        await notify(
            pr: pr,
            idPrefix: "rebase-failed",
            title: "Rebase failed",
            subtitle: "PR #\(pr.number)",
            body: "\(pr.title)\n\(reason)",
            category: NotificationCategory.manualRebaseFailed
        )
    }

    func notifyConflicts(pr: PullRequest) async {
        await notify(
            pr: pr,
            idPrefix: "conflicts",
            title: "Merge conflict",
            subtitle: "PR #\(pr.number)",
            body: "\(pr.title)\nNeeds local resolution against \(pr.baseRefName)",
            category: NotificationCategory.conflicts
        )
    }

    func notifyWorktreeFailed(pr: PullRequest, reason: String) async {
        await notify(
            pr: pr,
            idPrefix: "worktree-failed",
            title: "Worktree operation failed",
            subtitle: "PR #\(pr.number)",
            body: "\(pr.title)\n\(reason)",
            category: NotificationCategory.worktreeFailed
        )
    }

    /// Not PR-scoped, so it can't use the `notify` helper. Fired edge-triggered
    /// by AppState when auth transitions into needs-reauth, so the user learns
    /// PR tracking has stopped without having to open the popover.
    func notifyAuthFailure(reason: String) async {
        let content = UNMutableNotificationContent()
        content.title = "GitHub sign-in required"
        content.subtitle = "PR tracking is paused"
        content.body = "\(reason)\nRun `gh auth login`, then reopen GitPilot."
        content.categoryIdentifier = NotificationCategory.authFailed
        content.sound = .default
        let req = UNNotificationRequest(identifier: "auth-failed", content: content, trigger: nil)
        do { try await center.add(req) } catch { Log.warn("Notification add failed: \(error.localizedDescription)") }
    }

    /// Single scheduling entry — every notify* method routes through this so
    /// the boilerplate (content, category, sound, userInfo, request id) lives
    /// in one place.
    private func notify(
        pr: PullRequest,
        idPrefix: String,
        title: String,
        subtitle: String,
        body: String,
        category: String
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.categoryIdentifier = category
        content.sound = .default
        content.userInfo = ["prId": pr.id, "url": pr.url.absoluteString]
        let req = UNNotificationRequest(identifier: "\(idPrefix)-\(pr.id)", content: content, trigger: nil)
        // warn level so a failed notification is visible without GITPILOT_DEBUG=1.
        // The activity entry was already recorded by the caller, so the user can
        // still see what happened via the Activity tab; this surfaces *why* the
        // notification didn't appear.
        do { try await center.add(req) } catch { Log.warn("Notification add failed: \(error.localizedDescription)") }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banner/sound even when the app is foregrounded (the menu bar app technically is).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let prId = userInfo["prId"] as? String else {
            completionHandler(); return
        }
        switch response.actionIdentifier {
        case NotificationAction.updateBranch:
            onResponse(.updateBranch(prId: prId))
        case NotificationAction.openPR, UNNotificationDefaultActionIdentifier:
            onResponse(.openPR(prId: prId))
        case NotificationAction.dismiss, UNNotificationDismissActionIdentifier:
            onResponse(.dismiss(prId: prId))
        default:
            break
        }
        completionHandler()
    }
}

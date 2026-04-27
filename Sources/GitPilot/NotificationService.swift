import Foundation
import UserNotifications

/// Identifiers shared between scheduling and the delegate that handles taps.
enum NotificationCategory {
    static let needsUpdate = "GP_NEEDS_UPDATE"
    static let readyToMerge = "GP_READY_TO_MERGE"
    static let testsFailing = "GP_TESTS_FAILING"
    static let autoRebaseFailed = "GP_AUTO_REBASE_FAILED"
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
    private let onResponse: (NotificationResponse) -> Void

    /// Mirrors UNAuthorizationStatus so the UI can show a banner when notifications
    /// are denied and silently dropping. Updated after request and on demand.
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init(onResponse: @escaping (NotificationResponse) -> Void) {
        self.onResponse = onResponse
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

        center.setNotificationCategories([needsUpdate, readyToMerge, testsFailing, autoRebaseFailed])
    }

    func notifyNeedsUpdate(pr: PullRequest) async {
        let content = UNMutableNotificationContent()
        content.title = "Rebase PR?"
        content.subtitle = "PR #\(pr.number) is behind \(pr.baseRefName)"
        content.body = pr.title
        content.categoryIdentifier = NotificationCategory.needsUpdate
        content.sound = .default
        content.userInfo = ["prId": pr.id, "url": pr.url.absoluteString]
        await schedule(id: "needs-update-\(pr.id)", content: content)
    }

    func notifyReadyToMerge(pr: PullRequest) async {
        let content = UNMutableNotificationContent()
        content.title = "Ready to merge"
        content.subtitle = "PR #\(pr.number)"
        content.body = pr.title
        content.categoryIdentifier = NotificationCategory.readyToMerge
        content.sound = .default
        content.userInfo = ["prId": pr.id, "url": pr.url.absoluteString]
        await schedule(id: "ready-\(pr.id)", content: content)
    }

    func notifyTestsFailing(pr: PullRequest) async {
        let content = UNMutableNotificationContent()
        content.title = "CI failing"
        content.subtitle = "PR #\(pr.number)"
        content.body = pr.title
        content.categoryIdentifier = NotificationCategory.testsFailing
        content.sound = .default
        content.userInfo = ["prId": pr.id, "url": pr.url.absoluteString]
        await schedule(id: "tests-\(pr.id)", content: content)
    }

    func notifyAutoRebaseFailed(pr: PullRequest, reason: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Auto-rebase failed"
        content.subtitle = "PR #\(pr.number)"
        content.body = "\(pr.title)\n\(reason)"
        content.categoryIdentifier = NotificationCategory.autoRebaseFailed
        content.sound = .default
        content.userInfo = ["prId": pr.id, "url": pr.url.absoluteString]
        await schedule(id: "auto-rebase-failed-\(pr.id)", content: content)
    }

    private func schedule(id: String, content: UNMutableNotificationContent) async {
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do { try await center.add(req) } catch { print("Notification add failed: \(error)") }
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

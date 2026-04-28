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

        center.setNotificationCategories([needsUpdate, readyToMerge, testsFailing, autoRebaseFailed])
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
        do { try await center.add(req) } catch { Log.debug("Notification add failed: \(error)") }
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

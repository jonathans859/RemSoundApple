#if os(iOS)
import Foundation
import UserNotifications

/// Puts a connection request ("X would like to connect to you") up as a notification while
/// the app is not on screen, with Allow / Don't Allow answerable straight from the lock screen
/// (user, 2026-10-09). In the foreground the in-app alert asks instead, so nothing is posted
/// then. iOS only: the Mac app opens its window for the question (`onConnectionRequestPending`).
///
/// Allow requires unlocking (`.authenticationRequired`): it ticks the person, and a ticked
/// person hears this device's microphone whenever sending is on — not something a locked
/// phone in somebody else's hand should be able to grant. Don't Allow needs nothing.
///
/// No time-sensitive interruption level: that needs an entitlement and an App ID capability
/// the cloud-signed builds do not have. An ordinary notification still lights the lock screen.
@MainActor
final class ConnectionRequestNotifier: NSObject, UNUserNotificationCenterDelegate {
    // nonisolated: plain string constants, read from the nonisolated delegate methods below
    // (a main-actor static read from there is a compile error, even in Swift 5 mode).
    nonisolated static let categoryId = "connection-request"
    nonisolated static let allowAction = "allow"
    nonisolated static let declineAction = "decline"
    private nonisolated static let requestIdKey = "requestId"

    /// The user answered from the notification: the request id it was posted under, and
    /// whether they allowed it.
    var onAnswer: ((_ requestId: String, _ allow: Bool) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    /// Become the notification delegate and register the Allow / Don't Allow category. Must
    /// run at launch, before any response can arrive — an action tapped while the app was not
    /// running is delivered to whoever is the delegate when it starts.
    func install() {
        center.delegate = self
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow",
                                         options: [.authenticationRequired])
        let decline = UNNotificationAction(identifier: Self.declineAction, title: "Don't Allow",
                                           options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryId, actions: [allow, decline],
                                   intentIdentifiers: [], options: []),
        ])
    }

    /// Ask for permission, once, while the app is on screen — iOS only shows the prompt to a
    /// foreground app, and the first request usually arrives with the phone locked.
    func requestPermissionIfUndecided() {
        let center = self.center
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func post(id: String, question: String) {
        let content = UNMutableNotificationContent()
        content.title = "Connection request"
        content.body = question
        content.sound = .default
        content.categoryIdentifier = Self.categoryId
        content.userInfo = [Self.requestIdKey: id]
        // Identified by the request id, so withdrawing it later needs nothing remembered.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// The question was answered some other way (in the app), so the notification would only
    /// offer to answer it twice.
    func withdraw(id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo[Self.requestIdKey] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            // A plain tap opens the app, where the same question is waiting as an alert.
            if let id {
                if action == Self.allowAction { self.onAnswer?(id, true) }
                if action == Self.declineAction { self.onAnswer?(id, false) }
            }
            completionHandler()
        }
    }

    /// In the foreground the in-app alert is already asking; a banner on top of it would be
    /// the same question twice.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
#endif

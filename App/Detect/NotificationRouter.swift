import EarshotKit
import Foundation
import os
import UserNotifications

/// The notification center's delegate. It holds no state and belongs to no actor (spec 17): each callback reads what
/// it needs from the response on the thread the system uses, turns it into a `NotificationRoute.Command`, and hops to
/// the main actor with `Task { @MainActor in }`.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationRouter()

    /// Sets this as the delegate and registers Earshot's categories with their buttons.
    static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.setNotificationCategories(Set(NotificationRoute.Category.allCases.map(category)))
    }

    private static func category(_ category: NotificationRoute.Category) -> UNNotificationCategory {
        let actions = category.actions.map { UNNotificationAction(identifier: $0.rawValue, title: $0.title, options: []) }
        return UNNotificationCategory(identifier: category.rawValue, actions: actions, intentIdentifiers: [], options: [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let command = Self.command(for: response)
        Task { @MainActor in await AppModel.shared.perform(command) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private static func command(for response: UNNotificationResponse) -> NotificationRoute.Command {
        let content = response.notification.request.content
        var info: [String: String] = [:]
        for (key, value) in content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        return NotificationRoute.command(category: content.categoryIdentifier, action: response.actionIdentifier,
                                         userInfo: info)
    }
}

/// Posting and checking notifications. Nothing is posted in e2e runs.
enum EarshotNotifications {
    static let log = Logger(subsystem: "com.stephenthorn.earshot", category: "notifications")

    static func post(id: String, title: String, body: String = "", category: NotificationRoute.Category?,
                     userInfo: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        if let category { content.categoryIdentifier = category.rawValue }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { log.error("Couldn't post a notification: \(error.localizedDescription, privacy: .public)") }
        }
    }

    static func remove(ids: [String]) {
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// True when a notification reaches the user: allowed, and shown as a banner or an alert. Provisional delivery
    /// and the alert style None put it quietly in Notification Center, so the menu asks instead (spec 7.2).
    nonisolated static func authorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let status = settings.authorizationStatus
        return NotificationRoute.reachesUser(allowed: status == .authorized || status == .provisional,
                                             provisional: status == .provisional,
                                             alertsShown: settings.alertSetting == .enabled && settings.alertStyle != .none)
    }
}

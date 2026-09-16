import Foundation
import UserNotifications
import WatchKit

/// Schedules only on an explicit live request; no delivery retries or collector changes.
final class Libre2WatchNotificationTest {
    private let center: UNUserNotificationCenter
    private var isScheduling = false

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    /// Called on main by the Watch message router, including completion of scheduling.
    @discardableResult
    func receive(_ dictionary: [String: Any], reply: @escaping ([String: Any]) -> Void) -> Bool {
        guard dictionary[Libre2NotificationTest.requestKey] != nil else { return false }
        guard dictionary[Libre2NotificationTest.requestKey] as? Bool == true, !isScheduling else {
            reply(["error": Texts_DirectLibre.notificationTestUnavailable])
            return true
        }
        isScheduling = true
        Task { @MainActor in
            defer { isScheduling = false }
            do {
                var settings = await center.notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    guard WKApplication.shared().applicationState == .active else {
                        reply(["error": Texts_DirectLibre.notificationTestNeedsWatch])
                        return
                    }
                    guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                        reply(["error": Texts_DirectLibre.notificationTestPermission])
                        return
                    }
                    settings = await center.notificationSettings()
                }
                // Quiet/provisional delivery would not test notification presentation.
                guard settings.authorizationStatus == .authorized,
                    settings.alertSetting == .enabled else {
                    reply(["error": Texts_DirectLibre.notificationTestPermission])
                    return
                }

                let content = UNMutableNotificationContent()
                content.title = Texts_DirectLibre.notificationTestTitle
                content.body = Texts_DirectLibre.notificationTestBody
                content.sound = .default
                content.categoryIdentifier = Libre2NotificationTest.category
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Libre2NotificationTest.delay, repeats: false)
                let date = Date().addingTimeInterval(Libre2NotificationTest.delay)
                // Adding the same identifier replaces the previous pending request. Other
                // notifications, including real glucose alarms, are never removed or changed.
                try await center.add(UNNotificationRequest(identifier: Libre2NotificationTest.identifier,
                    content: content, trigger: trigger))
                Libre2ActivityLog.shared.record(Texts_DirectLibre.notificationTestScheduled(date))
                reply([Libre2NotificationTest.scheduledAtKey: date.timeIntervalSince1970])
            } catch {
                reply(["error": error.localizedDescription])
            }
        }
        return true
    }
}

#if os(watchOS)
import SwiftUI

/// Uses the same WatchKit custom-notification mechanism as ordinary xDrip alerts,
/// with its own category and content so a test cannot look like a glucose alarm.
final class Libre2NotificationTestController: WKUserNotificationHostingController<Libre2NotificationTestView> {
    override var body: Libre2NotificationTestView { Libre2NotificationTestView() }

    override func didReceive(_ notification: UNNotification) {
        Libre2LifecycleDiagnostics.recordNotification("Watch notification received", identifier: notification.request.identifier)
    }
}

struct Libre2NotificationTestView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text(Texts_DirectLibre.notificationTestTitle).font(.headline)
            Text(Texts_DirectLibre.notificationTestBody).font(.caption)
        }
    }
}
#endif

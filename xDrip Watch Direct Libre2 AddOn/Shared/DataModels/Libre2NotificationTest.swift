import Foundation

/// One interactive diagnostic request. A fixed identifier replaces a pending test.
enum Libre2NotificationTest {
    static let requestKey = "directLibreNotificationTest"
    static let scheduledAtKey = "notificationTestScheduledAt"
    static let identifier = "directLibreNotificationTest"
    static let category = "directLibreNotificationTestCategory"
    static let delay: TimeInterval = 30
}

#if LIBRE2_NOTIFICATION_TESTS
import Foundation

enum UNAuthorizationStatus { case notDetermined, denied, authorized, provisional }
enum UNNotificationSetting { case enabled, disabled }
struct UNNotificationSettings {
    var authorizationStatus = UNAuthorizationStatus.authorized
    var alertSetting = UNNotificationSetting.enabled
}
struct UNAuthorizationOptions: OptionSet {
    let rawValue: Int
    static let alert = Self(rawValue: 1)
    static let sound = Self(rawValue: 2)
}
enum UNNotificationSound { case `default` }
final class UNMutableNotificationContent {
    var title = ""
    var body = ""
    var categoryIdentifier = ""
    var sound: UNNotificationSound?
}
struct UNTimeIntervalNotificationTrigger {
    let timeInterval: TimeInterval
    let repeats: Bool
}
struct UNNotificationRequest {
    let identifier: String
    let content: UNMutableNotificationContent
    let trigger: UNTimeIntervalNotificationTrigger
}
final class UNUserNotificationCenter {
    static func current() -> UNUserNotificationCenter { UNUserNotificationCenter() }
    var settings = UNNotificationSettings()
    var grantsPermission = true
    var permissionRequests = 0
    var failsToAdd = false
    var pending: [String: UNNotificationRequest] = [:]
    func notificationSettings() async -> UNNotificationSettings { settings }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        permissionRequests += 1
        if grantsPermission { settings.authorizationStatus = .authorized }
        return grantsPermission
    }
    func add(_ request: UNNotificationRequest) async throws {
        if failsToAdd { throw NSError(domain: "test", code: 1) }
        pending[request.identifier] = request
    }
}
final class WKApplication {
    enum State { case active, background }
    static let instance = WKApplication()
    static func shared() -> WKApplication { instance }
    var applicationState = State.active
}
final class Libre2ActivityLog {
    static let shared = Libre2ActivityLog()
    func record(_ message: String) {}
}

@main
struct NotificationTests {
    static func check(_ value: Bool) { precondition(value) }
    @MainActor static func send(_ helper: Libre2WatchNotificationTest) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            precondition(helper.receive([Libre2NotificationTest.requestKey: true]) { continuation.resume(returning: $0) })
        }
    }

    @MainActor static func main() async {
        let center = UNUserNotificationCenter()
        let helper = Libre2WatchNotificationTest(center: center)
        let existing = UNNotificationRequest(identifier: "realAlarm", content: UNMutableNotificationContent(),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false))
        center.pending[existing.identifier] = existing
        let before = Date()
        let first = await send(helper)
        let timestamp = first[Libre2NotificationTest.scheduledAtKey] as! Double
        precondition(timestamp >= before.timeIntervalSince1970 + 30)
        let scheduled = center.pending[Libre2NotificationTest.identifier]!
        precondition(scheduled.trigger.timeInterval == 30 && !scheduled.trigger.repeats)
        precondition(scheduled.content.categoryIdentifier == Libre2NotificationTest.category)
        precondition(center.permissionRequests == 0)
        _ = await send(helper)
        precondition(center.pending.count == 2 && center.pending[existing.identifier] != nil)
        print("PASS: confirmed one-shot scheduling replaces only the pending test")

        center.failsToAdd = true
        let failure = await send(helper)
        precondition(failure["error"] != nil && failure[Libre2NotificationTest.scheduledAtKey] == nil)
        center.failsToAdd = false
        print("PASS: scheduling failure cannot confirm success")

        for authorization in [UNAuthorizationStatus.denied, .provisional] {
            center.settings.authorizationStatus = authorization
            check((await send(helper))["error"] != nil)
        }
        center.settings.authorizationStatus = .authorized
        center.settings.alertSetting = .disabled
        check((await send(helper))["error"] != nil)
        precondition(center.permissionRequests == 0)
        print("PASS: denied, quiet-only and disabled alerts are reported")

        center.settings.authorizationStatus = .notDetermined
        WKApplication.shared().applicationState = .background
        check((await send(helper))["error"] != nil)
        precondition(center.permissionRequests == 0)
        WKApplication.shared().applicationState = .active
        center.grantsPermission = false
        check((await send(helper))["error"] != nil)
        center.grantsPermission = true
        center.settings.alertSetting = .enabled
        check((await send(helper))[Libre2NotificationTest.scheduledAtKey] != nil)
        precondition(center.permissionRequests == 2)
        print("PASS: first authorization requires foreground and a grant")

        precondition(!helper.receive(["unrelated": true]) { _ in preconditionFailure() })
        var invalid: [String: Any] = [:]
        precondition(helper.receive([Libre2NotificationTest.requestKey: false]) { invalid = $0 })
        precondition(invalid["error"] != nil)
        await withCheckedContinuation { continuation in
            precondition(helper.receive([Libre2NotificationTest.requestKey: true]) { _ in continuation.resume() })
            var overlapping: [String: Any] = [:]
            precondition(helper.receive([Libre2NotificationTest.requestKey: true]) { overlapping = $0 })
            precondition(overlapping["error"] != nil)
        }
        print("PASS: unrelated, malformed and overlapping requests do not schedule another test")
    }
}
#endif

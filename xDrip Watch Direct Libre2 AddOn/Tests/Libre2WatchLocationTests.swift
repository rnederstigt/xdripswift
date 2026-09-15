#if LIBRE2_LOCATION_TESTS
import Foundation

// Framework and journal doubles; the script compiles the production session unchanged.
enum CLAuthorizationStatus { case notDetermined, denied, restricted, authorizedAlways, authorizedWhenInUse }
enum CLActivityType { case other }
let kCLLocationAccuracyHundredMeters = 100.0
let kCLDistanceFilterNone = -1.0
final class CLLocation {}
struct CLError: Error {
    enum Code { case denied, locationUnknown }
    let code: Code
}
protocol CLLocationManagerDelegate: AnyObject {}
final class CLLocationManager {
    static var instances: [CLLocationManager] = []
    weak var delegate: CLLocationManagerDelegate?
    var authorizationStatus = CLAuthorizationStatus.notDetermined
    var desiredAccuracy = 0.0
    var distanceFilter = 0.0
    var activityType = CLActivityType.other
    var allowsBackgroundLocationUpdates = false
    var starts = 0
    var stops = 0
    var requests = 0
    init() { Self.instances.append(self) }
    func startUpdatingLocation() { starts += 1 }
    func stopUpdatingLocation() { stops += 1 }
    func requestWhenInUseAuthorization() { requests += 1 }
}
final class WKExtension {
    enum State { case active, inactive, background }
    static let instance = WKExtension()
    static func shared() -> WKExtension { instance }
    static let applicationDidBecomeActiveNotification = Notification.Name("TestWatchActive")
    var applicationState = State.active
}
final class Libre2SessionStore {
    struct Snapshot { var owner = Libre2Owner.phone }
    static let shared = Libre2SessionStore()
    static let didChange = Notification.Name("TestOwnershipChanged")
    var snapshot = Snapshot()
}
final class Libre2ActivityLog {
    static let shared = Libre2ActivityLog()
    var entries: [String] = []
    func record(_ message: String) { entries.append(message) }
}

@main
struct LocationTests {
    static func check(_ name: String, _ test: (Libre2WatchLocationSession, UserDefaults) throws -> Void) rethrows {
        let suite = "Libre2LocationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        CLLocationManager.instances = []
        Libre2SessionStore.shared.snapshot.owner = .phone
        WKExtension.shared().applicationState = .active
        Libre2ActivityLog.shared.entries = []
        try test(Libre2WatchLocationSession(defaults: defaults), defaults)
        print("PASS: \(name)")
    }

    static func send(_ request: Libre2LocationRequest, to helper: Libre2WatchLocationSession) throws -> [String: Any] {
        var reply: [String: Any] = [:]
        let dictionary = try request.dictionary
        precondition(helper.receive(dictionary) { reply = $0 })
        return reply
    }

    static func own(_ owner: Libre2Owner) {
        Libre2SessionStore.shared.snapshot.owner = owner
        NotificationCenter.default.post(name: Libre2SessionStore.didChange, object: Libre2SessionStore.shared)
    }

    static func activate() {
        WKExtension.shared().applicationState = .active
        NotificationCenter.default.post(name: WKExtension.applicationDidBecomeActiveNotification, object: nil)
    }

    static func authorize(_ helper: Libre2WatchLocationSession) -> CLLocationManager {
        let manager = CLLocationManager.instances.last!
        manager.authorizationStatus = .authorizedWhenInUse
        helper.locationManagerDidChangeAuthorization(manager)
        return manager
    }

    static func main() throws {
        try check("default off, inspection and malformed messages never start location") { helper, defaults in
            own(.watch)
            let reply = try send(.inspect, to: helper)
            precondition(reply["enabled"] as? Bool == false)
            precondition(!helper.receive([:]) { _ in })
            precondition(helper.receive([Libre2LocationRequest.key: true]) { precondition($0["error"] != nil) })
            precondition(!Libre2WatchPreferences(defaults: defaults).backgroundLocationEnabled)
            precondition(CLLocationManager.instances.isEmpty)
        }
        try check("enabled setting persists but every non-Watch owner prevents a start") { helper, defaults in
            _ = try send(.setEnabled(true), to: helper)
            for owner: Libre2Owner in [.phone, .preparingWatch, .releasingPhone, .returnRequested,
                                      .returningToPhone, .releasingWatch, .reclaimingPhone, .verifyingPhone, .failed] {
                own(owner)
                precondition(CLLocationManager.instances.isEmpty)
            }
            precondition(Libre2WatchPreferences(defaults: defaults).backgroundLocationEnabled)
        }
        try check("background activation waits for foreground and requests permission only once") { helper, _ in
            WKExtension.shared().applicationState = .background
            own(.watch)
            _ = try send(.setEnabled(true), to: helper)
            precondition(CLLocationManager.instances.isEmpty)
            activate()
            let manager = CLLocationManager.instances.last!
            activate()
            precondition(manager.requests == 1 && manager.starts == 0)
            _ = authorize(helper)
            precondition(manager.starts == 1 && manager.allowsBackgroundLocationUpdates)
        }
        try check("existing session survives background, repeated state events and a missing fix") { helper, _ in
            own(.watch)
            _ = try send(.setEnabled(true), to: helper)
            let manager = authorize(helper)
            WKExtension.shared().applicationState = .background
            own(.watch)
            _ = try send(.inspect, to: helper)
            helper.locationManager(manager, didFailWithError: CLError(code: .locationUnknown))
            helper.locationManager(manager, didUpdateLocations: [CLLocation()])
            precondition(manager.starts == 1 && manager.stops == 0)
            let count = Libre2ActivityLog.shared.entries.count
            for _ in 0..<100 { helper.locationManager(manager, didUpdateLocations: [CLLocation()]) }
            precondition(Libre2ActivityLog.shared.entries.count == count)
        }
        try check("disable stops immediately in background and cannot be undone by a late callback") { helper, defaults in
            own(.watch)
            _ = try send(.setEnabled(true), to: helper)
            let manager = authorize(helper)
            WKExtension.shared().applicationState = .background
            _ = try send(.setEnabled(false), to: helper)
            helper.locationManagerDidChangeAuthorization(manager)
            helper.locationManager(manager, didUpdateLocations: [CLLocation()])
            activate()
            precondition(manager.starts == 1 && manager.stops == 1)
            precondition(!Libre2WatchPreferences(defaults: defaults).backgroundLocationEnabled)
        }
        try check("return or reset stops location without changing ownership") { helper, _ in
            own(.watch)
            _ = try send(.setEnabled(true), to: helper)
            let manager = authorize(helper)
            own(.returningToPhone)
            own(.phone)
            precondition(manager.starts == 1 && manager.stops == 1)
            precondition(Libre2SessionStore.shared.snapshot.owner == .phone)
        }
        try check("permission revocation stops; foreground authorization recovery restarts once") { helper, _ in
            own(.watch)
            _ = try send(.setEnabled(true), to: helper)
            let manager = authorize(helper)
            manager.authorizationStatus = .denied
            helper.locationManagerDidChangeAuthorization(manager)
            precondition(manager.stops == 1)
            WKExtension.shared().applicationState = .background
            manager.authorizationStatus = .authorizedWhenInUse
            helper.locationManagerDidChangeAuthorization(manager)
            precondition(manager.starts == 1)
            activate()
            precondition(manager.starts == 2)
        }
        try check("restart restores opt-in but never starts from a background launch") { _, defaults in
            WKExtension.shared().applicationState = .background
            Libre2WatchPreferences(defaults: defaults).backgroundLocationEnabled = true
            own(.watch)
            let restored = Libre2WatchLocationSession(defaults: defaults)
            precondition(CLLocationManager.instances.isEmpty)
            _ = try send(.inspect, to: restored)
            precondition(CLLocationManager.instances.isEmpty)
            // Keep this test backgrounded: foreground restore is covered by the activation test.
        }
    }
}
#endif

import CoreLocation
import WatchKit

/// Optional execution support. Sensor connections, counters and readings stay in the collector.
/// All entry points and delegate callbacks run on main; no location history is retained.
final class Libre2WatchLocationSession: NSObject, CLLocationManagerDelegate {
    private let preferences: Libre2WatchPreferences
    private var locationManager: CLLocationManager?
    private var observers: [NSObjectProtocol] = []
    private var isUpdating = false
    private var requestedAuthorization = false
    private var receivedLocation = false
    private var status = Texts_DirectLibre.locationOff

    init(defaults: UserDefaults = .standard) {
        preferences = Libre2WatchPreferences(defaults: defaults)
        super.init()
        for name in [Libre2SessionStore.didChange, WKExtension.applicationDidBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.refresh()
            })
        }
        refresh()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        locationManager?.stopUpdatingLocation()
    }

    @discardableResult
    func receive(_ dictionary: [String: Any], reply: ([String: Any]) -> Void) -> Bool {
        guard dictionary[Libre2LocationRequest.key] != nil else { return false }
        do {
            switch try Libre2LocationRequest.decode(dictionary) {
            case .inspect: break
            case .setEnabled(let enabled): preferences.backgroundLocationEnabled = enabled
            case .setAccuracy(let accuracy): preferences.backgroundLocationAccuracy = accuracy
            }
            refresh()
            reply(["enabled": preferences.backgroundLocationEnabled, "status": status,
                   "accuracy": preferences.backgroundLocationAccuracy.rawValue])
        } catch { reply(["error": error.localizedDescription]) }
        return true
    }

    private func refresh() {
        guard preferences.backgroundLocationEnabled else {
            stop(status: Texts_DirectLibre.locationOff)
            return
        }
        guard Libre2SessionStore.shared.snapshot.owner.allowsWatchConnection else {
            stop(status: Texts_DirectLibre.locationNeedsOwnership)
            return
        }

        // Never create/start a new location session from a background WCSession delivery.
        let isActive = WKExtension.shared().applicationState == .active
        guard isUpdating || isActive else {
            publish(Texts_DirectLibre.locationOpenWatch)
            return
        }
        if locationManager == nil {
            let manager = CLLocationManager()
            manager.delegate = self
            manager.distanceFilter = kCLDistanceFilterNone
            manager.activityType = .other
            manager.allowsBackgroundLocationUpdates = true
            locationManager = manager
        }
        guard let manager = locationManager else { return }
        // Apply to the existing session, including in the background; no location/BLE restart.
        let accuracy = Double(preferences.backgroundLocationAccuracy.rawValue)
        if manager.desiredAccuracy != accuracy { manager.desiredAccuracy = accuracy }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            guard !isUpdating else { return }
            isUpdating = true
            receivedLocation = false
            publish(Texts_DirectLibre.locationStarting)
            manager.startUpdatingLocation()
        case .notDetermined:
            publish(Texts_DirectLibre.locationPermission)
            if isActive && !requestedAuthorization {
                requestedAuthorization = true
                manager.requestWhenInUseAuthorization()
            }
        case .denied, .restricted:
            stop(status: Texts_DirectLibre.locationDenied)
        @unknown default:
            stop(status: Texts_DirectLibre.locationDenied)
        }
    }

    private func stop(status: String) {
        if isUpdating { locationManager?.stopUpdatingLocation() }
        isUpdating = false
        receivedLocation = false
        publish(status)
    }

    private func publish(_ value: String) {
        guard status != value else { return }
        status = value
        Libre2ActivityLog.shared.record(value)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refresh()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isUpdating, !receivedLocation, !locations.isEmpty else { return }
        receivedLocation = true
        publish(Texts_DirectLibre.locationReceiving)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard isUpdating else { return }
        if (error as? CLError)?.code == .denied {
            stop(status: Texts_DirectLibre.locationDenied)
        } else {
            // A missing fix is not a reason to restart location or touch the sensor connection.
            receivedLocation = false
            publish(Texts_DirectLibre.locationUnavailable)
        }
    }
}

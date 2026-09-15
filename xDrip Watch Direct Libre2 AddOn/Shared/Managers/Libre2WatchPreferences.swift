import Foundation

/// Watch preferences belong to the installation, not to a sensor handoff.
/// Keep the phone's last explicit unit choice when it cannot be reached after a restart.
struct Libre2WatchPreferences {
    private let defaults: UserDefaults
    private let unitsKey = "directLibreWatchIsMgDl"
    private let locationKey = "directLibreWatchBackgroundLocation"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Opt-in belongs to the Watch installation and survives sensor changes and restarts.
    var backgroundLocationEnabled: Bool {
        get { defaults.bool(forKey: locationKey) }
        nonmutating set { defaults.set(newValue, forKey: locationKey) }
    }

    func restoreUnits(cachedUnit: Bool? = nil) -> Bool {
        if let saved = defaults.object(forKey: unitsKey) as? Bool { return saved }
        // Existing installations may already have the choice in their complication cache.
        if let cachedUnit { defaults.set(cachedUnit, forKey: unitsKey) }
        return cachedUnit ?? true
    }

    /// Use the host's one-hour status window. Missing units must never imply mg/dL.
    func receiveUnits(_ dictionary: [String: Any], now: Date = Date()) -> Bool? {
        guard let generatedAt = dictionary["generatedAt"] as? Double,
              generatedAt.isFinite,
              Date(timeIntervalSince1970: generatedAt) > now.addingTimeInterval(-3600),
              let isMgDl = dictionary["isMgDl"] as? Bool else { return nil }
        if defaults.object(forKey: unitsKey) as? Bool != isMgDl {
            defaults.set(isMgDl, forKey: unitsKey)
        }
        return isMgDl
    }
}

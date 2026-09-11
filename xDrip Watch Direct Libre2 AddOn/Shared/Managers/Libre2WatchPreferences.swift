import Foundation

/// Display preferences belong to the Watch installation, not to a sensor handoff.
/// Keep the phone's last explicit unit choice when it cannot be reached after a restart.
struct Libre2WatchPreferences {
    private let defaults: UserDefaults
    private let unitsKey = "directLibreWatchIsMgDl"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

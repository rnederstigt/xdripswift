import Foundation

/// Watch preferences belong to the installation, not to a sensor handoff.
/// Keep the phone's last explicit display settings when it cannot be reached after a restart.
struct Libre2WatchPreferences {
    private let defaults: UserDefaults
    private let unitsKey = "directLibreWatchIsMgDl"
    private let locationKey = "directLibreWatchBackgroundLocation"
    private let limitsKey = "directLibreWatchGlucoseLimits"

    struct GlucoseLimits: Codable, Equatable {
        let urgentLow: Double
        let low: Double
        let high: Double
        let urgentHigh: Double

        var isValid: Bool {
            [urgentLow, low, high, urgentHigh].allSatisfy { $0.isFinite && $0 > 0 }
        }
    }

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
        guard isRecentStatus(dictionary, now: now),
              let isMgDl = dictionary["isMgDl"] as? Bool else { return nil }
        if defaults.object(forKey: unitsKey) as? Bool != isMgDl {
            defaults.set(isMgDl, forKey: unitsKey)
        }
        return isMgDl
    }

    func restoreLimits(cachedLimits: GlucoseLimits? = nil) -> GlucoseLimits? {
        if let data = defaults.data(forKey: limitsKey),
            let saved = try? JSONDecoder().decode(GlucoseLimits.self, from: data), saved.isValid {
            return saved
        }
        guard let cachedLimits, cachedLimits.isValid else { return nil }
        defaults.set(try? JSONEncoder().encode(cachedLimits), forKey: limitsKey)
        return cachedLimits
    }

    /// Accept a complete set in mg/dL, independently of whether the payload includes units.
    func receiveLimits(_ dictionary: [String: Any], now: Date = Date()) -> GlucoseLimits? {
        guard isRecentStatus(dictionary, now: now),
            let urgentLow = dictionary["urgentLowLimitInMgDl"] as? Double,
            let low = dictionary["lowLimitInMgDl"] as? Double,
            let high = dictionary["highLimitInMgDl"] as? Double,
            let urgentHigh = dictionary["urgentHighLimitInMgDl"] as? Double else { return nil }
        let limits = GlucoseLimits(urgentLow: urgentLow, low: low, high: high, urgentHigh: urgentHigh)
        guard limits.isValid else { return nil }
        if restoreLimits() != limits {
            defaults.set(try? JSONEncoder().encode(limits), forKey: limitsKey)
        }
        return limits
    }

    private func isRecentStatus(_ dictionary: [String: Any], now: Date) -> Bool {
        guard let generatedAt = dictionary["generatedAt"] as? Double, generatedAt.isFinite else { return false }
        return Date(timeIntervalSince1970: generatedAt) > now.addingTimeInterval(-3600)
    }
}

import Foundation

/// Maps the add-on's display interface to xDrip's existing Watch model.
/// History merging, validation and trend calculation live in Libre2WatchManager / Libre2ReadingPipeline.
extension WatchStateModel: Libre2WatchDisplay {
    /// Manual refresh only. Automatic phone refreshes retain the host's original behaviour.
    func refreshAfterDoubleTap() {
        if directLibre.isDirect {
            directLibre.retryConnection()
        } else {
            requestWatchStateUpdate()
        }
    }

    /// Restore before the collector can publish a reading or overwrite the complication cache.
    func restoreDirectLibrePreferences() {
        let defaults = UserDefaults(suiteName: Bundle.main.appGroupSuiteName)
        let data = defaults?.data(forKey: "complicationSharedUserDefaults.\(Bundle.main.mainAppBundleIdentifier)")
        let cached = data.flatMap { try? JSONDecoder().decode(ComplicationSharedUserDefaultsModel.self, from: $0) }
        let preferences = Libre2WatchPreferences()
        isMgDl = preferences.restoreUnits(cachedUnit: cached?.isMgDl)
        let cachedLimits = cached.map {
            Libre2WatchPreferences.GlucoseLimits(urgentLow: $0.urgentLowLimitInMgDl, low: $0.lowLimitInMgDl,
                                                high: $0.highLimitInMgDl, urgentHigh: $0.urgentHighLimitInMgDl)
        }
        if let limits = preferences.restoreLimits(cachedLimits: cachedLimits) {
            _ = applyDirectLibreLimits(limits)
        }
    }

    /// Display settings may follow the phone during direct collection; sensor status and readings may not.
    func receiveDirectLibrePreferences(_ dictionary: [String: Any]) -> Bool {
        let preferences = Libre2WatchPreferences()
        var changed = false
        if let units = preferences.receiveUnits(dictionary), units != isMgDl {
            if directLibre.isDirect {
                deltaValueInUserUnit = Libre2ReadingPipeline.trend(from: libreReadingHistory, isMgDl: units).delta
            }
            isMgDl = units
            changed = true
        }
        // Persist in either mode; ordinary relay retains its original status assignments.
        if let limits = preferences.receiveLimits(dictionary), directLibre.isDirect {
            changed = applyDirectLibreLimits(limits) || changed
        }
        return changed
    }

    private func applyDirectLibreLimits(_ limits: Libre2WatchPreferences.GlucoseLimits) -> Bool {
        guard urgentLowLimitInMgDl != limits.urgentLow || lowLimitInMgDl != limits.low ||
            highLimitInMgDl != limits.high || urgentHighLimitInMgDl != limits.urgentHigh else { return false }
        urgentLowLimitInMgDl = limits.urgentLow
        lowLimitInMgDl = limits.low
        highLimitInMgDl = limits.high
        urgentHighLimitInMgDl = limits.urgentHigh
        return true
    }

    var libreReadingHistory: [Libre2Sample] {
        zip(bgReadingDates, bgReadingValues).map { date, value in
            Libre2Sample(timeStamp: date, glucoseLevelRaw: value)
        }
    }

    var libreUsesMgDl: Bool { isMgDl }
    var libreLatestReadingDate: Date? { bgReadingDates.first }

    func applyLibreReadings(_ batch: Libre2ReadingBatch) {
        bgReadingValues = batch.values
        bgReadingDates = batch.dates.map { Date(timeIntervalSince1970: $0) }
        bgReadingDatesAsDouble = batch.dates
        slopeOrdinal = batch.slope
        deltaValueInUserUnit = batch.delta
        updatedDate = batch.generatedAt
        lastUpdatedTextString = Texts_WatchApp.lastReading + " "
        lastUpdatedTimeString = bgReadingDates[0].formatted(date: .omitted, time: .shortened)
        lastUpdatedTimeAgoString = bgReadingDates[0].daysAndHoursAgo(appendAgo: true)
        // Direct collection bypasses the host payload dispatcher and needs its own refresh.
        updateComplicationData()
    }

    func updateDirectLibreSensorAge(_ age: UInt16) {
        sensorAgeInMinutes = Double(age)
        keepAliveIsDisabled = false
        sensorNoiseStateRawValue = nil
    }

    func refreshLibreConnectionStatus() { objectWillChange.send() }
}

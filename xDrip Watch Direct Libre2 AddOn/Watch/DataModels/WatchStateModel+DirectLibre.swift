import Foundation

/// Maps the add-on's display interface to xDrip's existing Watch model.
/// History merging, validation and trend calculation live in Libre2WatchManager / Libre2ReadingPipeline.
extension WatchStateModel: Libre2WatchDisplay {
    /// Restore before the collector can publish a reading or overwrite the complication cache.
    func restoreDirectLibreUnits() {
        let defaults = UserDefaults(suiteName: Bundle.main.appGroupSuiteName)
        let data = defaults?.data(forKey: "complicationSharedUserDefaults.\(Bundle.main.mainAppBundleIdentifier)")
        let cached = data.flatMap { try? JSONDecoder().decode(ComplicationSharedUserDefaultsModel.self, from: $0) }
        isMgDl = Libre2WatchPreferences().restoreUnits(cachedUnit: cached?.isMgDl)
    }

    /// Units may follow the phone during direct collection; sensor status and readings may not.
    func receiveDirectLibreUnits(_ dictionary: [String: Any]) -> Bool {
        guard let units = Libre2WatchPreferences().receiveUnits(dictionary), units != isMgDl else { return false }
        if directLibre.isDirect {
            deltaValueInUserUnit = units ? deltaValueInUserUnit * 18.0182 : deltaValueInUserUnit / 18.0182
        }
        isMgDl = units
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

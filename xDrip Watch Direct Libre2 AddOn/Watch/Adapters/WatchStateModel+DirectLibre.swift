import Foundation

/// Maps the add-on's display interface to xDrip's existing Watch model.
/// History merging, validation and trend calculation live in Libre2WatchAddOn / Libre2ReadingPipeline.
extension WatchStateModel: Libre2WatchDisplay {
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
        updateComplicationData()
    }

    func updateDirectLibreSensorAge(_ age: UInt16) {
        sensorAgeInMinutes = Double(age)
        keepAliveIsDisabled = false
        sensorNoiseStateRawValue = nil
    }

    func refreshLibreConnectionStatus() { objectWillChange.send() }
}

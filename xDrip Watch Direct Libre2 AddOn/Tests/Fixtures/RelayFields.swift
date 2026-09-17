
    var directLibre = DirectMode()
    var bgReadingValues: [Double] = [] { didSet { applied += 1 } }
    var bgReadingDates: [Date] = []
    var bgReadingDatesAsDouble: [Double] = []
    var slopeOrdinal = 0
    var deltaValueInUserUnit: Double = 0
    var updatedDate = Date(timeIntervalSince1970: 0)
    var lastUpdatedTextString = ""
    var lastUpdatedTimeString = ""
    var lastUpdatedTimeAgoString = ""
    var applied = 0
    var complicationUpdates = 0
    func bgReadingDate() -> Date? { bgReadingDates.first }
    func updateComplicationData() { complicationUpdates += 1 }
    private func processStatusFromDictionary(dictionary: [String: Any]) -> Bool { false }
    private func processAGPFromDictionary(dictionary: [String: Any]) {}
    func deliver(_ payload: [String: Any]) { processWatchPayloadFromDictionary(dictionary: ["bgReadings": payload]) }

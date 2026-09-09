import Foundation

/// One parsed sample. iOS may request raw values; Watch requires native conversion.
struct Libre2Sample: Codable, Equatable {
    let timeStamp: Date
    var glucoseLevelRaw: Double
}

/// Overlap cache supplied by the caller, so the parser has no UserDefaults dependency.
struct Libre2ParserState: Codable {
    var previousRawGlucoseValues: [Int]?
    var previousRawTemperatureValues: [Int]?
    var previousTemperatureAdjustmentValues: [Int]?
}

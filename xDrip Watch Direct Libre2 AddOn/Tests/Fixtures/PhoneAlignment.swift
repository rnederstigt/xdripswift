
import Foundation
final class BgReading {
    let timeStamp: Date
    let finalValue: Double
    var calculatedValueSlope = 0.0
    var hideSlope = false
    init(_ sample: Libre2Sample) { timeStamp = sample.timeStamp; finalValue = sample.glucoseLevelRaw }
/* @source:calculate_slope */
/* @source:slope_ordinal */
}
enum ConstantsBGGraphBuilder { /* @source:max_slope */ }
/* @source:glucose_constants */
extension Date {
/* @source:timestamp_conversion */
}
extension Double {
/* @source:unit_conversion */
}
final class PhoneCalibrator {
/* @source:find_slope */
}

final class UserDefaults {
    static let standard = UserDefaults()
    var bloodGlucoseUnitIsMgDl = true
}
struct WatchBgReadings {
    let generatedAt: Double
    let hoursIncluded: Double
    let bgReadingValues: [Double]
    let bgReadingDatesAsDouble: [Double]
    let slopeOrdinal: Int
    let deltaValueInUserUnit: Double
}
final class ReadingAccessor {
    var readings: [BgReading] = []
    func getLatestBgReadingSnapshots(limit: Int?, fromDate: Date, forSensor: Int?,
                                    ignoreRawData: Bool, ignoreCalculatedValue: Bool) -> [BgReading] { readings }
}
final class PhoneWatchManager {
    let bgReadingsAccessor = ReadingAccessor()
    func result() -> WatchBgReadings { currentBgReadings() }
/* @source:phone_payload */
}

struct Libre2WatchPreferences {
    func receiveLimits(_ dictionary: [String: Any]) -> Int? { nil }
    func receiveUnits(_ dictionary: [String: Any]) -> Bool? { dictionary["isMgDl"] as? Bool }
}
final class DirectMode { var isDirect = true }
final class WatchStateModel {
    let directLibre = DirectMode()
    var isMgDl = true
    var deltaValueInUserUnit = 0.0
    var libreReadingHistory: [Libre2Sample] = []
    func applyDirectLibreLimits(_ limits: Int) -> Bool { preconditionFailure("Unit-only test unexpectedly received limits") }
/* @source:receive_preferences */
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
let phone = PhoneWatchManager()
var cases = 0
func compare(_ values: [Double], gap: Double) {
    let samples = values.enumerated().map { index, value in
        Libre2Sample(timeStamp: now.addingTimeInterval(-Double(index) * gap), glucoseLevelRaw: value)
    }
    var readings = samples.map(BgReading.init)
    PhoneCalibrator().findSlope(for: readings[0], last2Readings: &readings)
    phone.bgReadingsAccessor.readings = readings
    for units in [true, false] {
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = units
        let expected = phone.result()
        let direct = Libre2ReadingPipeline.trend(from: samples, isMgDl: units)
        precondition(direct.slopeOrdinal == expected.slopeOrdinal,
                     "Arrow differs: values=\(values), gap=\(gap)")
        precondition(abs(direct.delta - expected.deltaValueInUserUnit) < 0.0000001,
                     "Delta differs: values=\(values), units=\(units)")
        cases += 1
    }
}
for rate in [-3.501, -3.5, -3.499, -3.2, -2.001, -2, -1.999, -1.001, -1, -0.999,
             0, 0.999, 1, 1.001, 1.999, 2, 2.001, 3.2, 3.499, 3.5, 3.501] {
    for gap in [30.0, 60, 120, 1260, 1261] {
        compare([200 + rate * gap / 60, 200], gap: gap)
    }
}
compare([115], gap: 60)
compare([115, 110], gap: 0)
for latest in stride(from: 70.0, through: 200, by: 1) { compare([latest, 100], gap: 60) }

// Unit changes must recalculate from mg/dL history, not convert an already rounded delta.
let watch = WatchStateModel()
watch.libreReadingHistory = [Libre2Sample(timeStamp: now, glucoseLevelRaw: 109),
                            Libre2Sample(timeStamp: now.addingTimeInterval(-60), glucoseLevelRaw: 100)]
watch.deltaValueInUserUnit = 9
for units in [false, true, false, true] {
    precondition(watch.receiveDirectLibrePreferences(["isMgDl": units]))
    precondition(abs(watch.deltaValueInUserUnit - (units ? 9 : 0.4)) < 0.0000001)
}
watch.directLibre.isDirect = false
watch.deltaValueInUserUnit = 17
precondition(watch.receiveDirectLibrePreferences(["isMgDl": false]))
precondition(watch.deltaValueInUserUnit == 17, "Ordinary relay delta was changed")
print("\(cases) phone/Watch trend comparisons passed; repeated unit changes and ordinary relay guard passed.")

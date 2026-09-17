import Foundation
struct Libre2Sample { let timeStamp: Date; let glucoseLevelRaw: Double }
final class DirectMode { var isDirect = false }
enum Texts_WatchApp { static let lastReading = "Last reading"; static let noSensorData = "No data" }
extension Date { func daysAndHoursAgo(appendAgo: Bool) -> String { "display formatting stub" } }
/* @source:libre_constants *//* @source:reading_pipeline */
final class UpstreamWatch {
/* @source:display_fields *//* @source:receive_payload */
/* @source:original_readings */
}
final class AddOnWatch {
/* @source:display_fields *//* @source:receive_payload */
/* @source:current_readings */
/* @source:apply_readings */
    func deliverDirect(_ batch: Libre2ReadingBatch) {
        guard batch.isAcceptable(after: bgReadingDates.first) else { return }
        applyLibreReadings(batch)
    }
}

let now = Date()
let cases: [(String, [Double]?, [Double])] = [
    ("normal fresh", [110, 108], [-30, -90]),
    ("older recent replacement", [110, 108], [-120, -180]),
    ("future timestamp", [110, 108], [120, 60]),
    ("zero historical value", [110, 0], [-30, -90]),
    ("missing values", nil, [-30]),
    ("mismatched arrays", [110], [-30, -90]),
    ("over an hour old", [110], [-7200])
]
for (name, values, offsets) in cases {
    let upstream = UpstreamWatch(), addOn = AddOnWatch()
    upstream.bgReadingDates = [now.addingTimeInterval(-60)]
    addOn.bgReadingDates = upstream.bgReadingDates
    var payload: [String: Any] = ["bgReadingDatesAsDouble": offsets.map { now.addingTimeInterval($0).timeIntervalSince1970 }, "generatedAt": now.timeIntervalSince1970]
    if let values { payload["bgReadingValues"] = values }
    upstream.deliver(payload); addOn.deliver(payload)
    print("\(name): upstream accepted=\(upstream.applied > 0), complication calls=\(upstream.complicationUpdates); add-on accepted=\(addOn.applied > 0), complication calls=\(addOn.complicationUpdates)")
    precondition(upstream.complicationUpdates == addOn.complicationUpdates, name)
    precondition(upstream.applied == addOn.applied, name)
    precondition(upstream.bgReadingValues == addOn.bgReadingValues, name)
    precondition(upstream.bgReadingDates == addOn.bgReadingDates, name)
    precondition(upstream.updatedDate == addOn.updatedDate, name)
    addOn.directLibre.isDirect = true
    let previousUpdates = addOn.complicationUpdates
    addOn.deliver(payload)
    precondition(addOn.complicationUpdates == previousUpdates, "Relay overwrote direct mode")
}

let direct = AddOnWatch()
direct.deliverDirect(Libre2ReadingBatch(values: [110], dates: [now.timeIntervalSince1970], slope: 4, delta: 0, generatedAt: now))
precondition(direct.complicationUpdates == 1)
direct.deliverDirect(Libre2ReadingBatch(values: [0], dates: [now.timeIntervalSince1970], slope: 4, delta: 0, generatedAt: now))
precondition(direct.complicationUpdates == 1)
print("Direct samples: valid refreshes once; malformed sample rejected. Relay blocked while direct.")

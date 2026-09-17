import Foundation
final class Sensor { let id: Int; init(_ id: Int) { self.id = id } }
final class BgReading {
    let timeStamp: Date
    let sensor: Sensor
    let calculatedValue: Double = 100
    let adjustedValue: NSNumber? = 121.4
    let finalValue: Double = 133.6
    init(_ date: Date, _ sensor: Sensor) { timeStamp = date; self.sensor = sensor }
    func slopeOrdinal() -> Int { 4 }
    var slopeName: String { "SingleUp" }
}
final class CoreDataManager {
    var sensor: Sensor? = Sensor(1)
    var rows: [BgReading] = []
    var calibration: BgReading?
}
struct SensorsAccessor {
    let coreDataManager: CoreDataManager
    func fetchActiveSensor() -> Sensor? { coreDataManager.sensor }
}
struct CalibrationsAccessor {
    let coreDataManager: CoreDataManager
    func lastCalibrationForActiveSensor(withActivesensor: Sensor) -> BgReading? { coreDataManager.calibration }
}
struct BgReadingsAccessor {
    let coreDataManager: CoreDataManager
    func getLatestBgReadings(limit: Int, fromDate: Date, forSensor: Sensor,
        ignoreRawData: Bool, ignoreCalculatedValue: Bool) -> [BgReading] {
        precondition(ignoreRawData && !ignoreCalculatedValue)
        precondition(limit == ConstantsShareWithLoop.maxReadingsToShareWithLoop)
        return Array(coreDataManager.rows.filter { $0.sensor.id == forSensor.id && $0.timeStamp > fromDate }
            .sorted { $0.timeStamp > $1.timeStamp }.prefix(limit))
    }
}
enum Sharing { case disabled, enabled }
extension UserDefaults {
    static var master = true
    static var sharing = Sharing.enabled
    static var smoothed = false
    static var cursor: Date?
    var isMaster: Bool { Self.master }
    var loopShareType: Sharing { Self.sharing }
    var loopShareSmoothedData: Bool { Self.smoothed }
    var timeStampLatestLoopSharedBgReading: Date? { Self.cursor }
}
extension TimeInterval { init(minutes: Double) { self = minutes * 60 } }
final class LoopManager {
    static var delay: Double = 300
    static var osAidSharingPermitted = true
    static func loopDelay() -> Double { delay }
    var glucoseData: [GlucoseData] = []
}
enum Libre2PhoneReadingProcessing {
    static func prepareDelayedSharing(coreDataManager: CoreDataManager?, loopManager: LoopManager?, now: Date) {
/* @source:prepare */
    }
}
@main struct SharingTests {
    static func main() {
        let manager = CoreDataManager(), loop = LoopManager()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sensor = manager.sensor!
        manager.rows = (0..<100).map { BgReading(now.addingTimeInterval(Double(-$0 * 60)), sensor) }
        manager.rows.append(BgReading(now.addingTimeInterval(-1), Sensor(2)))
        manager.rows.append(BgReading(now.addingTimeInterval(1), sensor))
        UserDefaults.cursor = now.addingTimeInterval(-1800)
        func prepare() { Libre2PhoneReadingProcessing.prepareDelayedSharing(coreDataManager: manager, loopManager: loop, now: now) }
        prepare()
        precondition(loop.glucoseData.count == ConstantsShareWithLoop.maxReadingsToShareWithLoop - 1)
        precondition(loop.glucoseData.first!.timeStamp == now)
        precondition(loop.glucoseData.allSatisfy { $0.glucoseLevelRaw == 121 && $0.slopeOrdinal == 4 && $0.slopeName == "SingleUp" })
        precondition(loop.glucoseData.last!.timeStamp == now.addingTimeInterval(-58 * 60))
        print("PASS: delayed buffer preserves timestamps/trends, active sensor, descending order and host limit; excludes future samples")
        UserDefaults.smoothed = true; prepare()
        precondition(loop.glucoseData.allSatisfy { $0.glucoseLevelRaw == 134 })
        print("PASS: actual phone sharing-value policy honors optional smoothing")
        let retained = loop.glucoseData
        LoopManager.delay = 0; manager.rows = []; prepare()
        precondition(loop.glucoseData.count == retained.count)
        LoopManager.delay = 300
        for condition in 0..<5 {
            loop.glucoseData = retained
            UserDefaults.master = condition != 0
            UserDefaults.sharing = condition == 1 ? .disabled : .enabled
            LoopManager.osAidSharingPermitted = condition != 2
            manager.sensor = condition == 3 ? nil : sensor
            manager.calibration = condition == 4 ? BgReading(now, sensor) : nil
            prepare()
            precondition(loop.glucoseData.isEmpty)
        }
        print("PASS: immediate-sharing buffer is untouched; disabled/follower/blocked/missing-sensor/recent-calibration cases clear stale delayed data")
        UserDefaults.master = true; UserDefaults.sharing = .enabled
        LoopManager.osAidSharingPermitted = true; manager.sensor = sensor; manager.calibration = nil
        UserDefaults.cursor = nil
        manager.rows = (0..<100).map { BgReading(now.addingTimeInterval(Double(-$0 * 60)), sensor) }
        prepare()
        precondition(loop.glucoseData.count == 30)
        manager.rows.removeAll(); prepare(); precondition(loop.glucoseData.isEmpty)
        print("PASS: no-cursor startup uses the existing 30-minute window; rebuilding removes old cached readings")
    }
}

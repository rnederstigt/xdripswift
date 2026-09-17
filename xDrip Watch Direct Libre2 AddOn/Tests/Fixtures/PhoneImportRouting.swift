import Foundation
var calls: [String] = []
var current = true
var changeDuringProcessing = false
final class Sensor { let id = "active" }
final class CoreDataManager { var active: Sensor? = Sensor() }
struct SensorsAccessor {
    let coreDataManager: CoreDataManager
    func fetchActiveSensor() -> Sensor? { coreDataManager.active }
}
struct ConstantsLog { static let categoryRootView = "root" }
enum LogType { case info }
func trace(_ message: String, log: String, category: String, type: LogType) { calls.append("trace") }
final class Consumer {
    let name: String
    init(_ name: String) { self.name = name }
    func record(_ method: String) { calls.append(name + "." + method) }
    func processLatestReadings() -> Bool {
        record("process")
        if changeDuringProcessing { current = false }
        return true
    }
    func update(activeSensor: Sensor) { record("noise:" + activeSensor.id) }
    func invalidateCharts() { record("invalidateCharts") }
    func invalidate() { record("invalidate") }
    func uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp date: Date?) { record("upload:" + String(date!.timeIntervalSince1970)) }
    func syncAllWithNightscout() { record("syncAll") }
    func storeBgReadings() { record("store") }
    func speakNewReading(lastConnectionStatusChangeTimeStamp date: Date?) { record("speak:" + String(date!.timeIntervalSince1970)) }
    func sendLatestReading() { record("send") }
    func processNewReading(lastConnectionStatusChangeTimeStamp date: Date?) { record("process:" + String(date!.timeIntervalSince1970)) }
    func processNewReading() { record("process") }
    func share() { record("share") }
    func updateWatchApp(forceComplicationUpdate: Bool) { record("watch:" + String(forceComplicationUpdate)) }
}
final class Accessor {
    var count = 2
    func getLatestBgReadings(limit: Int, howOld: Date?, forSensor: Sensor, ignoreRawData: Bool,
        ignoreCalculatedValue: Bool, includingSuppressed: Bool) -> [Int] {
        precondition(limit == 36 && howOld == nil && !ignoreRawData && ignoreCalculatedValue && includingSuppressed)
        calls.append("calibrationQuery")
        return Array(repeating: 0, count: count)
    }
}
final class Transmitter {
    var web = false
    var override = false
    func isWebOOPEnabled() -> Bool { web }
    func overruleIsWebOOPEnabled() -> Bool { override }
}
enum Libre2PhoneReadingProcessing {
    static func isCurrentReading(_ date: Date?, coreDataManager: CoreDataManager?) -> Bool { date != nil && current }
    static func prepareDelayedSharing(coreDataManager: CoreDataManager?, loopManager: Consumer?) { calls.append("prepareDelayedSharing") }
}
final class RootApplicationCoordinator {
    let log = "root"
    var coreDataManager: CoreDataManager? = CoreDataManager()
    var activeSensor = Sensor()
    var firstCalibrationForActiveSensor: Int? = 1
    var lastCalibrationForActiveSensor: Int? = 1
    let cgmTransmitter = Transmitter()
    var bgReadingsAccessor: Accessor? = Accessor()
    var bgPostProcessingManager: Consumer? = Consumer("post")
    var sensorNoiseManager: Consumer? = Consumer("noise")
    var nightscoutSyncManager: Consumer? = Consumer("nightscout")
    var healthKitManager: Consumer? = Consumer("health")
    var bgReadingSpeaker: Consumer? = Consumer("speaker")
    var dexcomShareUploadManager: Consumer? = Consumer("dexcom")
    var bluetoothPeripheralManager: Consumer? = Consumer("bluetooth")
    var calendarManager: Consumer? = Consumer("calendar")
    var contactImageManager: Consumer? = Consumer("contact")
    var loopManager: Consumer? = Consumer("loop")
    var watchManager: Consumer? = Consumer("watch")
    var statisticsManager: Consumer? = Consumer("statistics")
    let rootHomeStateModel = Consumer("home")
    func lastConnectionStatusChangeTimeStamp() -> Date { Date(timeIntervalSince1970: 123) }
    func checkAlertsCreateNotificationAndSetAppBadge() { calls.append("alerts") }
    func createInitialCalibrationRequest() { calls.append("calibration") }
    func updateLabelsAndChart(overrideApplicationState: Bool) { calls.append("labels:" + String(overrideApplicationState)) }
    func updateLiveActivityAndWidgets(forceRestart: Bool) { calls.append("widgets:" + String(forceRestart)) }
    func updatePumpAndAIDStatusViews() { calls.append("pump") }
    func updateMiniChart() { calls.append("mini") }
    func updateStatistics(animate: Bool) { calls.append("stats:" + String(animate)) }
    func updateDataSourceInfo() { calls.append("source") }
    func originalPhone() {
        let bgReadingsAccessor = self.bgReadingsAccessor!
/* @source:old */
    }
    func phone() {
/* @source:phone */
    }
/* @source:shared */
    func receive(_ info: [String: Any]) {
        let notification = Notification(name: Notification.Name("Imported"), userInfo: info)
/* @source:handler_body */
    }
}
@main struct RoutingTests {
    static func main() {
        var cases = 0
        for first in [nil, 1] as [Int?] {
            for last in [nil, 1] as [Int?] {
                for web in [false, true] { for override in [false, true] {
                    for count in 0...2 { for optional in [false, true] {
                        let root = RootApplicationCoordinator()
                        root.firstCalibrationForActiveSensor = first
                        root.lastCalibrationForActiveSensor = last
                        root.cgmTransmitter.web = web
                        root.cgmTransmitter.override = override
                        root.bgReadingsAccessor!.count = count
                        if optional {
                            root.nightscoutSyncManager = nil; root.watchManager = nil
                            root.bgPostProcessingManager = nil; root.loopManager = nil
                            root.bgReadingSpeaker = nil; root.sensorNoiseManager = nil
                        }
                        calls = []; root.originalPhone(); let expected = calls
                        calls = []; root.phone()
                        precondition(calls == expected, "Ordinary phone order/arguments changed: \(calls) != \(expected)")
                        cases += 1
                    }}
                }}
            }
        }
        print("PASS: \(cases) ordinary phone calibration/settings/optional-manager cases match the original call order and arguments")
        let root = RootApplicationCoordinator()
        let fresh: [String: Any] = [Libre2PhoneHistoryUpdate.currentReadingDateKey: Date(),
            Libre2PhoneHistoryUpdate.changedSensorIDsKey: ["active"]]
        calls = []; root.phone()
        var expected = ["statistics.invalidate"] + calls.map {
            $0 == "labels:false" ? "labels:true" : ($0 == "watch.watch:false" ? "watch.watch:true" : $0)
        }
        expected.insert("prepareDelayedSharing", at: expected.firstIndex(of: "loop.share")!)
        calls = []; root.receive(fresh)
        precondition(calls == expected)
        print("PASS: current Watch import uses every normal downstream consumer after processing")
        let live = ["alerts", "speaker.speak:123.0", "bluetooth.send", "calendar.process:123.0", "contact.process", "loop.share", "prepareDelayedSharing"]
        calls = []; root.receive([Libre2PhoneHistoryUpdate.changedSensorIDsKey: ["active"]])
        precondition(calls == expected.filter { !live.contains($0) })
        print("PASS: historical import processes and exports history without live effects")
        changeDuringProcessing = true
        calls = []; root.receive(fresh)
        precondition(calls == expected.filter { !live.contains($0) })
        changeDuringProcessing = false; current = true
        print("PASS: freshness is reevaluated after processing suppresses the current reading")
        for info in [[:], [Libre2PhoneHistoryUpdate.changedSensorIDsKey: ["ended"]]] as [[String: Any]] {
            calls = []; root.receive(info)
            precondition(calls == expected.filter { !live.contains($0) && $0 != "post.process" && $0 != "noise.noise:active" })
        }
        print("PASS: duplicate/ended-sensor history avoids reprocessing the unrelated active sensor")
    }
}

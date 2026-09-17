#!/usr/bin/env python3
"""Execute production downstream routing with spies and compare ordinary phone call order.

The baseline is the pre-extraction coordinator. No networking, alerts or uploads run.
Core Data and export policies are covered separately by hosted tests and device testing.
"""
from pathlib import Path
import subprocess
from swift_test_runner import run_swift, test_directory

addon = Path(__file__).resolve().parents[1]
repo = addon.parent
path = 'xDrip/Managers/Application/RootApplicationCoordinator.swift'
source = (repo / path).read_text()
baseline = subprocess.check_output(['git', 'show', '4499634896fe7e5ab0379d7076d9473f1c137161:' + path], cwd=repo, text=True)

def block(text, marker):
    start = text.index(marker) + len(marker)
    depth, end = 1, start
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end - 1]

old = block(baseline, 'if newReadingCreated {')
shared_start = source.index('    private func processStoredGlucoseData(')
shared_body = block(source[shared_start:], '    ) {')
shared = source[shared_start:source.index('    ) {', shared_start) + len('    ) {')] + shared_body + '}'
handler_body = block(source, '    @objc private func handleDirectLibreHistoryDidImport(_ notification: Notification) {')
phone = block(source, 'if newReadingCreated {')
harness = r'''import Foundation
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
''' + old + r'''
    }
    func phone() {
''' + phone + r'''
    }
''' + shared + r'''
    func receive(_ info: [String: Any]) {
        let notification = Notification(name: Notification.Name("Imported"), userInfo: info)
''' + handler_body + r'''
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
'''
with test_directory('direct-libre-import-') as work:
    main = work / 'ImportRouting.swift'
    main.write_text(harness)
    executable = work / 'import-tests'
    run_swift(executable, [
        addon / 'Shared/DataModels/Libre2PhoneHistoryUpdate.swift',
        main,
    ], flags=['-swift-version', '5'])

# Execute the actual delayed-buffer adapter with database/settings doubles. This
# checks the values passed to the existing sharing manager, not an app-group write.
processing = (addon / 'iPhone/Managers/Libre2PhoneReadingProcessing.swift').read_text()
prepare = block(processing, 'static func prepareDelayedSharing(coreDataManager: CoreDataManager?, loopManager: LoopManager?, now: Date = Date()) {')
sharing = r'''import Foundation
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
''' + prepare + r'''
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
'''
with test_directory('direct-libre-sharing-') as work:
    main = work / 'Sharing.swift'
    main.write_text(sharing)
    executable = work / 'sharing-tests'
    run_swift(executable, [
        repo / 'xDrip/BluetoothTransmitter/CGM/Generic/GlucoseData.swift',
        repo / 'xDrip/Managers/Loop/BgReading+LoopShare.swift',
        repo / 'xDrip/Constants/ConstantsShareWithLoop.swift',
        main,
    ], flags=['-swift-version', '5'])

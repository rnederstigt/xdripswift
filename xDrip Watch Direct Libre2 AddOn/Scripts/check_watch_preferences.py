#!/usr/bin/env python3
"""Execute the Watch display adapter with isolated defaults and a complication spy.

The actual settings adapter, preference store and complication cache model are used.
The collector, display formatting and WidgetKit delivery are replaced with doubles.
"""
from pathlib import Path
import subprocess
import re
from swift_test_runner import run_swift, test_directory

addon = Path(__file__).resolve().parents[1]
repo = addon.parent
host_path = 'xDrip Watch App/DataModels/WatchStateModel.swift'
host = (repo / host_path).read_text()
# This reviewed host baseline includes the delivery/lifecycle hooks added after the
# original preference work. Compare the whole file; no adapter-only change needs a host edit.
expected = subprocess.check_output(['git', 'show', '58d40a4:' + host_path], cwd=repo, text=True)
# Remove exactly the retired investigation hooks from the reviewed baseline.
expected = re.sub(r'^ *Libre2LifecycleDiagnostics\.recordSession\([^\n]*\n(?: *details:[^\n]*\n)?', '', expected, flags=re.M)
expected = re.sub(r'^ *recordLibreComplicationCache\([^\n]*\n', '', expected, flags=re.M)
expected = expected.replace('    func session(_: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {\n        directLibre.historyTransferFinished(userInfoTransfer.userInfo, error: error)\n    }\n', '')
expected = expected.replace('if userInfo[Libre2HandoffMessage.retiredIDsKey] != nil\n                || (try? Libre2HandoffMessage.decode(userInfo).kind) == .revoke {', 'if userInfo[Libre2HandoffMessage.retiredIDsKey] != nil {')
assert host == expected, 'Host changes exceed the reviewed functional hooks and diagnostic removals'
assert host.index('restoreDirectLibrePreferences()') < host.index('directLibre.restore()')
assert 'processedUpdate = processStatusFromDictionary(dictionary: statusDictionary)' in host

adapter = (addon / 'Watch/DataModels/WatchStateModel+DirectLibre.swift').read_text().replace(
    'Libre2WatchPreferences()', 'Libre2WatchPreferences(defaults: testDefaults)')
code = r'''import Foundation
let suite = "DirectLibrePreferencesProbe." + UUID().uuidString
let testDefaults = UserDefaults(suiteName: suite)!
extension Bundle {
    var appGroupSuiteName: String { suite + ".complication" }
    var mainAppBundleIdentifier: String { "test" }
}
extension Date { func daysAndHoursAgo(appendAgo: Bool) -> String { "recent" } }
enum Texts_WatchApp { static let lastReading = "Last reading" }
struct Libre2Sample { let timeStamp: Date; let glucoseLevelRaw: Double }
protocol Libre2WatchDisplay: AnyObject {}
final class DirectMode {
    var isDirect = true
    func restartConnection() {}
}
struct Publisher { func send() {} }
final class WatchStateModel {
    let directLibre = DirectMode()
    let objectWillChange = Publisher()
    var isMgDl = true
    var urgentLowLimitInMgDl = 60.0, lowLimitInMgDl = 80.0, highLimitInMgDl = 170.0, urgentHighLimitInMgDl = 250.0
    var bgReadingValues: [Double] = [], bgReadingDatesAsDouble: [Double] = []
    var bgReadingDates: [Date] = []
    var slopeOrdinal = 2, deltaValueInUserUnit = 0.0, updatedDate = Date()
    var lastUpdatedTextString = "", lastUpdatedTimeString = "", lastUpdatedTimeAgoString = ""
    var sensorAgeInMinutes = 99.0, keepAliveIsDisabled = false, sensorNoiseStateRawValue: Int?
    var publishedLimits: Libre2WatchPreferences.GlucoseLimits?
    func requestWatchStateUpdate() {}
    func updateComplicationData() {
        publishedLimits = .init(urgentLow: urgentLowLimitInMgDl, low: lowLimitInMgDl,
                               high: highLimitInMgDl, urgentHigh: urgentHighLimitInMgDl)
    }
}
'''
code += adapter
code += r'''
@main struct PreferencesProbe {
    static func main() throws {
        let cacheDefaults = UserDefaults(suiteName: Bundle.main.appGroupSuiteName)!
        defer {
            testDefaults.removePersistentDomain(forName: suite)
            cacheDefaults.removePersistentDomain(forName: Bundle.main.appGroupSuiteName)
        }
        let expected = Libre2WatchPreferences.GlucoseLimits(urgentLow: 65, low: 75, high: 190, urgentHigh: 240)
        var payload: [String: Any] = ["generatedAt": Date().timeIntervalSince1970,
            "isMgDl": false, "urgentLowLimitInMgDl": 65.0, "lowLimitInMgDl": 75.0,
            "highLimitInMgDl": 190.0, "urgentHighLimitInMgDl": 240.0, "sensorAgeInMinutes": 500.0]
        let model = WatchStateModel()
        model.bgReadingDates = [Date(), Date().addingTimeInterval(-60)]
        model.bgReadingValues = [110, 100]
        precondition(model.receiveDirectLibrePreferences(payload))
        model.updateComplicationData()
        precondition(model.publishedLimits == expected && !model.isMgDl && model.sensorAgeInMinutes == 99)
        let delta = model.deltaValueInUserUnit
        precondition(!model.receiveDirectLibrePreferences(payload))
        payload["highLimitInMgDl"] = 200.0
        precondition(model.receiveDirectLibrePreferences(payload))
        precondition(model.highLimitInMgDl == 200 && model.deltaValueInUserUnit == delta)
        payload.removeValue(forKey: "isMgDl")
        payload["highLimitInMgDl"] = 190.0
        precondition(model.receiveDirectLibrePreferences(payload))
        print("PASS: limits-only changes request a complication refresh in direct mode; duplicates do not; units/trend and sensor status stay correct")

        let cache = ComplicationSharedUserDefaultsModel(bgReadingValues: [110], bgReadingDatesAsDouble: [Date().timeIntervalSince1970],
            isMgDl: false, slopeOrdinal: 2, deltaValueInUserUnit: 0,
            urgentLowLimitInMgDl: 60, lowLimitInMgDl: 80, highLimitInMgDl: 170, urgentHighLimitInMgDl: 250, keepAliveIsDisabled: false)
        cacheDefaults.set(try JSONEncoder().encode(cache), forKey: "complicationSharedUserDefaults.test")
        let restarted = WatchStateModel()
        restarted.restoreDirectLibrePreferences()
        restarted.applyLibreReadings(.init(values: [115], dates: [Date().timeIntervalSince1970], slope: 2, delta: 0, generatedAt: Date()))
        precondition(restarted.publishedLimits == expected && !restarted.isMgDl)
        print("PASS: saved phone limits beat the old complication cache and reach the first direct complication update after restart")

        payload["generatedAt"] = Date().addingTimeInterval(-7200).timeIntervalSince1970
        payload["highLimitInMgDl"] = 170.0
        precondition(!restarted.receiveDirectLibrePreferences(payload) && restarted.highLimitInMgDl == 190)
        precondition(!restarted.receiveDirectLibrePreferences([:]))
        print("PASS: old and empty phone status cannot reset direct display limits")

        testDefaults.removePersistentDomain(forName: suite)
        let migrated = WatchStateModel()
        migrated.restoreDirectLibrePreferences()
        precondition(migrated.lowLimitInMgDl == 80 && migrated.highLimitInMgDl == 170 && !migrated.isMgDl)
        precondition(Libre2WatchPreferences(defaults: testDefaults).restoreLimits()?.high == 170)
        let relay = WatchStateModel()
        relay.directLibre.isDirect = false
        payload["generatedAt"] = Date().timeIntervalSince1970
        payload["highLimitInMgDl"] = 190.0
        precondition(!relay.receiveDirectLibrePreferences(payload))
        precondition(relay.highLimitInMgDl == 170)
        precondition(Libre2WatchPreferences(defaults: testDefaults).restoreLimits() == expected)
        print("PASS: existing cache migrates; relay persists limits and retains the host's original status assignments")
    }
}
'''
with test_directory('direct-libre-preferences-') as work:
    main = work / 'PreferencesProbe.swift'
    main.write_text(code)
    binary = work / 'preferences-tests'
    sources = [addon / 'Shared/Managers/Libre2WatchPreferences.swift',
               addon / 'Shared/DataModels/Libre2LocationRequest.swift',
               addon / 'Shared/Constants/ConstantsLibre2.swift',
               addon / 'Shared/Managers/Libre2ReadingPipeline.swift',
               repo / 'xDrip Watch Complication/DataModels/ComplicationSharedUserDefaultsModel.swift']
    run_swift(binary, [
        *map(str, sources),
        main,
    ], flags=['-swift-version', '5'])

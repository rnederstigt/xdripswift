import Foundation
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
/* @source:adapter */
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

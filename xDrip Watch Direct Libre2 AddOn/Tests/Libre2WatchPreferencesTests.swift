import XCTest

@testable import Libre2ExperimentCore

final class Libre2WatchPreferencesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        suite = "Libre2WatchPreferencesTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testFreshInstallationKeepsDefaultUntilPhoneProvidesUnits() {
        let preferences = Libre2WatchPreferences(defaults: defaults)
        XCTAssertTrue(preferences.restoreUnits())
        XCTAssertEqual(preferences.receiveUnits(["generatedAt": now.timeIntervalSince1970, "isMgDl": false], now: now), false)
        XCTAssertFalse(preferences.restoreUnits())
    }

    func testBothUnitChoicesSurviveRecreatingPreferences() throws {
        for units in [false, true, false] {
            let preferences = Libre2WatchPreferences(defaults: defaults)
            _ = preferences.receiveUnits(["generatedAt": now.timeIntervalSince1970, "isMgDl": units], now: now)
            let restored = Libre2WatchPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
            XCTAssertEqual(restored.restoreUnits(), units)
        }
    }

    func testComplicationCacheMigratesOnceAndCannotOverrideLaterPhoneChoice() {
        let preferences = Libre2WatchPreferences(defaults: defaults)
        XCTAssertFalse(preferences.restoreUnits(cachedUnit: false))
        XCTAssertFalse(preferences.restoreUnits(cachedUnit: true))
        _ = preferences.receiveUnits(["generatedAt": now.timeIntervalSince1970, "isMgDl": true], now: now)
        XCTAssertTrue(preferences.restoreUnits(cachedUnit: false))
    }

    func testMissingMalformedAndStaleStatusCannotResetMmol() {
        let preferences = Libre2WatchPreferences(defaults: defaults)
        _ = preferences.restoreUnits(cachedUnit: false)
        let rejected: [[String: Any]] = [
            [:],
            ["generatedAt": now.timeIntervalSince1970],
            ["generatedAt": now.timeIntervalSince1970, "isMgDl": "true"],
            ["isMgDl": true],
            ["generatedAt": now.addingTimeInterval(-3600).timeIntervalSince1970, "isMgDl": true],
            ["generatedAt": Double.nan, "isMgDl": true]
        ]
        for dictionary in rejected {
            XCTAssertNil(preferences.receiveUnits(dictionary, now: now))
            XCTAssertFalse(preferences.restoreUnits())
        }
    }
}

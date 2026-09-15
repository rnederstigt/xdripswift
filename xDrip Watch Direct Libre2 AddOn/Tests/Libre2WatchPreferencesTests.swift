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

    func testLocationIsOptInAndPersistsIndependentlyOfUnits() {
        let preferences = Libre2WatchPreferences(defaults: defaults)
        XCTAssertFalse(preferences.backgroundLocationEnabled)
        _ = preferences.restoreUnits(cachedUnit: false)
        preferences.backgroundLocationEnabled = true
        let restored = Libre2WatchPreferences(defaults: defaults)
        XCTAssertTrue(restored.backgroundLocationEnabled)
        XCTAssertFalse(restored.restoreUnits())
        restored.backgroundLocationEnabled = false
        XCTAssertFalse(preferences.backgroundLocationEnabled)
    }

    func testLocationRequestsRoundTripAndRejectMalformedMessages() throws {
        for request: Libre2LocationRequest in [.inspect, .setEnabled(true), .setEnabled(false)] {
            XCTAssertEqual(try Libre2LocationRequest.decode(request.dictionary), request)
        }
        for dictionary: [String: Any] in [[:], [Libre2LocationRequest.key: true],
                                          [Libre2LocationRequest.key: Data("{}".utf8)]] {
            XCTAssertThrowsError(try Libre2LocationRequest.decode(dictionary))
        }
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

    private var limits: Libre2WatchPreferences.GlucoseLimits {
        .init(urgentLow: 65, low: 75, high: 190, urgentHigh: 240)
    }

    private var limitsStatus: [String: Any] {
        ["generatedAt": now.timeIntervalSince1970, "urgentLowLimitInMgDl": limits.urgentLow,
         "lowLimitInMgDl": limits.low, "highLimitInMgDl": limits.high, "urgentHighLimitInMgDl": limits.urgentHigh]
    }

    func testAllLimitsSurviveRestartWithoutDependingOnUnitsOrLocation() throws {
        let preferences = Libre2WatchPreferences(defaults: defaults)
        XCTAssertNil(preferences.restoreLimits())
        _ = preferences.restoreUnits(cachedUnit: false)
        preferences.backgroundLocationEnabled = true
        XCTAssertEqual(preferences.receiveLimits(limitsStatus, now: now), limits)
        let restored = Libre2WatchPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(restored.restoreLimits(), limits)
        XCTAssertFalse(restored.restoreUnits())
        XCTAssertTrue(restored.backgroundLocationEnabled)
        _ = restored.receiveUnits(["generatedAt": now.timeIntervalSince1970, "isMgDl": true], now: now)
        XCTAssertEqual(restored.restoreLimits(), limits)
    }

    func testCachedLimitsMigrateUntilExplicitPhoneLimitsAreReceived() {
        let preferences = Libre2WatchPreferences(defaults: defaults)
        let cached = Libre2WatchPreferences.GlucoseLimits(urgentLow: 60, low: 80, high: 170, urgentHigh: 250)
        XCTAssertEqual(preferences.restoreLimits(cachedLimits: cached), cached)
        XCTAssertEqual(preferences.receiveLimits(limitsStatus, now: now), limits)
        XCTAssertEqual(Libre2WatchPreferences(defaults: defaults).restoreLimits(cachedLimits: cached), limits)
    }

    func testPartialInvalidOrStaleLimitsCannotOverwriteSavedLimits() {
        let preferences = Libre2WatchPreferences(defaults: defaults)
        _ = preferences.receiveLimits(limitsStatus, now: now)
        for key in ["urgentLowLimitInMgDl", "lowLimitInMgDl", "highLimitInMgDl", "urgentHighLimitInMgDl"] {
            for value: Any? in [nil, "75", Double.nan, Double.infinity, -1.0, 0.0] {
                var malformed = limitsStatus
                malformed[key] = value
                XCTAssertNil(preferences.receiveLimits(malformed, now: now))
                XCTAssertEqual(preferences.restoreLimits(), limits)
            }
        }
        for date: Any? in [nil, "now", Double.nan, now.addingTimeInterval(-3600).timeIntervalSince1970] {
            var stale = limitsStatus
            stale["generatedAt"] = date
            XCTAssertNil(preferences.receiveLimits(stale, now: now))
            XCTAssertEqual(preferences.restoreLimits(), limits)
        }
    }

    func testInvalidCacheDoesNotReplaceStartupDefaultsOrPreventLaterSync() {
        let preferences = Libre2WatchPreferences(defaults: defaults)
        let invalid = Libre2WatchPreferences.GlucoseLimits(urgentLow: .nan, low: 0, high: 170, urgentHigh: 250)
        XCTAssertNil(preferences.restoreLimits(cachedLimits: invalid))
        XCTAssertEqual(preferences.receiveLimits(limitsStatus, now: now), limits)
        XCTAssertEqual(preferences.restoreLimits(), limits)
    }

}

import XCTest
@testable import Libre2ExperimentCore

final class Libre2ComplicationDiagnosticsTests: XCTestCase {
    private func withDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
        let suite = "Libre2ComplicationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(defaults)
    }

    func testLoggingIsDormantUntilEnabledAndNeverChangesTheGlucoseCache() {
        withDefaults { defaults in
            let cache = Data("unchanged glucose cache".utf8)
            defaults.set(cache, forKey: "complicationSharedUserDefaults.test")
            let log = Libre2ComplicationDiagnostics(defaults: defaults, namespace: "test")
            log.record("snapshot", value: 131, sampleDate: Date(), displayValue: "7.3")
            XCTAssertTrue(log.entries.isEmpty)
            log.setEnabled(true)
            log.record("timeline", value: 131, sampleDate: Date(), displayValue: "7.3")
            XCTAssertEqual(log.entries.count, 1)
            log.setEnabled(false)
            log.record("timeline", value: 167, sampleDate: Date(), displayValue: "9.3")
            XCTAssertEqual(log.entries.count, 1)
            XCTAssertEqual(defaults.data(forKey: "complicationSharedUserDefaults.test"), cache)
        }
    }

    func testComplicationJournalSurvivesRestartAndIsBoundedAndNamespaced() {
        withDefaults { defaults in
            let writer = Libre2ComplicationDiagnostics(defaults: defaults, namespace: "test")
            writer.setEnabled(true)
            for index in 0..<(Libre2ComplicationDiagnostics.maximumEntries + 5) {
                writer.record("timeline \(index)", value: 131, sampleDate: Date(), displayValue: "7.3")
            }
            let reader = Libre2ComplicationDiagnostics(defaults: defaults, namespace: "test")
            XCTAssertEqual(reader.entries.count, Libre2ComplicationDiagnostics.maximumEntries)
            XCTAssertTrue(reader.entries.first!.message.contains("timeline 5"))
            XCTAssertEqual(reader.entries.map(\.id), writer.entries.map(\.id))
            let other = Libre2ComplicationDiagnostics(defaults: defaults, namespace: "another-app")
            other.record("timeline", value: 90, sampleDate: Date(), displayValue: "5.0")
            XCTAssertTrue(other.entries.isEmpty)
        }
    }

    func testProviderCallbacksCanRecordConcurrentlyWithoutLosingEntries() {
        withDefaults { defaults in
            let log = Libre2ComplicationDiagnostics(defaults: defaults, namespace: "test")
            log.setEnabled(true)
            DispatchQueue.concurrentPerform(iterations: 30) { index in
                log.record("timeline \(index)", value: Double(index), sampleDate: Date(), displayValue: "test")
            }
            XCTAssertEqual(log.entries.count, 30)
            XCTAssertEqual(Set(log.entries.map(\.id)).count, 30)
        }
    }

    func testTraceSeparatesMeasurementTimeValueAndPresentation() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let message = Libre2ComplicationDiagnostics.message("timeline", value: 131.4,
            sampleDate: date, displayValue: "7.3", details: "preview=false")
        XCTAssertTrue(message.contains("sample=2027-01-15T08:00:00.000Z"))
        XCTAssertTrue(message.contains("mgdL=131.4 display=7.3"))
        XCTAssertTrue(message.contains("preview=false"))
        let absent = Libre2ComplicationDiagnostics.message("snapshot", value: nil,
            sampleDate: nil, displayValue: "-.-")
        XCTAssertTrue(absent.contains("sample=none mgdL=none display=-.-"))
    }

    func testExportMergesComplicationEntriesReadOnlyWithinExistingLimits() throws {
        try withDefaults { defaults in
            let activity = Libre2ActivityLog(defaults: defaults)
            let now = Date()
            for index in 0..<Libre2ActivityLog.maximumEntries {
                activity.record("Activity \(index)", now: now.addingTimeInterval(Double(index)))
            }
            let extra = Libre2ActivityLog.Entry(id: UUID(), date: now.addingTimeInterval(500), message: "Complication: timeline")
            let before = defaults.dictionaryRepresentation()
            var reply: [String: Any] = [:]
            XCTAssertTrue(activity.receive([Libre2ActivityLog.requestKey: true], additionalEntries: [extra]) { reply = $0 })
            let exported = try Libre2ActivityLog.decodeSnapshot(reply)
            XCTAssertEqual(exported.count, Libre2ActivityLog.maximumEntries)
            XCTAssertEqual(exported.last?.id, extra.id)
            XCTAssertEqual(exported.first?.message, "Activity 1")
            XCTAssertEqual(NSDictionary(dictionary: defaults.dictionaryRepresentation()), NSDictionary(dictionary: before))
        }
    }
}

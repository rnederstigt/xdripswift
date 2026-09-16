import XCTest
@testable import Libre2ExperimentCore

final class Libre2LifecycleDiagnosticsTests: XCTestCase {
    func testTracingPreservesEntryTimestampAndIdentifiesTheProcess() throws {
        let suite = "Libre2LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = Libre2ActivityLog(defaults: defaults)
        let entered = Date().addingTimeInterval(-2)
        let event = Libre2LifecycleDiagnostics.Event("Watch notification received", date: entered,
            uptime: ProcessInfo.processInfo.systemUptime - 2)
        Libre2LifecycleDiagnostics.record(event, details: "missedReading=true", log: log)
        XCTAssertTrue(log.entries.isEmpty)
        log.isTracingEnabled = true
        Libre2LifecycleDiagnostics.record(event, details: "missedReading=true", log: log)
        let record = try XCTUnwrap(log.entries.last)
        XCTAssertEqual(record.date, entered)
        XCTAssertTrue(record.message.contains("process=\(Libre2LifecycleDiagnostics.processID)"))
        XCTAssertTrue(record.message.contains("logWaitMs="))
        XCTAssertTrue(record.message.contains("missedReading=true"))
        Libre2LifecycleDiagnostics.record(.init("WC reachability changed"), details: "reachable=true", log: log)
        XCTAssertTrue(try XCTUnwrap(log.entries.last).message.contains("process=\(Libre2LifecycleDiagnostics.processID)"))
    }

    func testDetailedTracingStillStaysDormantOutsideTheExperiment() throws {
        let suite = "Libre2LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = Libre2ActivityLog(defaults: defaults, shouldRecord: { false })
        log.isTracingEnabled = true
        Libre2LifecycleDiagnostics.record(.init("App entered background"), details: "", log: log)
        XCTAssertTrue(log.entries.isEmpty)
    }
}

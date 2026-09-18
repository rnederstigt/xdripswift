import XCTest
@testable import Libre2ExperimentCore

final class Libre2DiagnosticCaptureTests: XCTestCase {
    private var directory: URL!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var capture: Libre2DiagnosticCapture!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        capture = makeCapture()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    private func makeCapture() -> Libre2DiagnosticCapture {
        Libre2DiagnosticCapture(directory: directory, clock: { self.now }, uptime: { 123.5 })
    }
    private func export(_ capture: Libre2DiagnosticCapture) throws -> String {
        let status = try XCTUnwrap(capture.status)
        var download = Libre2DiagnosticCapture.Download(status: status)
        repeat {
            let offset = download.data.count
            try download.append(["captureID": status.id.uuidString, "offset": offset,
                                 "data": capture.chunk(id: status.id, offset: offset)])
        } while !download.isComplete
        return try Libre2DiagnosticCapture.report(status: status, data: download.data)
    }

    func testDisabledCaptureDoesNotEvaluateDetailsOrCreateFiles() {
        var called = false
        func detail() -> String { called = true; return "event" }
        capture.record(detail())
        XCTAssertFalse(called)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testNinetyMinuteCaptureSurvivesRelaunchAndExportsEveryChunk() throws {
        let id = UUID()
        try capture.start(id: id)
        for minute in 0..<90 {
            now = now.addingTimeInterval(60)
            for event in 0..<12 { capture.record("minute=\(minute) event=\(event)") }
            if minute == 45 { capture = makeCapture(); capture.record("Relaunched") }
        }
        try capture.stop(id: id)
        XCTAssertGreaterThan(capture.status!.bytes, Libre2DiagnosticCapture.chunkBytes)
        let report = try export(capture)
        XCTAssertTrue(report.contains("minute=0 event=0"))
        XCTAssertTrue(report.contains("minute=89 event=11"))
        XCTAssertTrue(report.contains("Relaunched"))
        XCTAssertEqual(capture.status!.events, 1083)
        XCTAssertTrue(report.contains("run="))
        XCTAssertTrue(report.contains("uptime=123.500"))
    }

    func testStartAndStopAreIdempotentButStaleIDsCannotAffectCapture() throws {
        let id = UUID()
        try capture.start(id: id)
        capture.record("Preserve me")
        let bytes = capture.status!.bytes
        try capture.start(id: id)
        XCTAssertEqual(capture.status!.bytes, bytes)
        XCTAssertThrowsError(try capture.start(id: UUID()))
        XCTAssertThrowsError(try capture.stop(id: UUID()))
        XCTAssertThrowsError(try capture.chunk(id: UUID(), offset: 0))
        XCTAssertThrowsError(try capture.chunk(id: id, offset: 0)) // still recording
        try capture.stop(id: id)
        let finalBytes = capture.status!.bytes
        try capture.stop(id: id)
        XCTAssertEqual(capture.status!.bytes, finalBytes)
        XCTAssertTrue(try export(capture).contains("Preserve me"))
    }

    func testExpirationOnNextEventDoesNotNeedATimerAndSurvivesRestart() throws {
        let id = UUID()
        try capture.start(id: id)
        now = now.addingTimeInterval(Libre2DiagnosticCapture.duration + 60)
        capture = makeCapture()
        capture.record("Too late")
        XCTAssertFalse(capture.status!.isRecording)
        XCTAssertTrue(capture.status!.reason!.contains("Two-hour"))
        XCTAssertFalse(try export(capture).contains("Too late"))
    }

    func testCapacityPreservesBeginningAndExplicitlyMarksTruncation() throws {
        try capture.start(id: UUID())
        for index in 0..<6_000 { capture.record("Event \(index)") }
        XCTAssertEqual(capture.status!.events, Libre2DiagnosticCapture.maximumEvents)
        XCTAssertLessThanOrEqual(capture.status!.bytes, Libre2DiagnosticCapture.maximumBytes)
        let report = try export(capture)
        XCTAssertTrue(report.contains("Event 0"))
        XCTAssertTrue(report.contains("capacity reached"))
        XCTAssertFalse(report.contains("Event 5999"))
    }

    func testByteLimitAlsoPreservesATerminalReason() throws {
        try capture.start(id: UUID())
        for _ in 0..<3_000 { capture.record(String(repeating: "x", count: 1_200)) }
        XCTAssertFalse(capture.status!.isRecording)
        XCTAssertLessThan(capture.status!.events, Libre2DiagnosticCapture.maximumEvents)
        XCTAssertLessThanOrEqual(capture.status!.bytes, Libre2DiagnosticCapture.maximumBytes)
        XCTAssertTrue(try export(capture).contains("capacity reached"))
    }

    func testWriteFailureIsReportedWithoutThrowingFromCollectorLogging() throws {
        let id = UUID()
        try capture.start(id: id)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".txt"))
        capture.record("Cannot append")
        XCTAssertNotNil(capture.status!.storageError)
        XCTAssertFalse(capture.status!.isRecording)
        XCTAssertThrowsError(try capture.chunk(id: id, offset: 0))
    }

    func testIncompleteAppendIsPreservedAndFlaggedOnRelaunch() throws {
        let id = UUID()
        try capture.start(id: id)
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent(id.uuidString + ".txt"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("partial".utf8))
        try handle.close()
        capture = makeCapture()
        XCTAssertNotNil(capture.status!.storageError)
        try capture.stop(id: id)
        XCTAssertTrue(try export(capture).contains("partial"))
    }

    func testChunkValidationRejectsWrongCaptureOffsetsAndMissingBytes() throws {
        let id = UUID()
        try capture.start(id: id)
        try capture.stop(id: id)
        let status = capture.status!
        let chunk = try capture.chunk(id: id, offset: 0)
        var download = Libre2DiagnosticCapture.Download(status: status)
        XCTAssertThrowsError(try download.append(["captureID": UUID().uuidString, "offset": 0, "data": chunk]))
        XCTAssertThrowsError(try download.append(["captureID": id.uuidString, "offset": 1, "data": chunk]))
        XCTAssertThrowsError(try download.append(["captureID": id.uuidString, "offset": 0, "data": Data()]))
        try download.append(["captureID": id.uuidString, "offset": 0, "data": chunk])
        XCTAssertTrue(download.isComplete)
        XCTAssertThrowsError(try download.append(["captureID": id.uuidString, "offset": 0, "data": chunk]))
        XCTAssertThrowsError(try capture.chunk(id: id, offset: -1))
        XCTAssertThrowsError(try capture.chunk(id: id, offset: status.bytes + 1))
    }

    func testNewCaptureInvalidatesOldExportAndRemovesOnlyOldCaptureFile() throws {
        let old = UUID(), new = UUID()
        try capture.start(id: old)
        try capture.stop(id: old)
        try capture.start(id: new)
        XCTAssertThrowsError(try capture.chunk(id: old, offset: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(old.uuidString + ".txt").path))
        capture = makeCapture()
        XCTAssertEqual(capture.status!.id, new)
        XCTAssertTrue(capture.status!.isRecording)
    }

    func testCorruptMetadataReportsWarningButAllowsExplicitNewCapture() throws {
        try capture.start(id: UUID())
        try Data("bad metadata".utf8).write(to: directory.appendingPathComponent("capture.json"))
        capture = makeCapture()
        var reply: [String: Any] = [:]
        capture.receive([Libre2DiagnosticCapture.commandKey: "status"]) { reply = $0 }
        XCTAssertNil(try Libre2DiagnosticCapture.decodeStatus(reply))
        XCTAssertNotNil(reply["captureWarning"])
        let id = UUID()
        try capture.start(id: id)
        XCTAssertEqual(capture.status!.id, id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }.count, 1)
    }

    func testCaptureCommandsUseExistingActivityRoute() throws {
        let previous = Libre2DiagnosticCapture.shared
        Libre2DiagnosticCapture.shared = capture
        defer { Libre2DiagnosticCapture.shared = previous }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let log = Libre2ActivityLog(defaults: defaults, shouldRecord: { false })
        let id = UUID()
        var reply: [String: Any] = [:]
        XCTAssertTrue(log.receive([Libre2ActivityLog.requestKey: true,
                                  Libre2DiagnosticCapture.commandKey: "start", "captureID": id.uuidString]) { reply = $0 })
        XCTAssertEqual(try Libre2DiagnosticCapture.decodeStatus(reply)?.id, id)
        log.record("Capture includes ownership events even if short activity log is dormant")
        try capture.stop(id: id)
        XCTAssertTrue(try export(capture).contains("ownership events"))
        XCTAssertTrue(log.entries.isEmpty)
    }
}

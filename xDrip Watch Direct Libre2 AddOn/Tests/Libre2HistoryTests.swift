import XCTest
@testable import Libre2ExperimentCore

final class Libre2HistoryTests: XCTestCase {
    private let sessionID = UUID()
    private let uid = Data([1, 2, 3, 4, 5, 6, 7, 8])
    private let now = Date().addingTimeInterval(-600)

    private func reading(_ minute: UInt16 = 100, session: UUID? = nil, glucose: Double = 120) -> Libre2HistoryReading {
        Libre2HistoryReading(sessionID: session ?? sessionID, sensorUID: uid, sensorMinute: minute,
                             date: now.addingTimeInterval(Double(Int(minute) - 100) * 60), glucose: glucose)
    }

    func testBatchRoundTripContainsConvertedValueWithoutDisplayClamping() throws {
        let batch = Libre2HistoryBatch(readings: [reading(glucose: 650)])
        XCTAssertEqual(try Libre2HistoryBatch.decode(batch.dictionary), batch)
        let data = try XCTUnwrap(batch.dictionary[Libre2HistoryBatch.key] as? Data)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("unlock"))
        XCTAssertFalse(text.contains("calibration"))
    }

    func testInvalidReadingsAndOversizedBatchesAreRejected() throws {
        for glucose in [0, -1, .nan, .infinity, ConstantsLibre2.maximumValidGlucose] {
            XCTAssertThrowsError(try reading(glucose: glucose).validate())
        }
        XCTAssertThrowsError(try Libre2HistoryBatch(readings: []).validate())
        XCTAssertThrowsError(try Libre2HistoryBatch(readings: (100...220).map { reading(UInt16($0)) }).validate())
        XCTAssertThrowsError(try Libre2HistoryBatch(readings: [reading(), reading()]).validate())
        XCTAssertThrowsError(try Libre2HistoryBatch.decode([Libre2HistoryBatch.key: Data(count: 100_001)]))
        let future = Libre2HistoryReading(sessionID: sessionID, sensorUID: uid, sensorMinute: 100,
                                         date: Date().addingTimeInterval(600), glucose: 100)
        XCTAssertThrowsError(try future.validate())
    }

    func testAppendFailureDoesNotAdvanceMinuteOrLoseRetry() throws {
        var fail = true
        let queue = Libre2HistoryQueue { _ in if fail { throw Libre2HistoryError.unavailable } }
        XCTAssertThrowsError(try queue.append(reading()))
        XCTAssertTrue(queue.state.pending.isEmpty)
        XCTAssertTrue(queue.state.lastCollectedMinute.isEmpty)
        fail = false
        try queue.append(reading())
        XCTAssertEqual(queue.state.pending.count, 1)
    }

    func testBatchIsPersistedBeforeItCanBeSent() throws {
        var disk = Libre2HistoryQueue.State()
        let queue = Libre2HistoryQueue { disk = $0 }
        try queue.append(reading())
        let batch = try XCTUnwrap(queue.nextBatch())
        XCTAssertEqual(disk.batch, batch)
        let restarted = Libre2HistoryQueue(state: disk) { disk = $0 }
        XCTAssertEqual(try restarted.nextBatch(), batch)
    }

    func testFailedBatchPersistenceDoesNotExposeAnUntrackedTransfer() throws {
        var fail = false
        let queue = Libre2HistoryQueue { _ in if fail { throw Libre2HistoryError.unavailable } }
        try queue.append(reading())
        fail = true
        XCTAssertThrowsError(try queue.nextBatch())
        XCTAssertNil(queue.state.batch)
        XCTAssertEqual(queue.state.pending.count, 1)
    }

    func testAcknowledgementOnlyRemovesItsImmutableBatch() throws {
        let queue = Libre2HistoryQueue { _ in }
        try queue.append(reading())
        let first = try XCTUnwrap(queue.nextBatch())
        try queue.append(reading(101))
        XCTAssertEqual(try queue.nextBatch(), first)
        try queue.acknowledge(Libre2HistoryAcknowledgement(batch: first))
        XCTAssertEqual(queue.state.pending, [reading(101)])
        let second = try XCTUnwrap(queue.nextBatch())
        XCTAssertThrowsError(try queue.acknowledge(Libre2HistoryAcknowledgement(batch: first)))
        XCTAssertEqual(try queue.nextBatch(), second)
    }

    func testAcknowledgementMustMatchBothBatchIDAndReadingIDs() throws {
        let queue = Libre2HistoryQueue { _ in }
        try queue.append(reading())
        let batch = try XCTUnwrap(queue.nextBatch())
        let malformed: [String: Any] = ["batchID": batch.id.uuidString, "readingIDs": ["unrelated"]]
        let ack = try JSONDecoder().decode(Libre2HistoryAcknowledgement.self,
                                           from: JSONSerialization.data(withJSONObject: malformed))
        XCTAssertThrowsError(try queue.acknowledge(ack))
        XCTAssertEqual(queue.state.pending.count, 1)
    }

    func testAcknowledgementSaveFailureKeepsReadingsForRetry() throws {
        var fail = false
        let queue = Libre2HistoryQueue { _ in if fail { throw Libre2HistoryError.unavailable } }
        try queue.append(reading())
        let batch = try XCTUnwrap(queue.nextBatch())
        fail = true
        XCTAssertThrowsError(try queue.acknowledge(Libre2HistoryAcknowledgement(batch: batch)))
        XCTAssertEqual(queue.state.batch, batch)
        XCTAssertEqual(queue.state.pending.count, 1)
    }

    func testSameSensorMinuteIsNotRecollectedAfterAcknowledgementOrHandoff() throws {
        var disk = Libre2HistoryQueue.State()
        let queue = Libre2HistoryQueue { disk = $0 }
        try queue.append(reading())
        try queue.acknowledge(Libre2HistoryAcknowledgement(batch: XCTUnwrap(queue.nextBatch())))
        let restarted = Libre2HistoryQueue(state: disk) { disk = $0 }
        try restarted.append(reading(session: UUID()))
        try restarted.append(reading(99))
        XCTAssertTrue(restarted.state.pending.isEmpty)
        try restarted.append(reading(101, session: UUID()))
        XCTAssertEqual(restarted.state.pending.count, 1)
    }

    func testLargeOfflineQueueDrainsInBoundedBatchesWithoutDroppingData() throws {
        let queue = Libre2HistoryQueue { _ in }
        let start = Date().addingTimeInterval(-30_000)
        for minute in 100..<401 {
            try queue.append(Libre2HistoryReading(sessionID: sessionID, sensorUID: uid, sensorMinute: UInt16(minute),
                date: start.addingTimeInterval(Double(minute) * 60), glucose: 100))
        }
        var counts: [Int] = []
        while let batch = try queue.nextBatch() {
            counts.append(batch.readings.count)
            try queue.acknowledge(Libre2HistoryAcknowledgement(batch: batch))
        }
        XCTAssertEqual(counts, [120, 120, 61])
    }

    func testFileRoundTripAndCorruptionNeverSilentlyClearsOutbox() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("queue.json")
        let queue = try Libre2HistoryQueue(url: url)
        try queue.append(reading())
        let batch = try queue.nextBatch()
        XCTAssertEqual(try Libre2HistoryQueue(url: url).nextBatch(), batch)
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try Libre2HistoryQueue(url: url))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testRegistryRetainsOriginalSensorAcrossReplacementAndRejectsUnknownSession() throws {
        let old = Libre2HistoryRegistry.Entry(sessionID: sessionID, sensorUID: uid,
                                              sensorID: "original-phone-sensor", preparedAt: now)
        let replacement = Libre2HistoryRegistry.Entry(sessionID: UUID(), sensorUID: Data(repeating: 9, count: 8),
                                                      sensorID: "replacement", preparedAt: Date())
        let registry = Libre2HistoryRegistry(entries: [old, replacement]) { _ in }
        XCTAssertEqual(try registry.sensorID(for: reading()), "original-phone-sensor")
        XCTAssertThrowsError(try registry.sensorID(for: reading(session: UUID())))
        let wrongUID = Libre2HistoryReading(sessionID: sessionID, sensorUID: replacement.sensorUID,
                                            sensorMinute: 100, date: now, glucose: 100)
        XCTAssertThrowsError(try registry.sensorID(for: wrongUID))
        XCTAssertThrowsError(try registry.sensorID(for: reading(90)))
    }
}

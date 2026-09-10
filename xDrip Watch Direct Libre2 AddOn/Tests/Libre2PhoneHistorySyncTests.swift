#if os(iOS)
import CoreData
import WatchConnectivity
import XCTest
@testable import xdrip

/// Hosted tests exercise the actual app model, parent-context saves and acknowledgement path.
@MainActor
final class Libre2PhoneHistorySyncTests: XCTestCase {
    private let uid = Data([1, 2, 3, 4, 5, 6, 7, 8])

    private func fixture() async throws -> (CoreDataManager, Sensor, Libre2HistoryRegistry, Libre2HistoryReading) {
        let manager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sensor = Sensor(startDate: Date().addingTimeInterval(-3600), nsManagedObjectContext: manager.mainManagedObjectContext)
        let sample = Libre2HistoryReading(sessionID: UUID(), sensorUID: uid, sensorMinute: 100,
                                          date: Date().addingTimeInterval(-600), glucose: 650)
        let registry = Libre2HistoryRegistry(entries: [
            .init(sessionID: sample.sessionID, sensorUID: uid, sensorID: sensor.id,
                  preparedAt: sample.date.addingTimeInterval(-60))
        ]) { _ in }
        try manager.mainManagedObjectContext.save()
        let store = manager.privateManagedObjectContext
        try await store.perform { try store.save() }
        return (manager, sensor, registry, sample)
    }

    private func send(_ batch: Libre2HistoryBatch, to sync: Libre2PhoneHistorySync) async throws -> [String: Any] {
        let message = try batch.dictionary
        return await withCheckedContinuation { continuation in
            XCTAssertTrue(sync.receive(message) { continuation.resume(returning: $0) })
        }
    }

    private struct SavedReading {
        let id: String
        let calculatedValue: Double
        let sensorID: String?
        let backfilledAt: Date?
        let calibrationID: NSManagedObjectID?
    }

    private func diskReadings(_ manager: CoreDataManager) throws -> [SavedReading] {
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = manager.privateManagedObjectContext.persistentStoreCoordinator
        return try context.fetch(BgReading.fetchRequest()).map {
            SavedReading(id: $0.id, calculatedValue: $0.calculatedValue, sensorID: $0.sensor?.id,
                         backfilledAt: $0.backfilledAt, calibrationID: $0.calibration?.objectID)
        }
    }

    func testDuplicateBatchIsAcknowledgedOnlyAfterValuesReachPersistentStore() async throws {
        let (manager, _, registry, sample) = try await fixture()
        let sync = Libre2PhoneHistorySync(coreDataManager: manager, session: .default, registry: registry)
        let batch = Libre2HistoryBatch(readings: [sample])
        for _ in 0..<2 {
            let reply = try await send(batch, to: sync)
            XCTAssertEqual(try Libre2HistoryAcknowledgement.decode(reply).batchID, batch.id)
            let readings = try diskReadings(manager)
            XCTAssertEqual(readings.count, 1)
            XCTAssertEqual(readings.first?.calculatedValue, 650)
            XCTAssertEqual(readings.first?.id, sample.id)
            XCTAssertNotNil(readings.first?.backfilledAt)
            XCTAssertNil(readings.first?.calibrationID)
        }
    }

    func testFinalSaveFailureWithholdsAcknowledgementAndDuplicateRetryStillSaves() async throws {
        let (manager, _, registry, sample) = try await fixture()
        let failing = Libre2PhoneHistorySync(coreDataManager: manager, session: .default, registry: registry,
            beforeStoreSave: { throw Libre2HistoryError.unavailable })
        let batch = Libre2HistoryBatch(readings: [sample])
        let failedReply = try await send(batch, to: failing)
        XCTAssertNil(failedReply[Libre2HistoryAcknowledgement.key])
        XCTAssertNotNil(failedReply["error"])
        XCTAssertTrue(try diskReadings(manager).isEmpty)

        let retry = Libre2PhoneHistorySync(coreDataManager: manager, session: .default, registry: registry)
        let reply = try await send(batch, to: retry)
        XCTAssertEqual(try Libre2HistoryAcknowledgement.decode(reply).batchID, batch.id)
        XCTAssertEqual(try diskReadings(manager).count, 1)
    }

    func testDelayedReadingsRemainAttachedToOriginalEndedSensor() async throws {
        let (manager, original, registry, sample) = try await fixture()
        original.endDate = Date().addingTimeInterval(-300)
        _ = Sensor(startDate: Date().addingTimeInterval(-240), nsManagedObjectContext: manager.mainManagedObjectContext)
        let sync = Libre2PhoneHistorySync(coreDataManager: manager, session: .default, registry: registry)
        _ = try await send(Libre2HistoryBatch(readings: [sample]), to: sync)
        XCTAssertEqual(try diskReadings(manager).first?.sensorID, original.id)
    }

    func testUnknownSessionDoesNotImportOrAcknowledge() async throws {
        let (manager, _, _, sample) = try await fixture()
        let sync = Libre2PhoneHistorySync(coreDataManager: manager, session: .default,
                                         registry: Libre2HistoryRegistry { _ in })
        let reply = try await send(Libre2HistoryBatch(readings: [sample]), to: sync)
        XCTAssertNil(reply[Libre2HistoryAcknowledgement.key])
        XCTAssertTrue(try diskReadings(manager).isEmpty)
    }

    func testPhoneOverlapIsPreservedButDistinctWatchMinutesAreNotSuppressed() async throws {
        let (manager, sensor, registry, sample) = try await fixture()
        let phone = BgReading(timeStamp: sample.date, sensor: sensor, calibration: nil, rawData: 120,
                              deviceName: "Libre 2", nsManagedObjectContext: manager.mainManagedObjectContext)
        phone.calculatedValue = 120
        try manager.mainManagedObjectContext.save()
        let second = Libre2HistoryReading(sessionID: sample.sessionID, sensorUID: uid, sensorMinute: 101,
                                          date: sample.date.addingTimeInterval(60), glucose: 125)
        let third = Libre2HistoryReading(sessionID: sample.sessionID, sensorUID: uid, sensorMinute: 102,
                                         date: sample.date.addingTimeInterval(80), glucose: 126)
        let sync = Libre2PhoneHistorySync(coreDataManager: manager, session: .default, registry: registry)
        let batch = Libre2HistoryBatch(readings: [sample, second, third])
        _ = try await send(batch, to: sync)
        let readings = try diskReadings(manager)
        XCTAssertEqual(readings.count, 3)
        XCTAssertEqual(readings.first(where: { $0.id == phone.id })?.calculatedValue, 120)
        XCTAssertNil(readings.first(where: { $0.id == sample.id }))
        XCTAssertNotNil(readings.first(where: { $0.id == second.id }))
        XCTAssertNotNil(readings.first(where: { $0.id == third.id }))
    }
}
#endif

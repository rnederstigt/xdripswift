import CoreData
import Foundation
import WatchConnectivity

/// The host injects its existing database and WCSession. All scheduling and registry access
/// run on main; Core Data work uses the context queues. Imports never grant BLE authority.
final class Libre2PhoneHistorySync {
    static let didImport = Notification.Name("Libre2PhoneHistoryDidImport")

    private let coreDataManager: CoreDataManager
    private let session: WCSession
    private var registry: Libre2HistoryRegistry?
    private var pending: [(Libre2HistoryBatch, (([String: Any]) -> Void)?)] = []
    private var isImporting = false
    private let beforeStoreSave: (@Sendable () throws -> Void)?

    init(coreDataManager: CoreDataManager, session: WCSession, registry: Libre2HistoryRegistry? = nil,
         beforeStoreSave: (@Sendable () throws -> Void)? = nil) {
        self.coreDataManager = coreDataManager
        self.session = session
        self.registry = registry
        self.beforeStoreSave = beforeStoreSave
    }

    /// Register before PREPARE is sent. Saving the sensor itself precedes writing the mapping,
    /// so an app restart cannot leave Watch readings pointing at an unsaved phone sensor.
    func register(_ watchSession: Libre2WatchSession, completion: @escaping (Result<Void, Error>) -> Void) {
        Task { @MainActor in
            do {
                try await register(watchSession)
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    @discardableResult
    func receive(_ dictionary: [String: Any], reply: (([String: Any]) -> Void)? = nil) -> Bool {
        guard dictionary[Libre2HistoryBatch.key] != nil else { return false }
        do {
            let batch = try Libre2HistoryBatch.decode(dictionary)
            pending.append((batch, reply))
            importNext()
        } catch {
            report(error)
            reply?(["error": error.localizedDescription])
        }
        return true
    }

    private func importNext() {
        guard !isImporting, !pending.isEmpty else { return }
        isImporting = true
        let (batch, reply) = pending.removeFirst()
        Task { @MainActor in
            defer {
                isImporting = false
                importNext()
            }
            do {
                let count = try await importReadings(batch)
                let acknowledgement = try Libre2HistoryAcknowledgement(batch: batch).dictionary
                if let reply {
                    reply(acknowledgement)
                } else if session.activationState == .activated {
                    session.transferUserInfo(acknowledgement)
                }
                Libre2ActivityLog.shared.record("Saved \(count) Direct Watch readings on iPhone.")
                // Also refresh after a duplicate: an earlier attempt may have saved into the
                // parent context and then failed at the final persistent-store save.
                NotificationCenter.default.post(name: Self.didImport, object: self)
            } catch {
                report(error)
                reply?(["error": error.localizedDescription])
                // No success acknowledgement. The Watch retains and retries the batch.
            }
        }
    }

    @MainActor
    private func register(_ watchSession: Libre2WatchSession) async throws {
        let registry = try sensorRegistry()
        if let saved = registry.entries.first(where: { $0.sessionID == watchSession.id }) {
            guard saved.sensorUID == watchSession.sensorUID, saved.preparedAt == watchSession.createdAt else {
                throw Libre2HistoryError.unknownSensor
            }
            return
        }
        guard UserDefaults.standard.libreSensorUID == watchSession.sensorUID,
            let sensor = SensorsAccessor(coreDataManager: coreDataManager).fetchActiveSensor(),
            sensor.startDate <= watchSession.createdAt
        else { throw Libre2HistoryError.unknownSensor }
        let sensorID = sensor.id
        try await saveToPersistentStore()
        try registry.register(watchSession, sensorID: sensorID)
    }

    @MainActor
    private func importReadings(_ batch: Libre2HistoryBatch) async throws -> Int {
        let registry = try sensorRegistry()
        // Upgrade an already active prototype session only when its saved identity still
        // matches the phone's sensor. Unknown completed sessions are never guessed.
        if let current = Libre2SessionStore.shared.snapshot.session,
            batch.readings.contains(where: { $0.sessionID == current.id }),
            !registry.entries.contains(where: { $0.sessionID == current.id }) {
            try await register(current)
        }
        let sensorIDs = try batch.readings.map { try registry.sensorID(for: $0) }
        let context = coreDataManager.privateChildManagedObjectContext()
        let count = try await context.perform {
            // Resolve the entire batch before inserting any rows.
            var sensors: [String: Sensor] = [:]
            for id in Set(sensorIDs) {
                let request = Sensor.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", id)
                request.fetchLimit = 1
                guard let sensor = try context.fetch(request).first else { throw Libre2HistoryError.unknownSensor }
                sensors[id] = sensor
            }
            var inserted = 0
            for (sample, sensorID) in zip(batch.readings, sensorIDs) {
                let request = BgReading.fetchRequest()
                // Deterministic IDs cover repeated/cross-handoff Watch samples. At a switch
                // boundary prefer an existing phone reading within half a minute.
                request.predicate = NSPredicate(
                    format: "id == %@ OR (sensor.id == %@ AND timeStamp > %@ AND timeStamp < %@ AND calculatedValue > 0 AND NOT (id BEGINSWITH 'direct-libre-watch:'))",
                    sample.id, sensorID, sample.date.addingTimeInterval(-30) as NSDate,
                    sample.date.addingTimeInterval(30) as NSDate)
                request.fetchLimit = 1
                guard try context.fetch(request).isEmpty else { continue }
                let reading = BgReading(timeStamp: sample.date, sensor: sensors[sensorID], calibration: nil,
                    rawData: sample.glucose, deviceName: "Libre 2 Watch", nsManagedObjectContext: context)
                reading.id = sample.id
                reading.calculatedValue = sample.glucose
                reading.ageAdjustedRawValue = sample.glucose
                reading.hideSlope = true
                reading.backfilledAt = Date()
                inserted += 1
            }
            if context.hasChanges { try context.save() }
            return inserted
        }
        // Saving the child/main contexts alone is not durable. Always attempt the final save,
        // even for a duplicate batch after an earlier disk-save failure.
        try await saveToPersistentStore()
        return count
    }

    private func saveToPersistentStore() async throws {
        let main = coreDataManager.mainManagedObjectContext
        try await main.perform { if main.hasChanges { try main.save() } }
        let store = coreDataManager.privateManagedObjectContext
        let beforeStoreSave = self.beforeStoreSave
        try await store.perform {
            try beforeStoreSave?()
            if store.hasChanges { try store.save() }
        }
    }

    private func sensorRegistry() throws -> Libre2HistoryRegistry {
        if let registry { return registry }
        let loaded = try Libre2HistoryRegistry()
        registry = loaded
        return loaded
    }

    private func report(_ error: Error) {
        Libre2ActivityLog.shared.record("History sync: \(error.localizedDescription)")
    }
}

import Foundation

/// Main-queue Watch outbox. Keep unacknowledged readings across return, reclaim and restart.
/// Only the newest actual measurement from each BLE frame is collected; interpolated graph
/// points are deliberately excluded. This is not a sensor-history/backfill implementation.
final class Libre2HistoryQueue {
    struct State: Codable, Equatable {
        var pending: [Libre2HistoryReading] = []
        var batch: Libre2HistoryBatch?
        var lastCollectedMinute: [String: UInt16] = [:]
        var unresolved: [Libre2HistoryReading] = []

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            pending = try values.decode([Libre2HistoryReading].self, forKey: .pending)
            batch = try values.decodeIfPresent(Libre2HistoryBatch.self, forKey: .batch)
            lastCollectedMinute = try values.decode([String: UInt16].self, forKey: .lastCollectedMinute)
            // Existing installations have no unresolved collection; keep their pending batch intact.
            unresolved = try values.decodeIfPresent([Libre2HistoryReading].self, forKey: .unresolved) ?? []
        }
    }

    private(set) var state: State
    private let persist: (State) throws -> Void
    private var unresolvedRevision = UUID()

    var unresolvedReadings: Libre2UnresolvedReadings {
        Libre2UnresolvedReadings(id: unresolvedRevision, count: state.unresolved.count)
    }

    init(state: State = State(), persist: @escaping (State) throws -> Void) {
        self.state = state
        self.persist = persist
    }

    convenience init(url: URL = Libre2HistoryFile.url("watch-history.json")) throws {
        let state = try Libre2HistoryFile.load(State.self, from: url, fallback: State())
        self.init(state: state) { try Libre2HistoryFile.save($0, to: url) }
    }

    func append(_ reading: Libre2HistoryReading) throws {
        try reading.validate()
        if let minute = state.lastCollectedMinute[reading.sensorKey], minute >= reading.sensorMinute { return }
        var next = state
        next.pending.append(reading)
        next.lastCollectedMinute[reading.sensorKey] = reading.sensorMinute
        try save(next)
    }

    /// The batch is immutable once sent: a late acknowledgement cannot delete newer readings.
    func nextBatch() throws -> Libre2HistoryBatch? {
        if let batch = state.batch { return batch }
        guard !state.pending.isEmpty else { return nil }
        var next = state
        next.batch = Libre2HistoryBatch(readings: Array(next.pending.prefix(Libre2HistoryBatch.maximumReadings)))
        try save(next)
        return next.batch
    }

    func acknowledge(_ acknowledgement: Libre2HistoryAcknowledgement) throws {
        guard let batch = state.batch, acknowledgement.batchID == batch.id,
            acknowledgement.readingIDs == batch.readings.map(\.id)
        else { throw Libre2HistoryError.staleAcknowledgement }
        var next = state
        let savedIDs = Set(acknowledgement.readingIDs)
        next.pending.removeAll { savedIDs.contains($0.id) }
        next.batch = nil
        try save(next)
    }

    /// Persist rejected readings before releasing the batch. No measurements are deleted or
    /// reassigned to a different sensor. Late replies cannot affect a subsequent batch.
    func retainUnresolved(_ rejection: Libre2HistoryRejection) throws {
        let rejectedIDs = Set(rejection.readingIDs)
        guard let batch = state.batch, rejection.batchID == batch.id,
            !rejectedIDs.isEmpty, rejectedIDs.count == rejection.readingIDs.count,
            rejectedIDs.isSubset(of: Set(batch.readings.map(\.id)))
        else { throw Libre2HistoryError.staleAcknowledgement }
        var next = state
        next.unresolved.append(contentsOf: next.pending.filter { rejectedIDs.contains($0.id) })
        next.pending.removeAll { rejectedIDs.contains($0.id) }
        next.batch = nil
        try save(next)
        unresolvedRevision = UUID()
    }

    /// Require the count the user confirmed. A restart, new rejection or prior deletion
    /// invalidates that confirmation. Pending uploads and collection deduplication stay intact.
    func deleteUnresolved(_ confirmed: Libre2UnresolvedReadings) throws {
        guard confirmed == unresolvedReadings else { throw Libre2HistoryError.staleCleanup }
        var next = state
        next.unresolved.removeAll()
        try save(next)
        unresolvedRevision = UUID()
    }

    private func save(_ next: State) throws {
        try persist(next)
        state = next
    }
}

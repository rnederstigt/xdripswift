import Foundation

/// Main-queue Watch outbox. Keep unacknowledged readings across return, reclaim and restart.
/// Only the newest actual measurement from each BLE frame is collected; interpolated graph
/// points are deliberately excluded. This is not a sensor-history/backfill implementation.
final class Libre2HistoryQueue {
    struct State: Codable, Equatable {
        var pending: [Libre2HistoryReading] = []
        var batch: Libre2HistoryBatch?
        var lastCollectedMinute: [String: UInt16] = [:]
    }

    private(set) var state: State
    private let persist: (State) throws -> Void

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

    private func save(_ next: State) throws {
        try persist(next)
        state = next
    }
}

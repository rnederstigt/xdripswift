
    private func register(_ session: Libre2WatchSession) async throws {}
    @MainActor private func importReadings(_ batch: Libre2HistoryBatch) async throws -> ImportResult {
        if coreDataManager.pauseNextSave {
            coreDataManager.pauseNextSave = false
            await withCheckedContinuation { coreDataManager.resumeSave = $0 }
        }
        if coreDataManager.rejectNextSave {
            coreDataManager.rejectNextSave = false
            throw Libre2HistoryRejection(batchID: batch.id, readingIDs: batch.readings.map(\.id))
        }
        if coreDataManager.failNextSave {
            coreDataManager.failNextSave = false
            throw Libre2HistoryError.unavailable
        }
        coreDataManager.saved.append(batch)
        return ImportResult(inserted: batch.readings.count, changedSensorIDs: ["sensor"])
    }
    private func currentReadingDate(in batch: Libre2HistoryBatch) -> Date? {
        let latest = coreDataManager.saved.flatMap(\.readings).max { $0.date < $1.date }
        return latest.flatMap { batch.readings.contains($0) ? $0.date : nil }
    }
    private func report(_ error: Error) {}
}

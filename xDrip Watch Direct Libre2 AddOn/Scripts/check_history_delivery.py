#!/usr/bin/env python3
"""Run the production Watch history coordinator with explicit WatchConnectivity events.

Only platform imports are removed. The real journal/response models are used with
an injected in-memory writer; no application data or repository files are changed.
"""
from pathlib import Path
from swift_test_runner import run_swift, test_directory

addon = Path(__file__).resolve().parents[1]
with test_directory("direct-libre-history-") as work:
    source = work / "Libre2WatchHistorySync.swift"
    source.write_text((addon / "Watch/Managers/Libre2WatchHistorySync.swift").read_text()
                      .replace("import WatchConnectivity\n", "").replace("import WatchKit\n", ""))
    executable = work / "history-tests"
    run_swift(executable, [
        *[str(addon / path) for path in [
            "Shared/Constants/ConstantsLibre2.swift", "Shared/Protocol/Libre2BLEData.swift",
            "Shared/Protocol/Libre2Calibration.swift", "Shared/DataModels/Libre2WatchSession.swift",
            "Shared/Managers/Libre2JournalFile.swift", "Shared/DataModels/Libre2History.swift", "Shared/Managers/Libre2HistoryQueue.swift",
            "Tests/Libre2WatchHistoryDeliveryTests.swift"]],
        source,
    ], flags=["-swift-version", "5", "-D", "LIBRE2_HISTORY_TESTS"])

    # Run the phone's unchanged receive/import scheduling and response methods with a
    # storage spy. Real Core Data behaviour is covered by the hosted iPhone tests.
    phone = (addon / "iPhone/Managers/Libre2PhoneHistorySync.swift").read_text()
    phone = phone[:phone.index("    @MainActor\n    private func register(")]
    phone = phone.replace("import CoreData\n", "").replace("import WatchConnectivity\n", "")
    phone += r'''
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
'''
    # Exercise the actual host delegate hook, including its main-queue dispatch.
    host = (addon.parent / "xDrip/Managers/Watch/WatchManager.swift").read_text()
    hook = host[host.index("    func session(_: WCSession, didReceiveApplicationContext"):
                host.index("    func session(_: WCSession, didReceiveMessageData")]
    phone += "\nextension WatchManager {\n" + hook + "}\n"
    source = work / "Libre2PhoneHistorySync.swift"
    source.write_text(phone)
    run_swift(executable, [
        *[str(addon / path) for path in [
            "Shared/Constants/ConstantsLibre2.swift", "Shared/Protocol/Libre2BLEData.swift",
            "Shared/Protocol/Libre2Calibration.swift", "Shared/DataModels/Libre2WatchSession.swift",
            "Shared/Managers/Libre2JournalFile.swift", "Shared/DataModels/Libre2History.swift", "Shared/DataModels/Libre2PhoneHistoryUpdate.swift",
            "Tests/Libre2PhoneHistoryDeliveryTests.swift"]],
        source,
    ], flags=["-swift-version", "5", "-D", "LIBRE2_PHONE_HISTORY_TESTS"])

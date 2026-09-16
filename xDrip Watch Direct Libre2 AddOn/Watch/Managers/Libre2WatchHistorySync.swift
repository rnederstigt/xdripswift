import Foundation
import WatchConnectivity
import WatchKit

/// Event-driven history delivery using the host's WCSession. No display polling or extra
/// background runtime: Apple schedules queued transfers when the companion is unavailable.
final class Libre2WatchHistorySync {
    private var queue: Libre2HistoryQueue?
    private var sendingBatchID: UUID?
    private var lastAttempt: (id: UUID, date: Date)?
    private var lastLatestAttempt: (id: String, date: Date)?
    private var lastReachability: Bool?
    private var lastWaitingState: String?
    private var activationObserver: NSObjectProtocol?
    private let now: () -> Date

    init(queue: Libre2HistoryQueue? = nil, now: @escaping () -> Date = Date.init) {
        self.queue = queue
        self.now = now
        activationObserver = NotificationCenter.default.addObserver(
            forName: WKExtension.applicationDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resume() }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func resume() {
        Libre2ActivityLog.shared.recordTrace("Delivery: Watch resumed | \(deliveryState)")
        lastAttempt = nil
        lastLatestAttempt = nil
        flush()
    }

    func collect(_ sample: Libre2Sample, sensorMinute: UInt16, session: Libre2WatchSession) {
        do {
            let reading = Libre2HistoryReading(sessionID: session.id, sensorUID: session.sensorUID,
                sensorMinute: sensorMinute, date: sample.timeStamp, glucose: sample.glucoseLevelRaw)
            let previousMinute = try outbox().state.lastCollectedMinute[reading.sensorKey]
            try outbox().append(reading)
            if previousMinute.map({ $0 < sensorMinute }) ?? true {
                Libre2ActivityLog.shared.recordDelivery("Watch collected and stored", reading: reading,
                    details: deliveryState)
            }
            flush()
        } catch { report(error) }
    }

    /// Called for new measurements and WCSession activation/reachability changes.
    func flush() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let reachable = session.isReachable
        if reachable && lastReachability != true {
            lastAttempt = nil
            lastLatestAttempt = nil
        }
        lastReachability = reachable
        do { try publishLatestReadingContext() } catch { report(error) }
        do {
            // Latest delivery is independent of every history batch and its callbacks.
            if reachable { try sendLatestReading() }
            guard let batch = try outbox().nextBatch() else { return }
            guard sendingBatchID == nil else {
                recordHistory("Watch history waiting", batch: batch,
                    details: "reason=live reply outstanding", onlyWhenChanged: true)
                return
            }
            // Leave an existing background transfer to WatchConnectivity. Restored
            // reachability sends the latest reading, not a second copy of this batch.
            if let transfer = session.outstandingUserInfoTransfers.first(where: {
                (try? Libre2HistoryBatch.decode($0.userInfo).id) == batch.id
            }) {
                recordHistory("Watch history waiting", batch: batch,
                    details: "reason=background transfer outstanding transferring=\(transfer.isTransferring)",
                    onlyWhenChanged: true)
                return
            }
            guard try outbox().canRetryBackgroundTransfer(at: now()) else {
                recordHistory("Watch history waiting", batch: batch,
                    details: "reason=background acknowledgement pending retryIntervalSeconds=\(Int(Libre2HistoryQueue.backgroundRetryInterval))",
                    onlyWhenChanged: true)
                return
            }
            let dictionary = try batch.dictionary
            if reachable {
                if let lastAttempt, lastAttempt.id == batch.id, now().timeIntervalSince(lastAttempt.date) < 60 {
                    recordHistory("Watch history waiting", batch: batch,
                        details: "reason=live retry interval", onlyWhenChanged: true)
                    return
                }
                lastAttempt = (batch.id, now())
                sendingBatchID = batch.id
                recordHistory("Watch history live send", batch: batch)
                session.sendMessage(dictionary, replyHandler: { reply in
                    DispatchQueue.main.async {
                        if self.sendingBatchID == batch.id { self.sendingBatchID = nil }
                        if !self.receive(reply) {
                            let error = reply["error"] as? String ?? Libre2HistoryError.invalidBatch.localizedDescription
                            Libre2ActivityLog.shared.record("History sync: \(error)")
                        }
                    }
                }, errorHandler: { error in
                    DispatchQueue.main.async {
                        if self.sendingBatchID == batch.id { self.sendingBatchID = nil }
                        // Interactive delivery is best effort. The durable outbox remains until
                        // an import acknowledgement arrives through either transport.
                        if self.queue?.state.batch?.id == batch.id, session.activationState == .activated {
                            self.queueTransfer(dictionary, batchID: batch.id, reason: "live send failed")
                        }
                        self.report(error)
                    }
                })
            } else {
                queueTransfer(dictionary, batchID: batch.id, reason: "phone unreachable")
            }
        } catch { report(error) }
    }

    /// Keep only the newest pending value in the background context, independently of
    /// history acknowledgements and live reachability. WCSession retains this context
    /// across launches; comparing it also prevents older remaining history replacing it.
    private func publishLatestReadingContext() throws {
        guard let reading = try outbox().state.pending.max(by: { $0.date < $1.date }) else { return }
        let session = WCSession.default
        if session.applicationContext[Libre2HistoryBatch.latestKey] as? Bool == true,
            let published = try? Libre2HistoryBatch.decode(session.applicationContext).readings.first,
            published.date >= reading.date { return }
        do {
            try session.updateApplicationContext(Libre2HistoryBatch(readings: [reading]).latestDictionary)
            Libre2ActivityLog.shared.recordDelivery("Watch latest context published", reading: reading,
                details: deliveryState)
        } catch {
            let failure = error as NSError
            Libre2ActivityLog.shared.recordDelivery("Watch latest context failed", reading: reading,
                details: "\(failure.domain) \(failure.code): \(failure.localizedDescription)")
            report(error)
            // A failed context update must not prevent live delivery or history submission.
            // The next existing delivery event can retry; the journal remains untouched.
        }
    }

    private func sendLatestReading() throws {
        guard let reading = try outbox().state.pending.max(by: { $0.date < $1.date }) else { return }
        // Repeated frames/events may describe the same sensor minute. New measurements
        // bypass this retry throttle, even if a previous live reply never arrives.
        if let lastLatestAttempt, lastLatestAttempt.id == reading.id,
            now().timeIntervalSince(lastLatestAttempt.date) < 60 { return }
        let dictionary = try Libre2HistoryBatch(readings: [reading]).latestDictionary
        lastLatestAttempt = (reading.id, now())
        Libre2ActivityLog.shared.recordDelivery("Watch latest send", reading: reading, details: deliveryState)
        WCSession.default.sendMessage(dictionary, replyHandler: { reply in
            DispatchQueue.main.async {
                let outcome = reply["error"] as? String
                    ?? (reply["superseded"] as? Bool == true ? "superseded"
                        : (try? Libre2HistoryAcknowledgement.decode(reply).readingIDs) == [reading.id]
                            ? "save acknowledgement received" : "unrecognised reply")
                Libre2ActivityLog.shared.recordDelivery("Watch latest reply", reading: reading, details: outcome)
                if let error = reply["error"] as? String {
                    Libre2ActivityLog.shared.record("Latest reading sync: \(error)")
                }
                // History alone removes saved readings from the journal. Neither success,
                // supersession nor failure here can release or block a history batch.
            }
        }, errorHandler: { error in
            DispatchQueue.main.async {
                let failure = error as NSError
                Libre2ActivityLog.shared.recordDelivery("Watch latest send failed", reading: reading,
                    details: "\(failure.domain) \(failure.code): \(failure.localizedDescription)")
                self.report(error)
            }
        })
    }

    private var deliveryState: String {
        let session = WCSession.default
        return "foreground=\(WKApplication.shared().applicationState == .active)"
            + " activated=\(session.activationState == .activated) reachable=\(session.isReachable)"
    }

    private func queueTransfer(_ dictionary: [String: Any], batchID: UUID, reason: String) {
        let session = WCSession.default
        guard !session.outstandingUserInfoTransfers.contains(where: {
            (try? Libre2HistoryBatch.decode($0.userInfo).id) == batchID
        }) else { return }
        do {
            guard try outbox().reserveBackgroundTransfer(batchID: batchID, at: now()) else { return }
        } catch {
            report(error)
            return
        }
        session.transferUserInfo(dictionary)
        if let batch = try? Libre2HistoryBatch.decode(dictionary) {
            recordHistory("Watch background submitted", batch: batch, details: "reason=\(reason)")
        }
    }

    /// Transport completion is not a database acknowledgement. Observe it without draining
    /// the journal, retrying, or otherwise changing the existing delivery decisions.
    func transferFinished(_ dictionary: [String: Any], error: Error?) {
        guard let batch = try? Libre2HistoryBatch.decode(dictionary) else { return }
        let outcome: String
        if let error {
            let failure = error as NSError
            outcome = "error=\(failure.domain) \(failure.code): \(failure.localizedDescription)"
            report(error)
        } else {
            outcome = "transport completed"
        }
        let awaitingAcknowledgement = queue.map { String($0.state.batch?.id == batch.id) } ?? "unknown"
        recordHistory("Watch background finished", batch: batch,
            details: "\(outcome) awaitingAcknowledgement=\(awaitingAcknowledgement)")
    }

    private func recordHistory(_ event: String, batch: Libre2HistoryBatch,
                               details: String = "", onlyWhenChanged: Bool = false) {
        guard Libre2ActivityLog.shared.isTracingEnabled,
            let reading = batch.readings.max(by: { $0.date < $1.date }) else { return }
        let pending = queue?.state.pending ?? []
        let batchIDs = Set(batch.readings.map(\.id))
        let waiting = pending.filter { !batchIDs.contains($0.id) }.count
        let newest = pending.max(by: { $0.date < $1.date })
        let outstanding = WCSession.default.outstandingUserInfoTransfers.filter {
            (try? Libre2HistoryBatch.decode($0.userInfo).id) == batch.id
        }.count
        let state = "batch=\(batch.id.uuidString.prefix(8)) count=\(batch.readings.count) journalLoaded=\(queue != nil)"
            + " pending=\(pending.count) waitingBehind=\(waiting)"
            + " newestPendingMinute=\(newest.map { String($0.sensorMinute) } ?? "none")"
            + " outstanding=\(outstanding) \(deliveryState)"
            + (details.isEmpty ? "" : " \(details)")
        // Collection and reachability already drive flush(). Do not add polling or write
        // the same waiting state on every repeated frame/display event.
        if onlyWhenChanged, lastWaitingState == state { return }
        lastWaitingState = onlyWhenChanged ? state : nil
        Libre2ActivityLog.shared.recordDelivery(event, reading: reading, details: state)
    }

    @discardableResult
    func receive(_ dictionary: [String: Any]) -> Bool {
        guard dictionary[Libre2HistoryAcknowledgement.key] != nil || dictionary[Libre2HistoryRejection.key] != nil else { return false }
        do {
            let resolvedBatchID: UUID
            if dictionary[Libre2HistoryRejection.key] != nil {
                let rejection = try Libre2HistoryRejection.decode(dictionary)
                try outbox().retainUnresolved(rejection)
                resolvedBatchID = rejection.batchID
                Libre2ActivityLog.shared.record(
                    "History sync: retained \(rejection.readingIDs.count) unmatched readings on Watch; continuing with other readings. batch=\(resolvedBatchID.uuidString.prefix(8))")
            } else {
                let acknowledgement = try Libre2HistoryAcknowledgement.decode(dictionary)
                try outbox().acknowledge(acknowledgement)
                resolvedBatchID = acknowledgement.batchID
                Libre2ActivityLog.shared.record("History saved on iPhone (\(acknowledgement.readingIDs.count) readings). batch=\(resolvedBatchID.uuidString.prefix(8))")
            }
            lastWaitingState = nil
            // Either route can finish first. Only release this batch, after saving its result;
            // late interactive callbacks must not clear a newer in-flight batch.
            if sendingBatchID == resolvedBatchID { sendingBatchID = nil }
            for transfer in WCSession.default.outstandingUserInfoTransfers where
                (try? Libre2HistoryBatch.decode(transfer.userInfo).id) == resolvedBatchID {
                if let batch = try? Libre2HistoryBatch.decode(transfer.userInfo) {
                    recordHistory("Watch background cancel requested", batch: batch,
                        details: "reason=batch resolution persisted")
                }
                transfer.cancel()
            }
        } catch Libre2HistoryError.staleAcknowledgement {
            // Duplicate delivery is normal. It must not clear a newer batch.
        } catch {
            report(error)
            return true
        }
        // Drain remaining readings immediately; stale replies cannot resolve a newer batch.
        flush()
        return true
    }

    /// Uses the existing interactive message delegate; independent of the active sensor.
    @discardableResult
    func receiveCleanup(_ dictionary: [String: Any], reply: ([String: Any]) -> Void) -> Bool {
        guard dictionary[Libre2HistoryCleanupRequest.key] != nil else { return false }
        do {
            let request = try Libre2HistoryCleanupRequest.decode(dictionary)
            let queue = try outbox()
            if case .delete(let confirmed) = request {
                try queue.deleteUnresolved(confirmed)
                Libre2ActivityLog.shared.record("Deleted \(confirmed.count) unresolved readings from Watch.")
            }
            // Success is acknowledged only after the journal has been saved.
            reply(try queue.unresolvedReadings.dictionary)
        } catch {
            report(error)
            reply(["error": error.localizedDescription])
        }
        return true
    }

    private func outbox() throws -> Libre2HistoryQueue {
        if let queue { return queue }
        let loaded = try Libre2HistoryQueue()
        queue = loaded
        return loaded
    }

    private func report(_ error: Error) {
        Libre2ActivityLog.shared.record("History sync: \(error.localizedDescription)")
    }
}

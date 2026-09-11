import Foundation
import WatchConnectivity
import WatchKit

/// Event-driven history delivery using the host's WCSession. No display polling or extra
/// background runtime: Apple schedules queued transfers when the companion is unavailable.
final class Libre2WatchHistorySync {
    private var queue: Libre2HistoryQueue?
    private var sendingBatchID: UUID?
    private var lastAttempt: (id: UUID, date: Date)?
    private var activationObserver: NSObjectProtocol?

    init() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: WKExtension.applicationDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resume() }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func resume() {
        lastAttempt = nil
        flush()
    }

    func collect(_ sample: Libre2Sample, sensorMinute: UInt16, session: Libre2WatchSession) {
        do {
            let reading = Libre2HistoryReading(sessionID: session.id, sensorUID: session.sensorUID,
                sensorMinute: sensorMinute, date: sample.timeStamp, glucose: sample.glucoseLevelRaw)
            try outbox().append(reading)
            flush()
        } catch { report(error) }
    }

    /// Called for new measurements and WCSession activation/reachability changes.
    func flush() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        do {
            guard let batch = try outbox().nextBatch(), sendingBatchID == nil else { return }
            // A queued transfer is already managed by WatchConnectivity, including across launch.
            guard !session.outstandingUserInfoTransfers.contains(where: {
                (try? Libre2HistoryBatch.decode($0.userInfo).id) == batch.id
            }) else { return }
            // New frames may arrive before an acknowledgement. Avoid repeatedly sending the same
            // batch; retry on a later collection/lifecycle event, without a periodic timer.
            if let lastAttempt, lastAttempt.id == batch.id, Date().timeIntervalSince(lastAttempt.date) < 60 { return }
            lastAttempt = (batch.id, Date())
            let dictionary = try batch.dictionary
            if session.isReachable {
                sendingBatchID = batch.id
                session.sendMessage(dictionary, replyHandler: { reply in
                    DispatchQueue.main.async {
                        self.sendingBatchID = nil
                        if !self.receive(reply) {
                            let error = reply["error"] as? String ?? Libre2HistoryError.invalidBatch.localizedDescription
                            Libre2ActivityLog.shared.record("History sync: \(error)")
                        }
                    }
                }, errorHandler: { error in
                    DispatchQueue.main.async {
                        self.sendingBatchID = nil
                        // Interactive delivery is best effort. The durable outbox remains until
                        // an import acknowledgement arrives through either transport.
                        if self.queue?.state.batch?.id == batch.id, session.activationState == .activated {
                            session.transferUserInfo(dictionary)
                        }
                        self.report(error)
                    }
                })
            } else {
                session.transferUserInfo(dictionary)
            }
        } catch { report(error) }
    }

    @discardableResult
    func receive(_ dictionary: [String: Any]) -> Bool {
        guard dictionary[Libre2HistoryAcknowledgement.key] != nil else { return false }
        do {
            let acknowledgement = try Libre2HistoryAcknowledgement.decode(dictionary)
            try outbox().acknowledge(acknowledgement)
            Libre2ActivityLog.shared.record("History saved on iPhone (\(acknowledgement.readingIDs.count) readings).")
            flush()
        } catch Libre2HistoryError.staleAcknowledgement {
            // Duplicate delivery is normal. It must not clear a newer batch.
        } catch { report(error) }
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

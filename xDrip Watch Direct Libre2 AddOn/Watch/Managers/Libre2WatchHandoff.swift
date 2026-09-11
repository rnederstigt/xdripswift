import Foundation
import WatchConnectivity

/// Watch-side transaction coordinator. Bluetooth is created lazily after ACTIVATE,
/// or when a saved connection must be disconnected during return recovery.
final class Libre2WatchHandoff {

    // MARK: - Properties

    var onStatus: (String) -> Void = { _ in }
    var onReadings: ([Libre2Sample], UInt16) -> Void = { _, _ in }
    var onCollectedReading: (Libre2Sample, UInt16, Libre2WatchSession) -> Void = { _, _, _ in }

    private let store = Libre2SessionStore.shared
    private var collectorInstance: Libre2WatchCollector?
    private var lastReachability: Bool?
    private var returnRetryWorkItem: DispatchWorkItem?
    private(set) var lastDirectReading = Date.distantPast

    var isReceiving: Bool {
        owner == .watch && collectorInstance?.isConnected == true
            && Date().timeIntervalSince(lastDirectReading) < ConstantsLibre2.recentReadingInterval
    }
    var indicatorText: String {
        if isReceiving { return Texts_DirectLibre.directConnected }
        return isDirect ? Texts_DirectLibre.directWaiting : Texts_DirectLibre.phoneRelay
    }

    var owner: Libre2Owner { store.snapshot.owner }
    var reachable: Bool {
        WCSession.default.activationState == .activated && WCSession.default.isReachable
    }
    func recordReachability() {
        guard lastReachability != reachable else { return }
        lastReachability = reachable
        Libre2ActivityLog.shared.record(
            reachable ? Texts_DirectLibre.phoneReachableLog : Texts_DirectLibre.phoneUnreachableLog)
        if reachable { resumePendingReturn() }
    }

    var isDirect: Bool {
        store.snapshot.owner != .phone
    }

    private var collector: Libre2WatchCollector {
        if let collectorInstance {
            return collectorInstance
        }

        let collector = Libre2WatchCollector()
        collector.onStatus = { [weak self] status in
            self?.publishStatus(status)
        }
        collector.onReadings = { [weak self] samples, sensorAge in
            self?.lastDirectReading = samples.first?.timeStamp ?? .distantPast
            self?.onReadings(samples, sensorAge)
        }
        collector.onCollectedReading = { [weak self] sample, sensorMinute, session in
            self?.onCollectedReading(sample, sensorMinute, session)
        }
        collectorInstance = collector
        return collector
    }

    private func publishStatus(_ status: String) {
        Libre2ActivityLog.shared.record(status)
        onStatus(status)
    }

    // MARK: - Restore persisted ownership

    func restore() {
        switch store.snapshot.owner {
        case .watch:
            collector.start()
        case .preparingWatch:
            publishStatus(Texts_DirectLibre.prepared)
        case .returningToPhone, .releasingWatch:
            publishStatus(Texts_DirectLibre.returnRetryInstructions)
            resumePendingReturn()
        case .phone:
            if store.snapshot.hasExperimentalState { publishStatus(Texts_DirectLibre.phoneRelay) }
        default:
            publishStatus(Texts_DirectLibre.ownershipUnresolved)
        }
    }

    // MARK: - Phone to Watch: PREPARE, ACTIVATE

    func receive(_ dictionary: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        do {
            let message = try Libre2HandoffMessage.decode(dictionary)
            switch message.kind {
            case .prepare:
                try store.prepare(message.session)
                publishStatus(Texts_DirectLibre.prepared)
            case .activate:
                try activateCollector(for: message.session)
            case .revoke:
                if try store.revokeOnWatch(message.session) {
                    stopRevokedSession(message.session, reply: reply)
                    return
                }
            case .requestReturn:
                try store.prepareRequestedReturn(message.session)
                returnToPhone()
            default:
                throw Libre2HandoffError.invalidTransition
            }
            reply(["ready": message.session.id.uuidString])
        } catch {
            reply(["error": error.localizedDescription])
            publishStatus(Texts_DirectLibre.failed(error.localizedDescription))
        }
    }

    private func activateCollector(for session: Libre2WatchSession) throws {
        guard let storedSession = store.snapshot.session,
            storedSession.matchesHandoff(session),
            storedSession.unlockCount >= session.unlockCount
        else {
            throw Libre2HandoffError.staleSession
        }

        // ACTIVATE can be retried after its reply was lost. Do not reset the saved counter.
        if store.snapshot.owner != .watch {
            try store.activateWatch(id: storedSession.id)
        }
        collector.start()
    }

    // MARK: - Watch to phone: RETURN_PREPARE, disconnect, RETURN_COMMIT

    private func returnToPhone() {
        defer { scheduleReturnRetry() }
        guard let session = store.snapshot.session else {
            publishStatus(Texts_DirectLibre.noSavedSession)
            return
        }

        do {
            if store.snapshot.owner == .releasingWatch {
                disconnectWatchAndCommitReturn(session)
                return
            }

            // Freeze authentication at M before asking the phone to persist that counter.
            try store.beginReturnToPhone(id: session.id)
            publishStatus(Texts_DirectLibre.returning)
            Libre2ActivityLog.shared.record(Texts_DirectLibre.returnPrepareSent)
            send(.returnPrepare, session: session) {
                self.handleReturnReady(session)
            }
        } catch {
            publishStatus(Texts_DirectLibre.failed(error.localizedDescription))
        }
    }

    private func handleReturnReady(_ session: Libre2WatchSession) {
        guard owner == .returningToPhone, store.snapshot.session?.id == session.id else { return }
        do {
            try store.beginWatchRelease(id: session.id)
            disconnectWatchAndCommitReturn(session)
        } catch {
            publishStatus(Texts_DirectLibre.failed(error.localizedDescription))
        }
    }

    private func disconnectWatchAndCommitReturn(_ session: Libre2WatchSession) {
        let disconnected = {
            self.commitReturn(session)
        }

        // This barrier applies to retries too. After restart the collector retrieves the
        // persisted peripheral and cancels it before allowing RETURN_COMMIT.
        if store.snapshot.watchMayHaveConnected {
            collector.stop(completion: disconnected)
        } else {
            // A return directly from Prepared has never been allowed to connect.
            disconnected()
        }
    }

    private func commitReturn(_ session: Libre2WatchSession) {
        Libre2ActivityLog.shared.record(Texts_DirectLibre.returnCommitSent)
        send(.returnCommit, session: session) {
            do {
                try self.store.finishReturnOnWatch(id: session.id)
                self.publishStatus(Texts_DirectLibre.phoneRelay)
            } catch {
                self.publishStatus(Texts_DirectLibre.failed(error.localizedDescription))
            }
        }
    }

    // MARK: - Interrupted return recovery

    /// These retries finish a return already requested by the phone; they never initiate a takeover.
    private func resumePendingReturn() {
        guard [.returningToPhone, .releasingWatch].contains(owner),
            let session = store.snapshot.session
        else { return }
        if store.snapshot.retiredIDs.contains(session.id) {
            // An interrupted NFC revocation needs only a local disconnect, not RETURN_COMMIT.
            stopRevokedSession(session) { _ in }
        } else {
            returnToPhone()
        }
    }

    private func scheduleReturnRetry() {
        returnRetryWorkItem?.cancel()
        guard [.returningToPhone, .releasingWatch].contains(owner),
            let session = store.snapshot.session,
            !store.snapshot.retiredIDs.contains(session.id)
        else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.store.snapshot.session?.id == session.id else { return }
            self.resumePendingReturn()
        }
        returnRetryWorkItem = work
        // A lost COMMIT acknowledgement must not strand Watch without any Watch-side controls.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func stopRevokedSession(
        _ session: Libre2WatchSession, reply: @escaping ([String: Any]) -> Void
    ) {
        returnRetryWorkItem?.cancel()
        let finish = {
            do {
                try self.store.finishReturnOnWatch(id: session.id)
                self.publishStatus(Texts_DirectLibre.phoneRelay)
                reply(["ready": session.id.uuidString])
            } catch { reply(["error": error.localizedDescription]) }
        }
        if store.snapshot.watchMayHaveConnected { collector.stop(completion: finish) } else { finish() }
    }

    // MARK: - WatchConnectivity

    private func send(
        _ kind: Libre2HandoffMessage.Kind, session: Libre2WatchSession, ready: @escaping () -> Void
    ) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            publishStatus(Texts_DirectLibre.phoneUnreachable)
            return
        }

        do {
            let message = try Libre2HandoffMessage(kind: kind, session: session).dictionary
            let expectedOwner = owner
            WCSession.default.sendMessage(
                message,
                replyHandler: { reply in
                    DispatchQueue.main.async {
                        // Ignore replies from a phase superseded by cancellation or a completed return.
                        guard self.owner == expectedOwner, self.store.snapshot.session?.id == session.id else {
                            return
                        }
                        guard reply["ready"] as? String == session.id.uuidString else {
                            let reason = reply["error"] as? String ?? Texts_DirectLibre.returnRejected
                            self.publishStatus(Texts_DirectLibre.failed(reason))
                            return
                        }
                        ready()
                    }
                },
                errorHandler: { error in
                    DispatchQueue.main.async {
                        // Ignore replies from a phase superseded by cancellation or a completed return.
                        guard self.owner == expectedOwner, self.store.snapshot.session?.id == session.id else {
                            return
                        }
                        self.publishStatus(Texts_DirectLibre.returnFailed(error.localizedDescription))
                    }
                })
        } catch {
            publishStatus(Texts_DirectLibre.failed(error.localizedDescription))
        }
    }
}

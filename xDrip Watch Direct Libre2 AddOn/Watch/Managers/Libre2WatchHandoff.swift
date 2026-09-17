import Foundation
import WatchConnectivity

/// Watch-side transaction coordinator. Bluetooth is created lazily after ACTIVATE,
/// or when a saved connection must be disconnected during return recovery.
final class Libre2WatchHandoff {

    // MARK: - Properties

    var onChange: () -> Void = {}
    var onReadings: ([Libre2Sample], UInt16) -> Void = { _, _ in }
    var onCollectedReading: (Libre2Sample, UInt16, Libre2WatchSession) -> Void = { _, _, _ in }

    private let store: Libre2SessionStore
    private var collectorInstance: Libre2WatchCollector?
    private var lastReachability: Bool?
    private var returnRetryWorkItem: DispatchWorkItem?
    private var retirementReplies: [([String: Any]) -> Void] = []

    init(store: Libre2SessionStore = .shared) {
        self.store = store
    }

    var connectionState: Libre2WatchCollector.ConnectionState {
        if owner.isReturningToPhone || owner == .returnRequested { return .disconnecting }
        guard owner.allowsWatchConnection else { return .inactive }
        return collectorInstance?.connectionState ?? .inactive
    }
    var indicatorText: String {
        switch owner {
        case .phone: return Texts_DirectLibre.phoneRelay
        case .preparingWatch, .releasingPhone: return Texts_DirectLibre.prepared
        case .watch: return connectionState.text
        case .returnRequested, .returningToPhone, .releasingWatch: return Texts_DirectLibre.returning
        case .failed: return Texts_DirectLibre.resetOnPhone
        }
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
        collector.onConnectionChanged = { [weak self] in
            // Refresh immediately, including before first glucose and during a return.
            self?.onChange()
        }
        collector.onReadings = { [weak self] samples, sensorAge in
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
        onChange()
    }

    // MARK: - Restore persisted ownership

    func restartConnection() {
        guard owner.allowsWatchConnection else {
            // A tap cannot activate Prepared or reverse a return/NFC reset.
            publishStatus(indicatorText)
            return
        }
        collector.restartConnection()
    }

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
            // Validate the complete message before persisting retirements or stopping Bluetooth.
            let message = dictionary[Libre2HandoffMessage.key] == nil ? nil : try Libre2HandoffMessage.decode(dictionary)
            let retiredIDs = try Libre2HandoffMessage.retiredIDs(from: dictionary) ?? []
            if !retiredIDs.isEmpty, let retired = try store.retireOnWatch(retiredIDs) {
                publishStatus("Phone retired the Direct Libre handoff; disconnecting Watch.")
                stopRetiredSession(retired) { response in
                    guard response["error"] == nil else { reply(response); return }
                    self.receiveHandoff(message, reply: reply)
                }
            } else {
                receiveHandoff(message, reply: reply)
            }
        } catch {
            reply(["error": error.localizedDescription])
            publishStatus(Texts_DirectLibre.failed(error.localizedDescription))
        }
    }

    private func receiveHandoff(_ message: Libre2HandoffMessage?, reply: @escaping ([String: Any]) -> Void) {
        guard let message else {
            reply(["retiredHandoffsApplied": true])
            return
        }
        do {
            switch message.kind {
            case .prepare:
                try store.prepare(message.session)
                publishStatus(Texts_DirectLibre.prepared)
            case .activate:
                try activateCollector(for: message.session)
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
        guard store.snapshot.matches(id: session.id, owner: .returningToPhone) else { return }
        do {
            try store.beginWatchRelease(id: session.id)
            disconnectWatchAndCommitReturn(session)
        } catch {
            publishStatus(Texts_DirectLibre.failed(error.localizedDescription))
        }
    }

    private func disconnectWatchAndCommitReturn(_ session: Libre2WatchSession) {
        disconnectWatch { self.commitReturn(session) }
    }

    /// Both normal return and NFC retirement use the same local release barrier.
    /// Prepared sessions have never connected. After a restart, the collector retrieves
    /// and cancels its saved peripheral before invoking the completion.
    private func disconnectWatch(completion: @escaping () -> Void) {
        if store.snapshot.watchMayHaveConnected {
            collector.stop(completion: completion)
        } else {
            completion()
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
        guard owner.isReturningToPhone,
            let session = store.snapshot.session
        else { return }
        if store.snapshot.retiredIDs.contains(session.id) {
            // An interrupted NFC revocation needs only a local disconnect, not RETURN_COMMIT.
            stopRetiredSession(session) { _ in }
        } else {
            returnToPhone()
        }
    }

    private func scheduleReturnRetry() {
        returnRetryWorkItem?.cancel()
        guard owner.isReturningToPhone,
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

    private func stopRetiredSession(
        _ session: Libre2WatchSession, reply: @escaping ([String: Any]) -> Void
    ) {
        returnRetryWorkItem?.cancel()
        // Live and queued retirement may arrive together. Share the disconnect barrier
        // rather than replacing the collector's completion and losing a waiting PREPARE.
        retirementReplies.append(reply)
        guard retirementReplies.count == 1 else { return }
        let finish = {
            let response: [String: Any]
            do {
                try self.store.finishReturnOnWatch(id: session.id)
                self.publishStatus(Texts_DirectLibre.phoneRelay)
                response = ["ready": session.id.uuidString]
            } catch { response = ["error": error.localizedDescription] }
            let replies = self.retirementReplies
            self.retirementReplies.removeAll()
            replies.forEach { $0(response) }
        }
        disconnectWatch(completion: finish)
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
                        guard self.store.snapshot.matches(id: session.id, owner: expectedOwner) else {
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
                        guard self.store.snapshot.matches(id: session.id, owner: expectedOwner) else {
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

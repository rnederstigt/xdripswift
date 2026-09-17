import Combine
import Foundation
import WatchConnectivity

/// Coordinates phone ownership using WatchManager's existing WCSession delegate.
/// Call UI actions and message handlers on main. The sensor freezes its counter on the Bluetooth queue.
final class Libre2PhoneHandoff: ObservableObject {

    // MARK: - Properties

    static let shared = Libre2PhoneHandoff()

    weak var sensor: Libre2PhoneSensor?
    var registerHistorySession: ((Libre2WatchSession, @escaping (Result<Void, Error>) -> Void) -> Void)?
    var isPageVisible = false {
        didSet {
            Libre2ActivityLog.shared.isPageVisible = isPageVisible
            if isPageVisible { refreshChecklist() }
        }
    }
    var readingStatus = Libre2PhoneReadingStatus() {
        didSet { refreshChecklist() }
    }
    @Published var status = "" {
        didSet { Libre2ActivityLog.shared.record(status) }
    }
    @Published private(set) var isStarting = false
    private var lastWatchAvailability: WatchAvailability?
    private var lastSettings: ChecklistSettings?
    var owner: Libre2Owner { store.snapshot.owner }
    var canCancel: Bool {
        store.snapshot.phoneSwitchAction == .returnToPhone
    }

    private let store = Libre2SessionStore.shared

    var reachable: Bool {
        WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    var canStart: Bool {
        owner == .phone && !isStarting && !store.phoneNFCIsActive
            && checklistGroups.flatMap(\.items).allSatisfy { $0.isSatisfied }
    }

    private struct WatchAvailability: Equatable {
        let isActivated: Bool
        let isPaired: Bool
        let isInstalled: Bool
        let isReachable: Bool
    }

    func recordReachability() {
        let session = WCSession.default
        let availability = WatchAvailability(
            isActivated: session.activationState == .activated,
            isPaired: session.isPaired,
            isInstalled: session.isWatchAppInstalled,
            isReachable: reachable)
        let previous = lastWatchAvailability
        guard availability != previous else { return }
        lastWatchAvailability = availability
        refreshChecklist()
        guard previous?.isReachable != availability.isReachable else { return }
        Libre2ActivityLog.shared.record(availability.isReachable ? Texts_DirectLibre.watchReachableLog : Texts_DirectLibre.watchUnreachableLog)
        if availability.isReachable { syncRetiredSessions() }
    }

    /// Called on main for connection, ownership or freshness changes; never sends a radio request.
    func refreshChecklist() {
        if isPageVisible { objectWillChange.send() }
    }

    /// Ignore unrelated preference writes, including the activity journal and normal app updates.
    func refreshChecklistSettings() {
        let settings = ChecklistSettings(
            isMaster: UserDefaults.standard.isMaster,
            nativeAlgorithm: sensor?.usesNativeAlgorithm == true,
            suppressUnlock: UserDefaults.standard.suppressUnLockPayLoad,
            unlockCode: UserDefaults.standard.libreActiveSensorUnlockCode,
            sensorUID: UserDefaults.standard.libreSensorUID)
        guard settings != lastSettings else { return }
        lastSettings = settings
        refreshChecklist()
    }

    private struct ChecklistSettings: Equatable {
        let isMaster: Bool
        let nativeAlgorithm: Bool
        let suppressUnlock: Bool
        let unlockCode: UInt32
        let sensorUID: Data?
    }

    // MARK: - User actions

    func start() {
        guard canStart, let sensor else {
            status = Libre2HandoffError.unavailable.localizedDescription
            return
        }

        isStarting = true
        status = Texts_DirectLibre.preparingWatch
        sensor.prepareDirectWatch { result in
            self.isStarting = false
            switch result {
            case .success(let session):
                self.prepareWatch(session)
            case .failure(let error):
                self.status = error.localizedDescription
            }
        }
    }

    /// Request a normal return, even if cancellation overtakes the original PREPARE message.
    func cancelAndReturn() {
        guard canCancel, let session = store.snapshot.session else { return }
        do {
            try store.requestReturnFromWatch(id: session.id)
            status = Texts_DirectLibre.returnRequested
            Libre2ActivityLog.shared.record(Texts_DirectLibre.requestSent)
            send(.requestReturn, session: session) {
                if self.owner == .returnRequested {
                    self.status = Texts_DirectLibre.returnRequested
                }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func didUpdatePhoneReadingStatus(_ snapshot: Libre2PhoneReadingStatus) {
        guard owner.allowsPhoneConnection else { return }
        let hadRecentReading = readingStatus.hasRecentReading()
        let hadVerifiedReading = readingStatus.hasRecentVerifiedReading()
        readingStatus = snapshot
        if !hadRecentReading && snapshot.hasRecentReading() {
            Libre2ActivityLog.shared.record(Texts_DirectLibre.phoneBLEReadingReceived)
        }
        if !hadVerifiedReading && snapshot.hasRecentVerifiedReading() {
            Libre2ActivityLog.shared.record(Texts_DirectLibre.phoneLoginVerified)
        }
    }

    // MARK: - Phone to Watch: PREPARE, disconnect, ACTIVATE

    private func prepareWatch(_ session: Libre2WatchSession) {
        guard let registerHistorySession else {
            status = Libre2HistoryError.unavailable.localizedDescription
            return
        }
        registerHistorySession(session) { result in
            guard self.store.snapshot.matches(id: session.id, owner: .preparingWatch) else { return }
            switch result {
            case .success: self.sendWatchPreparation(session)
            case .failure(let error): self.status = error.localizedDescription
            }
        }
    }

    private func sendWatchPreparation(_ session: Libre2WatchSession) {
        Libre2ActivityLog.shared.record(Texts_DirectLibre.prepareSent)
        send(.prepare, session: session) {
            guard self.store.snapshot.matches(id: session.id, owner: .preparingWatch) else { return }
            do {
                try self.store.beginPhoneRelease(id: session.id)
                self.disconnectPhoneAndActivateWatch(session)
            } catch {
                self.status = error.localizedDescription
            }
        }
    }

    private func disconnectPhoneAndActivateWatch(_ session: Libre2WatchSession) {
        guard let sensor else {
            status = Texts_DirectLibre.waitingForPhoneTransport
            return
        }

        status = Texts_DirectLibre.disconnectingPhone
        sensor.disconnect {
            // An intervening return message can supersede an outstanding disconnect callback.
            guard self.store.snapshot.matches(id: session.id, owner: .releasingPhone)
            else {
                return
            }
            self.activateWatch(session)
        }
    }

    private func activateWatch(_ session: Libre2WatchSession) {
        Libre2ActivityLog.shared.record(Texts_DirectLibre.activateSent)
        send(.activate, session: session) {
            guard self.store.snapshot.matches(id: session.id, owner: .releasingPhone) else { return }
            do {
                try self.store.confirmWatchOwnership(id: session.id)
                self.status = Texts_DirectLibre.watchOwnsLibre
            } catch {
                self.status = error.localizedDescription
            }
        }
    }

    // MARK: - Watch to phone: RETURN_PREPARE, RETURN_COMMIT

    func receive(_ dictionary: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        do {
            let message = try Libre2HandoffMessage.decode(dictionary)
            switch message.kind {
            case .returnPrepare:
                try acceptReturnPreparation(message.session)
            case .returnCommit:
                try completeReturn(message.session)
            default:
                throw Libre2HandoffError.invalidTransition
            }
            reply(["ready": message.session.id.uuidString])
        } catch {
            Libre2ActivityLog.shared.record(error.localizedDescription)
            reply(["error": error.localizedDescription])
        }
    }

    private func acceptReturnPreparation(_ session: Libre2WatchSession) throws {
        guard owner == .returnRequested || owner == .returningToPhone else { throw Libre2HandoffError.invalidTransition }
        try store.acceptReturn(session)
        UserDefaults.standard.libreActiveSensorUnlockCount = session.unlockCount
        status = Texts_DirectLibre.waitingForWatchDisconnect
    }

    private func completeReturn(_ session: Libre2WatchSession) throws {
        // A lost acknowledgement may be retried after phone counters advance or another NFC scan.
        // Acknowledge the retired ID without copying old credentials/counters or changing current status.
        if owner == .phone, store.snapshot.retiredIDs.contains(session.id) { return }
        guard let storedSession = store.snapshot.session,
            storedSession.matchesHandoff(session),
            storedSession.unlockCount == session.unlockCount
        else {
            throw Libre2HandoffError.staleSession
        }

        // Repeated COMMIT must not overwrite a counter that the phone has already advanced.
        let shouldResumePhone = store.snapshot.owner == .returningToPhone
        if shouldResumePhone {
            UserDefaults.standard.libreActiveSensorUnlockCount = storedSession.unlockCount
        }
        try store.finishReturnOnPhone(id: storedSession.id)
        status = Texts_DirectLibre.phoneOwnsLibre
        if shouldResumePhone {
            sensor?.connect()
        }
    }

    // MARK: - WatchConnectivity

    /// NFC recovery must also reach a Watch which missed the original queued revocation.
    /// Use the existing journal, activation/reachability events and transaction messages.
    private var retiredSessionsDictionary: [String: Any] {
        [Libre2HandoffMessage.retiredIDsKey: store.snapshot.retiredIDs.map(\.uuidString).sorted()]
    }

    func notifyWatchOfNFCReset() {
        let session = WCSession.default
        if session.activationState == .activated {
            session.transferUserInfo(retiredSessionsDictionary)
        }
        syncRetiredSessions()
    }

    private func syncRetiredSessions() {
        guard reachable, !store.snapshot.retiredIDs.isEmpty else { return }
        WCSession.default.sendMessage(retiredSessionsDictionary, replyHandler: { _ in }, errorHandler: { _ in
            // Persisted IDs are resent on restored reachability and with the next transaction.
        })
    }

    static func receiveWatchMessage(_ dictionary: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard dictionary[Libre2HandoffMessage.key] != nil else { reply([:]); return }
        DispatchQueue.main.async { shared.receive(dictionary, reply: reply) }
    }

    private func send(_ kind: Libre2HandoffMessage.Kind, session: Libre2WatchSession, ready: @escaping () -> Void) {
        guard reachable else {
            status = Texts_DirectLibre.watchUnreachable
            return
        }

        do {
            var message = try Libre2HandoffMessage(kind: kind, session: session).dictionary
            message.merge(retiredSessionsDictionary) { _, retirement in retirement }
            let expectedOwner = owner
            WCSession.default.sendMessage(
                message,
                replyHandler: { reply in
                    DispatchQueue.main.async {
                        // Ignore replies from a phase superseded by cancellation or a completed return.
                        guard self.store.snapshot.matches(id: session.id, owner: expectedOwner) else { return }
                        guard reply["ready"] as? String == session.id.uuidString else {
                            self.status = reply["error"] as? String ?? Texts_DirectLibre.handoffRejected
                            return
                        }
                        ready()
                    }
                },
                errorHandler: { error in
                    DispatchQueue.main.async {
                        // Ignore replies from a phase superseded by cancellation or a completed return.
                        guard self.store.snapshot.matches(id: session.id, owner: expectedOwner) else { return }
                        self.status = Texts_DirectLibre.handoffFailed(error.localizedDescription)
                    }
                })
        } catch {
            status = error.localizedDescription
        }
    }
}

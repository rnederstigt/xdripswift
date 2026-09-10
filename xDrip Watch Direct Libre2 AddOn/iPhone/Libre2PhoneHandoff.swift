import Combine
import CoreBluetooth
import CoreNFC
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
    @Published private(set) var isVerifyingPhoneConnection = false
    @Published var status = "" {
        didSet { Libre2ActivityLog.shared.record(status) }
    }
    @Published private(set) var isStarting = false
    private var lastReachability: Bool?
    private var lastWatchState: [Bool] = []
    private var lastSettings: ChecklistSettings?
    private var verificationTimeout: DispatchWorkItem?
    private var reclaimReader: Libre2PhoneReclaim?
    @Published private(set) var isReclaiming = false

    private var reclaimSensorUID: Data? {
        if let uid = store.snapshot.session?.sensorUID, uid.count == 8 { return uid }
        if let uid = UserDefaults.standard.libreSensorUID, uid.count == 8 { return uid }
        return nil
    }

    var canReclaim: Bool {
        !isReclaiming && !isStarting && !store.phoneNFCIsActive && sensor != nil
            && reclaimSensorUID != nil
            && NFCTagReaderSession.readingAvailable
    }

    var owner: Libre2Owner { store.snapshot.owner }
    var canCancel: Bool {
        [.preparingWatch, .releasingPhone, .watch, .returnRequested, .returningToPhone].contains(owner) && store.snapshot.session != nil
    }

    private let store = Libre2SessionStore.shared

    var reachable: Bool {
        WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    var isPending: Bool {
        store.snapshot.owner != .phone
    }

    var checklistGroups: [Libre2ChecklistGroup] {
        let session = WCSession.default
        let activated = session.activationState == .activated
        return [
            Libre2ChecklistGroup(
                id: .watch, title: Texts_DirectLibre.watchAppSection,
                items: [
                    Libre2ChecklistItem(
                        id: "installed", title: Texts_DirectLibre.watchAppReady, detail: Texts_DirectLibre.watchInstalledHelp,
                        isSatisfied: activated && session.isPaired && session.isWatchAppInstalled),
                    Libre2ChecklistItem(
                        id: "reachable", title: Texts_DirectLibre.watchReachable, detail: Texts_DirectLibre.reachabilityHelp,
                        isSatisfied: reachable),
                ]),
            Libre2ChecklistGroup(
                id: .sensor, title: Texts_DirectLibre.sensorSection,
                items: [
                    Libre2ChecklistItem(
                        id: "master", title: Texts_DirectLibre.masterMode, detail: Texts_DirectLibre.masterHelp,
                        isSatisfied: UserDefaults.standard.isMaster),
                    Libre2ChecklistItem(
                        id: "native", title: Texts_DirectLibre.nativeAlgorithm, detail: Texts_DirectLibre.nativeHelp,
                        isSatisfied: sensor?.usesNativeAlgorithm == true),
                    Libre2ChecklistItem(
                        id: "unlock", title: Texts_DirectLibre.unlockEnabled, detail: Texts_DirectLibre.unlockHelp,
                        isSatisfied: !UserDefaults.standard.suppressUnLockPayLoad),
                ]),
            Libre2ChecklistGroup(
                id: .phone, title: Texts_DirectLibre.phoneConnectionSection,
                items: [
                    Libre2ChecklistItem(
                        id: "connected", title: Texts_DirectLibre.phoneConnected, detail: Texts_DirectLibre.phoneConnectedHelp,
                        isSatisfied: sensor?.isConnected == true),
                    Libre2ChecklistItem(
                        id: "reading", title: Texts_DirectLibre.freshReading, detail: readingDetail,
                        showsDetailWhenSatisfied: true, isSatisfied: readingStatus.hasRecentReading()),
                    Libre2ChecklistItem(
                        id: "phoneLogin", title: Texts_DirectLibre.phoneLoginVerified, detail: Texts_DirectLibre.phoneLoginHelp,
                        isSatisfied: readingStatus.hasRecentVerifiedReading()
                            && readingStatus.verifiedUnlockCode == UserDefaults.standard.libreActiveSensorUnlockCode),
                ], note: owner.allowsPhoneConnection ? nil : Texts_DirectLibre.phoneConnectionPaused),
        ]
    }

    var switchButtonTitle: String {
        switch store.snapshot.phoneSwitchAction {
        case .switchToWatch: return Texts_DirectLibre.connectToWatch
        case .returnToPhone:
            return [.returnRequested, .returningToPhone].contains(owner)
                ? Texts_DirectLibre.retryReturnToPhone : Texts_DirectLibre.cancelReturn
        case .retryPhoneRecovery: return Texts_DirectLibre.retryPhoneConnection
        case .unavailable: return Texts_DirectLibre.cancelReturn
        }
    }

    var switchButtonSymbol: String {
        store.snapshot.phoneSwitchAction == .switchToWatch ? "applewatch" : "iphone"
    }

    var canSwitchDevice: Bool {
        guard !isStarting, !isReclaiming, !isVerifyingPhoneConnection, !store.phoneNFCIsActive else { return false }
        switch store.snapshot.phoneSwitchAction {
        case .switchToWatch: return canStart
        case .returnToPhone: return canCancel
        case .retryPhoneRecovery: return sensor != nil
        case .unavailable: return false
        }
    }

    /// Cancellation and retry reuse the existing protocol; this never changes ownership directly.
    func switchDevice() {
        guard canSwitchDevice else { return }
        switch store.snapshot.phoneSwitchAction {
        case .switchToWatch: start()
        case .returnToPhone: cancelAndReturn()
        case .retryPhoneRecovery: retry()
        case .unavailable: break
        }
    }

    private var readingDetail: String {
        guard let date = readingStatus.lastReadingAt else { return Texts_DirectLibre.noPhoneBLEReading }
        return Texts_DirectLibre.lastPhoneBLEReading(date)
    }

    var canVerifyPhoneConnection: Bool {
        owner == .phone && !isStarting && !isReclaiming && !isVerifyingPhoneConnection
            && !store.phoneNFCIsActive && sensor?.isConnected == true
            && !UserDefaults.standard.suppressUnLockPayLoad
    }

    /// Re-establish an observable phone login after Core Bluetooth restores an existing stream.
    /// This uses the current credentials and the BLE-only scanner, never NFC provisioning.
    func verifyPhoneConnection() {
        guard canVerifyPhoneConnection, let sensor else { return }
        isVerifyingPhoneConnection = true
        readingStatus = Libre2PhoneReadingStatus()
        status = Texts_DirectLibre.verifyingPhoneConnection
        sensor.disconnect { [weak self, weak sensor] in
            guard let self else { return }
            self.isVerifyingPhoneConnection = false
            guard self.owner == .phone, let sensor, self.sensor === sensor else { return }
            sensor.startBLEScanning()
        }
    }

    var canStart: Bool {
        owner == .phone && !isStarting && !isReclaiming && !isVerifyingPhoneConnection && !store.phoneNFCIsActive
            && checklistGroups.flatMap(\.items).allSatisfy { $0.isSatisfied == true }
    }

    func recordReachability() {
        let session = WCSession.default
        let watchState = [session.activationState == .activated, session.isPaired, session.isWatchAppInstalled, reachable]
        if watchState != lastWatchState {
            lastWatchState = watchState
            refreshChecklist()
        }
        guard lastReachability != reachable else { return }
        lastReachability = reachable
        Libre2ActivityLog.shared.record(reachable ? Texts_DirectLibre.watchReachableLog : Texts_DirectLibre.watchUnreachableLog)
        if reachable, store.snapshot.reclaim != nil { notifyWatchOfReclaim() }
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
            case .success:
                self.retry()
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

    /// Phone recovery never depends on Watch reachability or acknowledgement.
    func reclaimViaNFC() {
        guard canReclaim, let sensor,
            let uid = reclaimSensorUID
        else { return }
        do {
            var code = UInt32.random(in: 1...(UInt32.max - UInt32(UInt16.max)))
            while code == 42 || code == UserDefaults.standard.libreActiveSensorUnlockCode || code == store.snapshot.session?.unlockCode
                || code == store.snapshot.reclaim?.unlockCode
            {
                code = UInt32.random(in: 1...(UInt32.max - UInt32(UInt16.max)))
            }
            let attempt = try store.beginReclaim(sensorUID: uid, unlockCode: code)
            isReclaiming = true
            readingStatus = Libre2PhoneReadingStatus()
            isVerifyingPhoneConnection = false
            sensor.disconnect()
            notifyWatchOfReclaim()
            status = Texts_DirectLibre.reclaimScanning
            reclaimReader = Libre2PhoneReclaim(
                sensor: sensor, attempt: attempt,
                status: { [weak self] in self?.status = $0 },
                finished: { [weak self] in
                    // NFC delegates issue expected-device/start-BLE callbacks immediately afterward.
                    DispatchQueue.main.async {
                        self?.isReclaiming = false
                        self?.reclaimReader = nil
                        self?.scheduleVerificationTimeout()
                    }
                })
            reclaimReader?.start()
        } catch { status = error.localizedDescription }
    }

    private func scheduleVerificationTimeout() {
        verificationTimeout?.cancel()
        guard let id = store.snapshot.reclaim?.id else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.store.snapshot.reclaim?.id == id,
                self.owner == .verifyingPhone || self.owner == .reclaimingPhone
            else { return }
            self.status = Texts_DirectLibre.reclaimNotVerified
        }
        verificationTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: item)
    }

    private func retryReclaimVerification() {
        guard let id = store.snapshot.reclaim?.id else { return }
        status = Texts_DirectLibre.reclaimVerifying
        sensor?.disconnect {
            do {
                try self.store.beginReclaimVerification(id: id)
                self.sensor?.connect()
                self.scheduleVerificationTimeout()
            } catch { self.status = error.localizedDescription }
        }
    }

    private func notifyWatchOfReclaim() {
        guard reachable, let old = store.snapshot.session else { return }
        do {
            let message = try Libre2HandoffMessage(kind: .revoke, session: old).dictionary
            WCSession.default.sendMessage(message, replyHandler: { _ in }, errorHandler: { _ in })
            Libre2ActivityLog.shared.record(Texts_DirectLibre.revokeSent)
        } catch { Libre2ActivityLog.shared.record(error.localizedDescription) }
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
            if status == Texts_DirectLibre.verifyingPhoneConnection { status = Texts_DirectLibre.phoneLoginVerified }
        }
        if owner == .verifyingPhone, let recovery = store.snapshot.reclaim,
            snapshot.hasRecentVerifiedReading(), recovery.nfcConfirmed, recovery.unlockCode == snapshot.verifiedUnlockCode
        {
            do {
                try store.confirmReclaimReading(id: recovery.id)
                verificationTimeout?.cancel()
                status = Texts_DirectLibre.reclaimVerified
            } catch { status = error.localizedDescription }
        }
    }

    /// Resume the saved phase; an uncertain transaction never enables phone Bluetooth.
    func retry() {
        if owner == .verifyingPhone || (owner == .reclaimingPhone && store.snapshot.reclaim?.nfcConfirmed == true) {
            retryReclaimVerification()
            return
        }
        guard let session = store.snapshot.session else {
            status = Texts_DirectLibre.usePhoneRecovery
            return
        }

        switch store.snapshot.owner {
        case .preparingWatch:
            prepareWatch(session)
        case .releasingPhone:
            disconnectPhoneAndActivateWatch(session)
        case .returnRequested:
            cancelAndReturn()
        case .watch, .returningToPhone:
            cancelAndReturn()
        case .verifyingPhone:
            retryReclaimVerification()
        case .reclaimingPhone:
            if store.snapshot.reclaim?.nfcConfirmed == true { retryReclaimVerification() } else { reclaimViaNFC() }
        default:
            status = Texts_DirectLibre.openBothAppsToReturn
        }
    }

    // MARK: - Phone to Watch: PREPARE, disconnect, ACTIVATE

    private func prepareWatch(_ session: Libre2WatchSession) {
        guard let registerHistorySession else {
            status = Libre2HistoryError.unavailable.localizedDescription
            return
        }
        registerHistorySession(session) { result in
            guard self.owner == .preparingWatch, self.store.snapshot.session?.id == session.id else { return }
            switch result {
            case .success: self.sendWatchPreparation(session)
            case .failure(let error): self.status = error.localizedDescription
            }
        }
    }

    private func sendWatchPreparation(_ session: Libre2WatchSession) {
        Libre2ActivityLog.shared.record(Texts_DirectLibre.prepareSent)
        send(.prepare, session: session) {
            guard self.owner == .preparingWatch, self.store.snapshot.session?.id == session.id else { return }
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
            guard self.store.snapshot.owner == .releasingPhone,
                self.store.snapshot.session?.id == session.id
            else {
                return
            }
            self.activateWatch(session)
        }
    }

    private func activateWatch(_ session: Libre2WatchSession) {
        Libre2ActivityLog.shared.record(Texts_DirectLibre.activateSent)
        send(.activate, session: session) {
            guard self.owner == .releasingPhone, self.store.snapshot.session?.id == session.id else { return }
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
            let message = try Libre2HandoffMessage(kind: kind, session: session).dictionary
            let expectedOwner = owner
            WCSession.default.sendMessage(
                message,
                replyHandler: { reply in
                    DispatchQueue.main.async {
                        // Ignore replies from a phase superseded by cancellation or a completed return.
                        guard self.owner == expectedOwner, self.store.snapshot.session?.id == session.id else { return }
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
                        guard self.owner == expectedOwner, self.store.snapshot.session?.id == session.id else { return }
                        self.status = Texts_DirectLibre.handoffFailed(error.localizedDescription)
                    }
                })
        } catch {
            status = error.localizedDescription
        }
    }
}

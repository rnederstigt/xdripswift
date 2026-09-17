import Foundation

/// Persists ownership before allowing any Bluetooth or WatchConnectivity side effect.
/// Phone access spans the Bluetooth and main queues; Watch access stays on main.
final class Libre2SessionStore {

    // MARK: - Properties

    static let shared = Libre2SessionStore()
    static let didChange = Notification.Name("Libre2SessionStoreDidChange")

    private var nfcActive = false
    private var confirmedNFCResetCode: UInt32?

    var phoneNFCIsActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return nfcActive
    }

    private let lock = NSRecursiveLock()
    private var record: Libre2OwnershipRecord
    private let persist: (Libre2OwnershipRecord) throws -> Void

    var snapshot: Libre2OwnershipRecord {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    // MARK: - Initialization

    /// The injected writer lets tests fail persistence without invoking Bluetooth.
    init(
        record: Libre2OwnershipRecord = Libre2OwnershipRecord(),
        persist: @escaping (Libre2OwnershipRecord) throws -> Void
    ) {
        self.record = record
        self.persist = persist
    }

    convenience init(fileURL: URL = Libre2JournalFile.url("ownership.json")) {
        let record = Self.loadRecord(from: fileURL)
        self.init(record: record) { try Libre2JournalFile.save($0, to: fileURL) }
    }

    // MARK: - Phone to Watch

    /// PREPARE freezes the credentials/counter. Repeated PREPARE is safe only for the same payload.
    func prepare(_ session: Libre2WatchSession) throws {
        try session.validate()
        try updateRecord { record in
            guard !record.retiredIDs.contains(session.id) else {
                throw Libre2HandoffError.staleSession
            }
            if record.owner == .preparingWatch, record.session == session {
                return
            }
            guard record.owner == .phone, !nfcActive else {
                throw Libre2HandoffError.invalidTransition
            }

            record.session = session
            record.nfcCredentials = nil
            record.watchMayHaveConnected = false
            record.watchPeripheralID = nil
            record.owner = .preparingWatch
        }
    }

    /// Called on phone after Watch acknowledges PREPARE.
    func beginPhoneRelease(id: UUID) throws {
        try transition(id: id, from: [.preparingWatch], to: .releasingPhone)
    }

    /// Called on Watch when ACTIVATE arrives, after phone disconnects.
    func activateWatch(id: UUID) throws {
        try transition(id: id, from: [.preparingWatch], to: .watch)
    }

    /// Called on phone after Watch acknowledges ACTIVATE.
    func confirmWatchOwnership(id: UUID) throws {
        try transition(id: id, from: [.releasingPhone], to: .watch)
    }

    // MARK: - Watch to phone

    /// Freeze Watch authentication before sending its final counter to the phone.
    func beginReturnToPhone(id: UUID) throws {
        try transition(
            id: id, from: [.watch, .preparingWatch, .returningToPhone], to: .returningToPhone)
    }

    /// Persist cancellation before sending anything; delayed READY/ACTIVATE replies cannot undo it.
    func requestReturnFromWatch(id: UUID) throws {
        try updateRecord { record in
            guard record.session?.id == id, !record.retiredIDs.contains(id) else {
                throw Libre2HandoffError.staleSession
            }
            guard record.owner.canRequestReturn else {
                throw Libre2HandoffError.invalidTransition
            }
            // If M has already been accepted, Watch may be about to send COMMIT.
            // Preserve that phase so another cancel tap cannot invalidate its COMMIT.
            if record.owner != .returningToPhone {
                record.owner = .returnRequested
            }
        }
    }

    /// A cancel may overtake PREPARE. Persist the same session on Watch before returning it.
    func prepareRequestedReturn(_ session: Libre2WatchSession) throws {
        try session.validate()
        try updateRecord { record in
            guard !record.retiredIDs.contains(session.id) else {
                throw Libre2HandoffError.staleSession
            }
            if record.owner == .phone {
                record.session = session
                record.watchMayHaveConnected = false
                record.watchPeripheralID = nil
                record.owner = .preparingWatch
            } else {
                guard let existing = record.session,
                    existing.matchesHandoff(session),
                    existing.unlockCount >= session.unlockCount
                else {
                    throw Libre2HandoffError.staleSession
                }
                guard [.preparingWatch, .watch, .returningToPhone, .releasingWatch].contains(record.owner)
                else {
                    throw Libre2HandoffError.invalidTransition
                }
            }
        }
    }

    /// The phone persists M before it acknowledges RETURN_PREPARE.
    func acceptReturn(_ session: Libre2WatchSession) throws {
        try updateRecord { record in
            guard let existing = record.session,
                existing.matchesHandoff(session),
                !record.retiredIDs.contains(session.id),
                session.unlockCount >= existing.unlockCount
            else {
                throw Libre2HandoffError.staleSession
            }
            guard record.owner.canRequestReturn else {
                throw Libre2HandoffError.invalidTransition
            }

            record.session = session
            record.owner = .returningToPhone
        }
    }

    /// Called on Watch after the phone acknowledges RETURN_PREPARE.
    func beginWatchRelease(id: UUID) throws {
        try transition(id: id, from: [.returningToPhone], to: .releasingWatch)
    }

    func finishReturnOnPhone(id: UUID) throws {
        try finishReturn(id: id, from: [.returningToPhone])
    }

    func finishReturnOnWatch(id: UUID) throws {
        try finishReturn(id: id, from: [.releasingWatch])
    }

    /// A no-op in ordinary upstream mode; persist only counters tied to this experiment.
    func recordPhoneCounter(_ counter: UInt16, sensorUID: Data, unlockCode: UInt32) throws {
        lock.lock()
        defer { lock.unlock() }
        let tracksNFCCredentials =
            record.nfcCredentials?.sensorUID == sensorUID
            && record.nfcCredentials?.unlockCode == unlockCode
        let tracksSession =
            record.session?.sensorUID == sensorUID && record.session?.unlockCode == unlockCode
        guard tracksNFCCredentials || tracksSession else { return }
        try updateRecord { record in
            guard record.owner.allowsPhoneConnection else { throw Libre2HandoffError.invalidTransition }
            if tracksNFCCredentials {
                guard counter >= record.nfcCredentials!.unlockCount else { throw Libre2HandoffError.staleSession }
                record.nfcCredentials?.unlockCount = counter
            }
            if tracksSession {
                guard counter >= record.session!.unlockCount else { throw Libre2HandoffError.staleSession }
                record.session?.unlockCount = counter
            }
        }
    }

    // MARK: - Ordinary NFC reset

    /// An ordinary scan remains available after deletion or an unresolved handoff. Only scans
    /// superseding experimental state require journal writes and a fresh streaming code.
    func beginPhoneNFC(resetUnlockCode: UInt32? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !nfcActive else { throw Libre2HandoffError.invalidTransition }
        if record.hasExperimentalState {
            guard let code = resetUnlockCode, code != 42,
                  code <= UInt32.max - UInt32(UInt16.max),
                  code != record.session?.unlockCode, code != record.nfcCredentials?.unlockCode,
                  code != record.phoneNFCResetCode else { throw Libre2HandoffError.invalidSession }
            try updateRecord { record in
                if let id = record.session?.id { record.retiredIDs.insert(id) }
                // Failed here means a new scan is needed, never permission to reconnect with
                // the old credentials. Cancellation/restart leaves ordinary NFC available.
                record.owner = .failed
                record.session = nil
                record.nfcCredentials = nil
                record.phoneNFCResetCode = code
            }
        }
        confirmedNFCResetCode = nil
        nfcActive = true
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Confirmation is transient: after interruption, another scan must provision the sensor.
    func confirmPhoneNFCReset(unlockCode: UInt32) throws {
        lock.lock()
        defer { lock.unlock() }
        guard nfcActive, record.owner == .failed, record.phoneNFCResetCode == unlockCode else {
            throw Libre2HandoffError.staleSession
        }
        confirmedNFCResetCode = unlockCode
    }

    /// Called after NFC enabled streaming and the previous phone BLE connection closed.
    /// Match this attempt's code so a delayed completion cannot finish a later reset.
    func finishPhoneNFCReset(unlockCode: UInt32, sensorUID: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard nfcActive, record.owner == .failed, record.phoneNFCResetCode == unlockCode,
              confirmedNFCResetCode == unlockCode, sensorUID.count == 8 else {
            throw Libre2HandoffError.staleSession
        }
        try updateRecord { record in
            record.phoneNFCResetCode = nil
            // Keep the newly provisioned credentials so restart and later ordinary scans
            // cannot fall back to a streaming code held by a retired Watch session.
            record.nfcCredentials = Libre2NFCCredentials(
                sensorUID: sensorUID, unlockCode: unlockCode)
            record.owner = .phone
        }
        endPhoneNFC()
    }

    func endPhoneNFC() {
        lock.lock()
        defer { lock.unlock() }
        guard nfcActive else { return }
        nfcActive = false
        confirmedNFCResetCode = nil
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Reconcile the phone's durable retirements even after NFC removed its old credentials.
    /// Only the matching handoff can stop; duplicate delivery after disconnect is a no-op.
    func retireOnWatch(_ ids: Set<UUID>) throws -> Libre2WatchSession? {
        return try updateRecord { record in
            record.retiredIDs.formUnion(ids)
            guard record.owner != .phone, let existing = record.session, ids.contains(existing.id) else {
                return nil
            }
            record.owner = .releasingWatch
            return existing
        }
    }

    // MARK: - Watch Bluetooth persistence

    func rememberWatchPeripheral(_ id: UUID, sessionID: UUID) throws {
        try updateRecord { record in
            guard record.owner == .watch, record.session?.id == sessionID else {
                throw Libre2HandoffError.invalidTransition
            }
            record.watchPeripheralID = id
        }
    }

    /// Keep this ordering visible: reserve and persist first, then attempt the write.
    func attemptUnlock(id: UUID, write: (Libre2WatchSession) throws -> Void) throws {
        let reservedSession = try reserveCounter(id: id)
        try write(reservedSession)
    }

    /// Reservation never rolls back, even when payload generation or writing fails.
    func reserveCounter(id: UUID) throws -> Libre2WatchSession {
        try updateRecord { record in
            guard record.owner.allowsWatchConnection,
                var session = record.session,
                session.id == id
            else {
                throw Libre2HandoffError.invalidTransition
            }
            guard session.unlockCount < UInt16.max else {
                throw Libre2HandoffError.counterExhausted
            }

            session.unlockCount += 1
            record.session = session
            return session
        }
    }

    // MARK: - State transition helpers

    private func transition(id: UUID, from allowedOwners: Set<Libre2Owner>, to owner: Libre2Owner)
        throws
    {
        try updateRecord { record in
            guard record.session?.id == id, !record.retiredIDs.contains(id) else {
                throw Libre2HandoffError.staleSession
            }
            guard allowedOwners.contains(record.owner) else {
                throw Libre2HandoffError.invalidTransition
            }

            record.owner = owner
            if owner == .watch {
                record.watchMayHaveConnected = true
            }
        }
    }

    private func finishReturn(id: UUID, from allowedOwners: Set<Libre2Owner>) throws {
        try updateRecord { record in
            // A lost RETURN_COMMIT reply may cause the already completed transaction to repeat.
            if record.owner == .phone, record.retiredIDs.contains(id) {
                return
            }
            guard record.session?.id == id else {
                throw Libre2HandoffError.staleSession
            }
            guard allowedOwners.contains(record.owner) else {
                throw Libre2HandoffError.invalidTransition
            }

            record.owner = .phone
            record.retiredIDs.insert(id)
        }
    }

    // MARK: - Journal storage

    private func updateRecord<Result>(_ update: (inout Libre2OwnershipRecord) throws -> Result) throws
        -> Result
    {
        lock.lock()
        defer { lock.unlock() }

        let previousRecord = record
        // UI subscribers receive on main, after this locked transaction finishes.
        defer {
            if record != previousRecord {
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
        }
        var updatedRecord = record
        let result = try update(&updatedRecord)
        guard updatedRecord != record else { return result }
        do {
            try persist(updatedRecord)
        } catch {
            record.owner = .failed
            throw Libre2HandoffError.persistence
        }
        record = updatedRecord
        return result
    }

    private static func loadRecord(from fileURL: URL) -> Libre2OwnershipRecord {
        var record = Libre2OwnershipRecord()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return record
        }

        do {
            record = try JSONDecoder().decode(Libre2OwnershipRecord.self, from: Data(contentsOf: fileURL))
            try record.validateRestoredState()
        } catch {
            record.owner = .failed
        }
        return record
    }
}

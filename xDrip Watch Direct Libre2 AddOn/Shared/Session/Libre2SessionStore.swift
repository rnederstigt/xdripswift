import Foundation

/// Persists ownership before allowing any Bluetooth or WatchConnectivity side effect.
/// Phone access spans the Bluetooth and main queues; Watch access stays on main.
final class Libre2SessionStore {

    // MARK: - Properties

    static let shared = Libre2SessionStore()
    static let didChange = Notification.Name("Libre2SessionStoreDidChange")

    private var nfcActive = false

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

    convenience init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let fileURL = applicationSupport.appendingPathComponent(
            "PhoneControlledLibre", isDirectory: true
        ).appendingPathComponent(
            "ownership.json")
        let record = Self.loadRecord(from: fileURL)

        self.init(record: record) { record in
            try Self.saveRecord(record, to: fileURL)
        }
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
            record.reclaim = nil
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
            guard
                [.preparingWatch, .releasingPhone, .watch, .returnRequested, .returningToPhone].contains(
                    record.owner)
            else {
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
            guard
                [.preparingWatch, .watch, .releasingPhone, .returnRequested, .returningToPhone].contains(
                    record.owner)
            else {
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
        let tracksReclaim =
            record.reclaim?.nfcConfirmed == true && record.reclaim?.sensorUID == sensorUID
            && record.reclaim?.unlockCode == unlockCode
        let tracksSession =
            record.session?.sensorUID == sensorUID && record.session?.unlockCode == unlockCode
        guard tracksReclaim || tracksSession else { return }
        try updateRecord { record in
            guard record.owner.allowsPhoneConnection else { throw Libre2HandoffError.invalidTransition }
            if tracksReclaim {
                guard counter >= record.reclaim!.unlockCount else { throw Libre2HandoffError.staleSession }
                record.reclaim?.unlockCount = counter
            }
            if tracksSession {
                guard counter >= record.session!.unlockCount else { throw Libre2HandoffError.staleSession }
                record.session?.unlockCount = counter
            }
        }
    }

    // MARK: - Phone NFC and explicit reclaim

    /// Transient exclusion prevents a transfer from overtaking a normal NFC scan.
    func beginPhoneNFC() throws {
        lock.lock()
        defer { lock.unlock() }
        guard record.owner == .phone, !nfcActive else { throw Libre2HandoffError.invalidTransition }
        nfcActive = true
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func endPhoneNFC() {
        lock.lock()
        defer { lock.unlock() }
        guard nfcActive else { return }
        nfcActive = false
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Reclaim is available even after journal failure. Persist the new code before touching the sensor.
    func beginReclaim(sensorUID: Data, unlockCode: UInt32) throws -> Libre2ReclaimState {
        try updateRecord { record in
            guard !nfcActive, sensorUID.count == 8,
                unlockCode <= UInt32.max - UInt32(UInt16.max),
                unlockCode != record.session?.unlockCode,
                unlockCode != record.reclaim?.unlockCode
            else { throw Libre2HandoffError.invalidSession }
            if let previous = record.session { record.retiredIDs.insert(previous.id) }
            if let session = record.session, (try? session.validate()) == nil { record.session = nil }
            let attempt = Libre2ReclaimState(id: UUID(), sensorUID: sensorUID, unlockCode: unlockCode)
            record.reclaim = attempt
            record.owner = .reclaimingPhone
            return attempt
        }
    }

    func confirmReclaimNFC(id: UUID) throws {
        try updateRecord { record in
            guard record.owner == .reclaimingPhone, record.reclaim?.id == id else {
                throw Libre2HandoffError.staleSession
            }
            record.reclaim?.nfcConfirmed = true
        }
    }

    func beginReclaimVerification(id: UUID) throws {
        try updateRecord { record in
            guard [.reclaimingPhone, .verifyingPhone].contains(record.owner),
                record.reclaim?.id == id, record.reclaim?.nfcConfirmed == true
            else { throw Libre2HandoffError.invalidTransition }
            record.owner = .verifyingPhone
        }
    }

    /// Fresh glucose is accepted only after a new phone login and the NFC/disconnect barrier.
    func confirmReclaimReading(id: UUID) throws {
        try updateRecord { record in
            guard record.owner == .verifyingPhone, record.reclaim?.id == id,
                record.reclaim?.nfcConfirmed == true
            else { throw Libre2HandoffError.invalidTransition }
            record.owner = .phone
        }
    }

    /// A revoke targets one old handoff, so a delayed revoke cannot stop a newer session.
    func revokeOnWatch(_ session: Libre2WatchSession) throws {
        try updateRecord { record in
            guard let existing = record.session, existing.matchesHandoff(session) else {
                throw Libre2HandoffError.staleSession
            }
            record.retiredIDs.insert(session.id)
            record.owner = .releasingWatch
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

    /// A successful phone NFC provisioning starts a new counter sequence.
    func clearCompletedSessionAfterNFC() throws {
        lock.lock()
        defer { lock.unlock() }
        guard record.owner == .phone else { throw Libre2HandoffError.invalidTransition }
        // Ordinary NFC must not acquire a dependency on the experimental journal.
        guard record.session != nil || record.reclaim != nil else { return }
        try updateRecord { record in
            guard record.owner == .phone else {
                throw Libre2HandoffError.invalidTransition
            }
            record.session = nil
            record.reclaim = nil
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
            try record.session?.validate()
            try record.reclaim?.validate()
            if [.reclaimingPhone, .verifyingPhone].contains(record.owner) {
                guard record.reclaim != nil else { throw Libre2HandoffError.invalidSession }
                if record.owner == .verifyingPhone, record.reclaim?.nfcConfirmed != true {
                    throw Libre2HandoffError.invalidSession
                }
            } else if record.owner != .phone && record.owner != .failed && record.session == nil {
                throw Libre2HandoffError.invalidSession
            }
        } catch {
            record.owner = .failed
        }
        return record
    }

    private static func saveRecord(_ record: Libre2OwnershipRecord, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)

        let file = try FileHandle(forWritingTo: fileURL)
        defer { try? file.close() }
        try file.synchronize()
    }
}

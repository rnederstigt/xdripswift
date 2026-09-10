import Foundation
import WatchConnectivity

/// Keeps Direct Libre authentication and freshness tracking out of the original transmitter.
/// BLE callbacks and session preparation run on the transmitter's Bluetooth queue.
final class Libre2PhoneSensorAdapter: Libre2PhoneSensor {
    private weak var transmitter: CGMLibre2Transmitter?
    private let sensorSerial: () -> String?
    private var phoneReadingStatus = Libre2PhoneReadingStatus()
    private var authenticatedThisConnection = false
    private var connectionUnlockCode: UInt32?
    private var ownsNFCScan = false
    private var resetUnlockCode: UInt32?

    init(transmitter: CGMLibre2Transmitter, sensorSerial: @escaping () -> String?) {
        self.transmitter = transmitter
        self.sensorSerial = sensorSerial
    }

    deinit { endNFC() }

    static var hasExperimentalState: Bool { Libre2SessionStore.shared.snapshot.hasExperimentalState }

    static var allowsBluetoothActivity: Bool {
        Libre2SessionStore.shared.snapshot.owner.allowsPhoneConnection
    }

    static func restoreCredentials() {
        // Only the opt-in experiment's returned/reclaimed credentials are restored here.
        let saved = Libre2SessionStore.shared.snapshot
        if let reclaim = saved.reclaim, reclaim.nfcConfirmed,
           reclaim.sensorUID == UserDefaults.standard.libreSensorUID {
            if UserDefaults.standard.libreActiveSensorUnlockCode != reclaim.unlockCode {
                UserDefaults.standard.libreActiveSensorUnlockCount = reclaim.unlockCount
            } else {
                UserDefaults.standard.libreActiveSensorUnlockCount = max(reclaim.unlockCount, UserDefaults.standard.libreActiveSensorUnlockCount)
            }
            UserDefaults.standard.libreActiveSensorUnlockCode = reclaim.unlockCode
        } else if saved.owner == .phone, let returned = saved.session,
                  returned.sensorUID == UserDefaults.standard.libreSensorUID,
                  returned.unlockCode == UserDefaults.standard.libreActiveSensorUnlockCode {
            UserDefaults.standard.libreActiveSensorUnlockCount = max(returned.unlockCount, UserDefaults.standard.libreActiveSensorUnlockCount)
        }
    }

    func attach() {
        DispatchQueue.main.async {
            Libre2PhoneHandoff.shared.sensor = self
            Libre2PhoneHandoff.shared.readingStatus = Libre2PhoneReadingStatus()
        }
    }

    // MARK: - Existing sensor operations

    var isConnected: Bool { transmitter?.getConnectionStatus() == .connected }
    var usesNativeAlgorithm: Bool { transmitter?.isWebOOPEnabled() == true }
    func connect() { transmitter?.connect() }
    func disconnect() { transmitter?.disconnect() }
    func disconnect(completion: @escaping () -> Void) { transmitter?.disconnect(completion: completion) }
    func startBLEScanning() { transmitter?.startBLEScanning() }

    func applyNFCReading(sensorUID: Data, patchInfo: Data, fram: Data) {
        transmitter?.received(sensorUID: sensorUID, patchInfo: patchInfo)
        transmitter?.received(fram: fram)
    }

    func expectedDevice(serialNumber: String, macAddress: String) {
        transmitter?.nfcScanExpectedDevice(serialNumber: serialNumber, macAddress: macAddress)
    }

    // MARK: - BLE authentication and readings

    func connectionStarted() {
        authenticatedThisConnection = false
        connectionUnlockCode = nil
        phoneReadingStatus = Libre2PhoneReadingStatus()
        publishPhoneReadingStatus()
    }

    func connectionChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, Libre2PhoneHandoff.shared.sensor === self else { return }
            Libre2PhoneHandoff.shared.refreshChecklist()
        }
    }

    func prepareUnlock(sensorUID: Data) -> Bool {
        guard UserDefaults.standard.libreActiveSensorUnlockCount < UInt16.max else {
            unlockWasWithheld("counter exhausted at 65535")
            return false
        }
        UserDefaults.standard.libreActiveSensorUnlockCount += 1
        do {
            try Libre2SessionStore.shared.recordPhoneCounter(
                UserDefaults.standard.libreActiveSensorUnlockCount,
                sensorUID: sensorUID, unlockCode: UserDefaults.standard.libreActiveSensorUnlockCode)
        } catch {
            unlockWasWithheld("counter persistence rejected (\(error.localizedDescription))")
            return false
        }
        authenticatedThisConnection = false
        connectionUnlockCode = UserDefaults.standard.libreActiveSensorUnlockCode
        return true
    }

    func didWriteUnlock(error: Error?) {
        guard Self.allowsBluetoothActivity, connectionUnlockCode != nil else { return }
        authenticatedThisConnection = error == nil
        let message = error == nil ? Texts_DirectLibre.phoneLoginWritten : Texts_DirectLibre.phoneLoginWriteFailed
        DispatchQueue.main.async { Libre2ActivityLog.shared.record(message) }
    }

    /// Only real BLE frames reach this hook; test-data replay cannot satisfy the checklist.
    func receivedBLEReading(sensorAge: UInt16) {
        let canTransfer = authenticatedThisConnection
            && sensorAge >= ConstantsLibre2.minimumSensorAgeInMinutes
            && usesNativeAlgorithm && !UserDefaults.standard.suppressUnLockPayLoad
            && Self.allowsBluetoothActivity
        phoneReadingStatus.receivedBLEReading(at: Date(), verifiedUnlockCode: canTransfer ? connectionUnlockCode : nil)
        publishPhoneReadingStatus()
    }

    private func publishPhoneReadingStatus() {
        let snapshot = phoneReadingStatus
        DispatchQueue.main.async { [weak self] in
            guard let self, Libre2PhoneHandoff.shared.sensor === self else { return }
            Libre2PhoneHandoff.shared.didUpdatePhoneReadingStatus(snapshot)
        }
    }

    /// Snapshot and freeze authentication on the same queue as the Libre counter.
    func prepareDirectWatch(completion: @escaping (Result<Libre2WatchSession, Error>) -> Void) {
        guard let transmitter else {
            completion(.failure(Libre2HandoffError.unavailable))
            return
        }
        transmitter.performOnBluetoothQueue {
            do {
                guard Self.allowsBluetoothActivity, self.authenticatedThisConnection,
                      self.connectionUnlockCode == UserDefaults.standard.libreActiveSensorUnlockCode,
                      !Libre2SessionStore.shared.phoneNFCIsActive,
                      self.isConnected,
                      self.phoneReadingStatus.hasRecentVerifiedReading(),
                      !UserDefaults.standard.suppressUnLockPayLoad,
                      self.usesNativeAlgorithm,
                      let sensorUID = UserDefaults.standard.libreSensorUID,
                      let patchInfo = UserDefaults.standard.librePatchInfo,
                      let sensorSerial = self.sensorSerial(),
                      let bluetoothName = transmitter.deviceName,
                      let parameters = UserDefaults.standard.libre1DerivedAlgorithmParameters,
                      parameters.serialNumber == sensorSerial else {
                    throw Libre2HandoffError.unavailable
                }
                let session = Libre2WatchSession(
                    id: UUID(),
                    createdAt: Date(),
                    sensorUID: sensorUID,
                    patchInfo: patchInfo,
                    unlockCode: UserDefaults.standard.libreActiveSensorUnlockCode,
                    unlockCount: UserDefaults.standard.libreActiveSensorUnlockCount,
                    bluetoothName: bluetoothName,
                    sensorSerial: sensorSerial,
                    calibration: Libre2Calibration(parameters)
                )
                try Libre2SessionStore.shared.prepare(session)
                DispatchQueue.main.async { completion(.success(session)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Ordinary NFC lifecycle

    func beginNFC() -> Bool {
        do {
            let store = Libre2SessionStore.shared
            let previous = store.snapshot
            var code: UInt32?
            if previous.hasExperimentalState {
                var candidate = UInt32.random(in: 1...(UInt32.max - UInt32(UInt16.max)))
                while candidate == 42 || candidate == previous.session?.unlockCode || candidate == previous.reclaim?.unlockCode
                    || candidate == previous.phoneNFCResetCode || candidate == UserDefaults.standard.libreActiveSensorUnlockCode {
                    candidate = UInt32.random(in: 1...(UInt32.max - UInt32(UInt16.max)))
                }
                code = candidate
            }
            try store.beginPhoneNFC(resetUnlockCode: code)
            reportAuthentication("NFC started; counter \(UserDefaults.standard.libreActiveSensorUnlockCount); Direct Libre reset: \(code != nil).")
            ownsNFCScan = true
            resetUnlockCode = store.snapshot.phoneNFCResetCode
            if resetUnlockCode != nil {
                DispatchQueue.main.async {
                    Libre2PhoneHandoff.shared.readingStatus = Libre2PhoneReadingStatus()
                    Libre2PhoneHandoff.shared.status = "Direct Libre reset started. Scan the sensor you want to use."
                    if let old = previous.session, WCSession.default.activationState == .activated,
                       let message = try? Libre2HandoffMessage(kind: .revoke, session: old).dictionary {
                        // An unavailable Watch must not block a new sensor. A queued, session-bound
                        // revoke stops its retired collector when WatchConnectivity can deliver it.
                        WCSession.default.transferUserInfo(message)
                    }
                }
            }
            return true
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.transmitter?.bluetoothTransmitterDelegate?.error(message: error.localizedDescription)
                Libre2PhoneHandoff.shared.status = error.localizedDescription
            }
            return false
        }
    }

    var nfcUnlockCode: UInt32 { resetUnlockCode ?? 42 }
    var isNFCResetScan: Bool { ownsNFCScan && resetUnlockCode != nil }

    func didEnableNFCStreaming() -> Bool {
        if let code = resetUnlockCode {
            do {
                guard ownsNFCScan else { throw Libre2HandoffError.staleSession }
                try Libre2SessionStore.shared.confirmPhoneNFCReset(unlockCode: code)
            } catch {
                reportAuthentication("NFC counter reset withheld: \(error.localizedDescription). Counter remains \(UserDefaults.standard.libreActiveSensorUnlockCount).")
                return false
            }
            // Only experimental provisioning replaces the saved unlock code.
            UserDefaults.standard.libreActiveSensorUnlockCode = code
            return true
        }
        guard !Self.hasExperimentalState else {
            reportAuthentication("NFC counter reset withheld: no matching Direct Libre reset attempt. Counter remains \(UserDefaults.standard.libreActiveSensorUnlockCount).")
            return false
        }
        // Ordinary NFC retains the upstream counter reset, without a journal/code write.
        return true
    }

    func didResetNFCCounter(from previous: UInt16) {
        reportAuthentication("NFC counter reset: \(previous) → \(UserDefaults.standard.libreActiveSensorUnlockCount); next BLE unlock will advance the counter.")
    }

    func unlockWasWithheld(_ reason: String) {
        reportAuthentication("Libre unlock withheld: \(reason). Counter \(UserDefaults.standard.libreActiveSensorUnlockCount).")
    }

    private func reportAuthentication(_ message: String) {
        DispatchQueue.main.async { Libre2ActivityLog.shared.record(message, force: true) }
    }

    func endNFC() {
        guard ownsNFCScan else { return }
        ownsNFCScan = false
        resetUnlockCode = nil
        Libre2SessionStore.shared.endPhoneNFC()
    }

    func finishNFCReset(completion: @escaping () -> Void) {
        guard ownsNFCScan, let transmitter, let code = resetUnlockCode,
              let sensorUID = UserDefaults.standard.libreSensorUID else { return }
        transmitter.disconnect { [weak self, weak transmitter] in
            guard let self, let transmitter else { return }
            transmitter.performOnBluetoothQueue {
                guard self.ownsNFCScan, self.resetUnlockCode == code else { return }
                do {
                    self.connectionStarted()
                    try Libre2SessionStore.shared.finishPhoneNFCReset(unlockCode: code, sensorUID: sensorUID)
                    self.endNFC()
                    DispatchQueue.main.async {
                        Libre2PhoneHandoff.shared.status = "Direct Libre reset completed; connecting to the scanned sensor."
                    }
                    completion()
                } catch {
                    self.endNFC()
                    DispatchQueue.main.async { Libre2PhoneHandoff.shared.status = error.localizedDescription }
                }
            }
        }
    }
}

import Foundation

/// Keeps Direct Libre authentication and freshness tracking out of the original transmitter.
/// BLE callbacks and session preparation run on the transmitter's Bluetooth queue.
final class Libre2PhoneSensorAdapter: Libre2PhoneSensor {
    private weak var transmitter: CGMLibre2Transmitter?
    private let sensorSerial: () -> String?
    private var phoneReadingStatus = Libre2PhoneReadingStatus()
    private var authenticatedThisConnection = false
    private var connectionUnlockCode: UInt32?

    init(transmitter: CGMLibre2Transmitter, sensorSerial: @escaping () -> String?) {
        self.transmitter = transmitter
        self.sensorSerial = sensorSerial
    }

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

    func prepareUnlock(sensorUID: Data) -> Bool {
        guard UserDefaults.standard.libreActiveSensorUnlockCount < UInt16.max else { return false }
        UserDefaults.standard.libreActiveSensorUnlockCount += 1
        do {
            try Libre2SessionStore.shared.recordPhoneCounter(
                UserDefaults.standard.libreActiveSensorUnlockCount,
                sensorUID: sensorUID, unlockCode: UserDefaults.standard.libreActiveSensorUnlockCode)
        } catch { return false }
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
            try Libre2SessionStore.shared.beginPhoneNFC()
            return true
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.transmitter?.bluetoothTransmitterDelegate?.error(message: Texts_DirectLibre.usePhoneRecovery)
                Libre2PhoneHandoff.shared.status = Texts_DirectLibre.usePhoneRecovery
            }
            return false
        }
    }

    func didEnableNFCStreaming() -> Bool {
        // Ordinary NFC uses the upstream code. Retire completed experimental credentials.
        do { try Libre2SessionStore.shared.clearCompletedSessionAfterNFC() }
        catch { return false }
        UserDefaults.standard.libreActiveSensorUnlockCode = 42
        return true
    }

    func endNFC() { Libre2SessionStore.shared.endPhoneNFC() }
}

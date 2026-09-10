import CoreNFC
import Foundation

/// Adapts the existing NFC reader for one explicit recovery attempt. Default NFC callers are unchanged.
final class Libre2PhoneReclaim: LibreNFCDelegate {
    private let store = Libre2SessionStore.shared
    private let sensor: Libre2PhoneSensor
    private let attempt: Libre2ReclaimState
    private let status: (String) -> Void
    private let finished: () -> Void
    private var reader: LibreNFC?
    private var patchInfo: Data?
    private var fram: Data?
    private var committed = false

    init(
        sensor: Libre2PhoneSensor, attempt: Libre2ReclaimState,
        status: @escaping (String) -> Void, finished: @escaping () -> Void
    ) {
        self.sensor = sensor
        self.attempt = attempt
        self.status = status
        self.finished = finished
    }

    func start() {
        reader = LibreNFC(libreNFCDelegate: self, unlockCode: attempt.unlockCode, expectedSensorUID: attempt.sensorUID)
        reader?.startSession()
    }

    func received(sensorUID: Data, patchInfo: Data) {
        guard sensorUID == attempt.sensorUID else { return }
        self.patchInfo = patchInfo
    }

    func received(fram: Data) { self.fram = fram }

    func streamingEnabled(successful: Bool) {
        guard successful, let patchInfo, let fram else {
            status(Texts_DirectLibre.reclaimFailed)
            return
        }
        do {
            try store.confirmReclaimNFC(id: attempt.id)
            // Persisted confirmation allows recovery after termination before defaults are updated.
            UserDefaults.standard.libreActiveSensorUnlockCode = attempt.unlockCode
            UserDefaults.standard.libreActiveSensorUnlockCount = 0
            sensor.applyNFCReading(sensorUID: attempt.sensorUID, patchInfo: patchInfo, fram: fram)
            committed = true
            status(Texts_DirectLibre.reclaimVerifying)
        } catch {
            status(Texts_DirectLibre.failed(error.localizedDescription))
        }
    }

    func nfcScanResult(_ result: LibreNFCScanResult) {
        if result != .succeeded || !committed { status(Texts_DirectLibre.reclaimFailed) }
        finished()
    }

    func nfcScanExpectedDevice(serialNumber: String, macAddress: String) {
        guard committed else { return }
        sensor.expectedDevice(serialNumber: serialNumber, macAddress: macAddress)
    }

    func startBLEScanning() {
        guard committed else { return }
        // Do not count buffered readings from the previous phone connection as successful reclaim.
        sensor.disconnect {
            guard self.store.snapshot.reclaim?.id == self.attempt.id,
                self.store.snapshot.owner == .reclaimingPhone
            else { return }
            do {
                try self.store.beginReclaimVerification(id: self.attempt.id)
                self.status(Texts_DirectLibre.reclaimVerifying)
                self.sensor.startBLEScanning()
            } catch { self.status(error.localizedDescription) }
        }
    }
}

import CoreBluetooth
import Foundation

/// CoreBluetooth transport for a durably activated Libre session.
/// All callbacks and handoff actions run on main, so counter reservation and writes stay ordered.
final class Libre2WatchCollector: NSObject {

    // MARK: - Properties

    var onStatus: (String) -> Void = { _ in }
    var onReadings: ([Libre2Sample], UInt16) -> Void = { _, _ in }
    var onCollectedReading: (Libre2Sample, UInt16, Libre2WatchSession) -> Void = { _, _, _ in }

    private let store = Libre2SessionStore.shared
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var receiveCharacteristic: CBCharacteristic?
    private var hasAttemptedUnlock = false

    private var packetAssembler = Libre2FrameAssembler()
    private var parserSessionID: UUID?
    private var parserState = Libre2ParserState()

    private var stopRequested = false
    private var disconnectCompletion: (() -> Void)?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?

    var isConnected: Bool { peripheral?.state == .connected }

    // MARK: - Initialization

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Collection and handoff

    func start() {
        guard store.snapshot.owner.allowsWatchConnection else { return }
        stopRequested = false

        let sessionID = store.snapshot.session?.id
        if parserSessionID != sessionID {
            parserState = Libre2ParserState()
            parserSessionID = sessionID
        }
        guard centralManager.state == .poweredOn else {
            onStatus(Texts_DirectLibre.bluetoothUnavailable)
            return
        }
        guard peripheral == nil else { return }

        onStatus(Texts_DirectLibre.connecting)
        centralManager.scanForPeripherals(withServices: [CBUUID(string: ConstantsLibre2.serviceUUID)])
        scheduleConnectionTimeout()
    }

    /// The completion grants permission to send RETURN_COMMIT; a cancellation request alone does not.
    func stop(completion: @escaping () -> Void) {
        stopRequested = true
        disconnectCompletion = completion
        disconnectWhenBluetoothIsReady()
    }

    private func disconnectWhenBluetoothIsReady() {
        reconnectWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        centralManager.stopScan()

        guard centralManager.state == .poweredOn else {
            onStatus(Texts_DirectLibre.enableBluetoothToReturn)
            return
        }

        // On restart, retrieve the previously saved handle without scanning or authenticating.
        if peripheral == nil, let peripheralID = store.snapshot.watchPeripheralID {
            peripheral = centralManager.retrievePeripherals(withIdentifiers: [peripheralID]).first
            peripheral?.delegate = self
        }
        if let peripheral, peripheral.state != .disconnected {
            centralManager.cancelPeripheralConnection(peripheral)
        } else {
            finishDisconnect()
        }
    }

    private func finishDisconnect() {
        peripheral = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        hasAttemptedUnlock = false
        packetAssembler.reset()

        let completion = disconnectCompletion
        disconnectCompletion = nil
        completion?()
    }

    // MARK: - Connection timeouts and retry

    private func scheduleConnectionTimeout() {
        connectionTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.fail(Texts_DirectLibre.connectionTimedOut)
        }
        connectionTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ConstantsLibre2.connectionTimeout, execute: workItem)
    }

    private func fail(_ status: String) {
        onStatus(status)
        connectionTimeoutWorkItem?.cancel()
        centralManager.stopScan()
        if let peripheral, peripheral.state != .disconnected {
            centralManager.cancelPeripheralConnection(peripheral)
        } else {
            finishDisconnect()
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard store.snapshot.owner.allowsWatchConnection else { return }
        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.start()
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ConstantsLibre2.reconnectDelay, execute: workItem)
    }

    // MARK: - Glucose processing

    private func processFrame(_ frame: Data, session: Libre2WatchSession) {
        do {
            let decryptedData = Data(try Libre2Core.decryptBLE(sensorUID: session.sensorUID, data: frame))
            guard latestGlucoseIsValid(in: decryptedData, calibration: session.calibration) else {
                fail(Texts_DirectLibre.invalidReading)
                return
            }

            let parsedData = Libre2Core.parseBLEData(
                decryptedData,
                libre1DerivedAlgorithmParameters: session.calibration,
                state: &parserState,
                allowsRawFallback: false
            )
            guard parsedData.sensorTimeInMinutes >= ConstantsLibre2.minimumSensorAgeInMinutes else {
                onStatus(Texts_DirectLibre.sensorWarmingUp)
                return
            }
            guard !parsedData.bleGlucose.isEmpty else {
                onStatus(Texts_DirectLibre.noFreshReading)
                return
            }

            connectionTimeoutWorkItem?.cancel()
            onStatus(Texts_DirectLibre.directConnected)
            if let latest = parsedData.bleGlucose.first {
                onCollectedReading(latest, parsedData.sensorTimeInMinutes, session)
            }
            onReadings(displaySamples(from: parsedData.bleGlucose), parsedData.sensorTimeInMinutes)
        } catch {
            onStatus(Texts_DirectLibre.frameAuthenticationFailed)
            packetAssembler.reset()
        }
    }

    /// The shared iOS parser supports raw fallback, but raw values must never reach the Watch display.
    private func latestGlucoseIsValid(in data: Data, calibration: Libre2Calibration) -> Bool {
        let rawGlucose = Libre2Core.readBits(data, 0, 0, 14)
        let rawTemperature = Libre2Core.readBits(data, 0, 14, 12) << 2
        let glucose = calibration.glucose(raw: rawGlucose, temperature: rawTemperature)
        return rawGlucose > 0 && glucose.isFinite && glucose > 0 && glucose < ConstantsLibre2.maximumValidGlucose
    }

    private func displaySamples(from samples: [Libre2Sample]) -> [Libre2Sample] {
        samples.filter { sample in
            sample.glucoseLevelRaw.isFinite && sample.glucoseLevelRaw > 0
                && sample.glucoseLevelRaw < ConstantsLibre2.maximumValidGlucose
        }.map { sample in
            Libre2Sample(timeStamp: sample.timeStamp, glucoseLevelRaw: min(ConstantsLibre2.maximumDisplayGlucose, sample.glucoseLevelRaw))
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension Libre2WatchCollector: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if stopRequested {
            disconnectWhenBluetoothIsReady()
            return
        }
        guard store.snapshot.owner.allowsWatchConnection else { return }
        if central.state == .poweredOn {
            start()
        } else {
            onStatus(Texts_DirectLibre.bluetoothUnavailable)
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        guard store.snapshot.owner.allowsWatchConnection,
            self.peripheral == nil,
            let session = store.snapshot.session
        else {
            return
        }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard advertisedName.caseInsensitiveCompare(session.bluetoothName) == .orderedSame else { return }

        central.stopScan()
        self.peripheral = peripheral
        do {
            try store.rememberWatchPeripheral(peripheral.identifier, sessionID: session.id)
        } catch {
            self.peripheral = nil
            fail(Texts_DirectLibre.identityPersistenceFailed)
            return
        }
        peripheral.delegate = self
        central.connect(peripheral)
        scheduleConnectionTimeout()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard store.snapshot.owner.allowsWatchConnection else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        hasAttemptedUnlock = false
        packetAssembler.reset()
        peripheral.discoverServices([CBUUID(string: ConstantsLibre2.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionTimeoutWorkItem?.cancel()
        finishDisconnect()
        onStatus(Texts_DirectLibre.connectionFailed)
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionTimeoutWorkItem?.cancel()
        let wasReturning = disconnectCompletion != nil
        finishDisconnect()
        if !wasReturning {
            onStatus(Texts_DirectLibre.disconnected)
            scheduleReconnect()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension Libre2WatchCollector: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard store.snapshot.owner.allowsWatchConnection else { return }
        guard error == nil,
            let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: ConstantsLibre2.serviceUUID) })
        else {
            fail(Texts_DirectLibre.serviceMissing)
            return
        }
        let characteristics = [ConstantsLibre2.writeCharacteristicUUID, ConstantsLibre2.receiveCharacteristicUUID].map {
            CBUUID(string: $0)
        }
        peripheral.discoverCharacteristics(characteristics, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard store.snapshot.owner.allowsWatchConnection else { return }
        guard error == nil else {
            fail(Texts_DirectLibre.characteristicDiscoveryFailed)
            return
        }

        writeCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: ConstantsLibre2.writeCharacteristicUUID) }
        receiveCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: ConstantsLibre2.receiveCharacteristicUUID) }
        guard let writeCharacteristic, writeCharacteristic.properties.contains(.write),
            let receiveCharacteristic, receiveCharacteristic.properties.contains(.notify)
        else {
            fail(Texts_DirectLibre.characteristicsMissing)
            return
        }
        guard !hasAttemptedUnlock, let session = store.snapshot.session else { return }
        do {
            try store.attemptUnlock(id: session.id) { reservedSession in
                hasAttemptedUnlock = true
                let payload = Libre2Core.streamingUnlockPayload(
                    sensorUID: reservedSession.sensorUID,
                    info: reservedSession.patchInfo,
                    enableTime: reservedSession.unlockCode,
                    unlockCount: reservedSession.unlockCount
                )
                peripheral.writeValue(Data(payload), for: writeCharacteristic, type: .withResponse)
            }
        } catch {
            fail(Texts_DirectLibre.failed(error.localizedDescription))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard store.snapshot.owner.allowsWatchConnection,
            characteristic.uuid == CBUUID(string: ConstantsLibre2.writeCharacteristicUUID),
            let receiveCharacteristic
        else { return }
        guard error == nil else { fail(Texts_DirectLibre.unlockWriteFailed); return }
        peripheral.setNotifyValue(true, for: receiveCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard store.snapshot.owner.allowsWatchConnection,
            characteristic.uuid == CBUUID(string: ConstantsLibre2.receiveCharacteristicUUID)
        else { return }
        if error != nil || !characteristic.isNotifying { fail(Texts_DirectLibre.subscriptionFailed) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard store.snapshot.owner.allowsWatchConnection, hasAttemptedUnlock,
            characteristic.uuid == CBUUID(string: ConstantsLibre2.receiveCharacteristicUUID), error == nil,
            let value = characteristic.value, let session = store.snapshot.session,
            let frame = packetAssembler.append(value)
        else {
            return
        }
        processFrame(frame, session: session)
    }
}

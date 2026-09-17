import CoreBluetooth
import Foundation

/// CoreBluetooth transport for a durably activated Libre session.
/// All callbacks and handoff actions run on main, so counter reservation and writes stay ordered.
final class Libre2WatchCollector: NSObject {

    /// Transient Bluetooth progress, separate from the persisted handoff transaction.
    enum ConnectionState {
        case inactive, scanning, connecting, restarting, connected, disconnecting, waitingToRetry, bluetoothUnavailable

        var isConnecting: Bool {
            switch self {
            case .scanning, .connecting, .restarting, .waitingToRetry: return true
            default: return false
            }
        }

        var text: String {
            switch self {
            case .inactive: return Texts_DirectLibre.directDisconnected
            case .scanning: return Texts_DirectLibre.scanning
            case .connecting: return Texts_DirectLibre.connecting
            case .restarting: return Texts_DirectLibre.restarting
            case .connected: return Texts_DirectLibre.directConnected
            case .disconnecting: return Texts_DirectLibre.returning
            case .waitingToRetry: return Texts_DirectLibre.waitingToRetry
            case .bluetoothUnavailable: return Texts_DirectLibre.bluetoothUnavailableStatus
            }
        }
    }

    // MARK: - Properties

    var onStatus: (String) -> Void = { _ in }
    var onConnectionChanged: () -> Void = {}
    var onReadings: ([Libre2Sample], UInt16) -> Void = { _, _ in }
    var onCollectedReading: (Libre2Sample, UInt16, Libre2WatchSession) -> Void = { _, _, _ in }

    private let store: Libre2SessionStore
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var receiveCharacteristic: CBCharacteristic?
    private var hasAttemptedUnlock = false
    private var lastReadingAt: Date?
    private var restartRequested = false
    private var scanOnNextAttempt = false
    private var reconnectDelayAfterDisconnect: TimeInterval?

    private var packetAssembler = Libre2FrameAssembler()
    private var parserSessionID: UUID?
    private var parserState = Libre2ParserState()

    private var stopRequested = false
    private var disconnectCompletion: (() -> Void)?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?

    private(set) var connectionState: ConnectionState = .inactive {
        didSet {
            if connectionState != oldValue { onConnectionChanged() }
        }
    }

    // MARK: - Initialization

    init(store: Libre2SessionStore = .shared) {
        self.store = store
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
            scanOnNextAttempt = false
        }
        guard centralManager.state == .poweredOn else {
            connectionState = .bluetoothUnavailable
            onStatus(Texts_DirectLibre.bluetoothUnavailable)
            return
        }
        guard peripheral == nil, !centralManager.isScanning else { return }
        reconnectWorkItem?.cancel()
        reconnectDelayAfterDisconnect = nil
        restartRequested = false

        onStatus(Texts_DirectLibre.connecting)
        if !scanOnNextAttempt, let peripheralID = store.snapshot.watchPeripheralID,
            let savedPeripheral = centralManager.retrievePeripherals(withIdentifiers: [peripheralID]).first {
            // Like the phone, leave a known peripheral's connect request pending while out of range.
            connect(savedPeripheral)
            return
        }
        scanOnNextAttempt = false
        connectionState = .scanning
        centralManager.scanForPeripherals(withServices: [CBUUID(string: ConstantsLibre2.serviceUUID)])
    }

    /// A deliberate double tap restarts even a fresh connection or pending attempt.
    /// Further taps share the cancellation already in progress; automatic recovery is unchanged.
    func restartConnection() {
        guard store.snapshot.owner.allowsWatchConnection, !stopRequested else { return }
        guard centralManager.state == .poweredOn else {
            connectionState = .bluetoothUnavailable
            onStatus(connectionState.text)
            return
        }
        guard !restartRequested else { return }
        restartRequested = true
        connectionState = .restarting
        onStatus(Texts_DirectLibre.retryingConnection)
        reconnectWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        centralManager.stopScan()
        reconnectDelayAfterDisconnect = 0

        if let peripheral, peripheral.state != .disconnected {
            // A protocol failure may already be cancelling this attempt. Its callback
            // will complete the manual restart without a second cancellation request.
            if peripheral.state != .disconnecting {
                centralManager.cancelPeripheralConnection(peripheral)
            }
        } else {
            finishDisconnect()
            scheduleReconnect()
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        centralManager.connect(peripheral)
    }

    /// The completion grants permission to send RETURN_COMMIT; a cancellation request alone does not.
    func stop(completion: @escaping () -> Void) {
        stopRequested = true
        restartRequested = false
        connectionState = .disconnecting
        reconnectDelayAfterDisconnect = nil
        disconnectCompletion = completion
        disconnectWhenBluetoothIsReady()
    }

    private func disconnectWhenBluetoothIsReady() {
        reconnectWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        centralManager.stopScan()

        guard centralManager.state == .poweredOn else {
            connectionState = .bluetoothUnavailable
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
        lastReadingAt = nil
        packetAssembler.reset()

        connectionState = restartRequested ? .restarting : .inactive
        let completion = disconnectCompletion
        disconnectCompletion = nil
        completion?()
    }

    // MARK: - Connection timeouts and retry

    /// Match the phone's five-second limit for a scan-discovered connection only.
    private func scheduleConnectionTimeout() {
        connectionTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.store.snapshot.owner.allowsWatchConnection, !self.stopRequested else { return }
            self.scanOnNextAttempt = true
            self.fail(Texts_DirectLibre.connectionTimedOut, retryDelay: 0)
        }
        connectionTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ConstantsLibre2.connectionTimeout, execute: workItem)
    }

    private func fail(_ status: String, retryDelay: TimeInterval = ConstantsLibre2.reconnectDelay) {
        guard !restartRequested else { return }
        connectionState = .waitingToRetry
        onStatus(status)
        connectionTimeoutWorkItem?.cancel()
        centralManager.stopScan()
        reconnectDelayAfterDisconnect = retryDelay
        if let peripheral, peripheral.state != .disconnected {
            centralManager.cancelPeripheralConnection(peripheral)
        } else {
            finishDisconnect()
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        // Range loss reconnects immediately, as on iPhone. Protocol failures keep a short backoff.
        let delay = reconnectDelayAfterDisconnect ?? 0
        reconnectDelayAfterDisconnect = nil
        guard store.snapshot.owner.allowsWatchConnection, !stopRequested else { return }
        reconnectWorkItem?.cancel()
        connectionState = restartRequested ? .restarting : .waitingToRetry
        let workItem = DispatchWorkItem { [weak self] in
            self?.start()
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - Glucose processing

    private func processFrame(_ frame: Data, session: Libre2WatchSession) {
        do {
            let decryptedData = Data(try Libre2Core.decryptBLE(sensorUID: session.sensorUID, data: frame))
            let parsedData = Libre2Core.parseBLEData(
                decryptedData,
                calibration: session.calibration,
                state: &parserState
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
            lastReadingAt = parsedData.bleGlucose.first?.timeStamp
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
        guard store.snapshot.owner.allowsWatchConnection else {
            // Power changes still affect the indicator while a return is waiting for the phone.
            onConnectionChanged()
            return
        }
        if central.state == .poweredOn {
            start()
        } else {
            connectionTimeoutWorkItem?.cancel()
            reconnectWorkItem?.cancel()
            if central.state == .poweredOff || central.state == .resetting {
                finishDisconnect()
            }
            restartRequested = false
            connectionState = .bluetoothUnavailable
            onStatus(Texts_DirectLibre.bluetoothUnavailable)
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        guard store.snapshot.owner.allowsWatchConnection, !stopRequested, !restartRequested,
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
        connect(peripheral)
        scheduleConnectionTimeout()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard store.snapshot.owner.allowsWatchConnection, !stopRequested,
            self.peripheral === peripheral, reconnectDelayAfterDisconnect == nil
        else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        hasAttemptedUnlock = false
        packetAssembler.reset()
        scanOnNextAttempt = false
        connectionTimeoutWorkItem?.cancel()
        connectionState = .connected
        peripheral.discoverServices([CBUUID(string: ConstantsLibre2.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        connectionTimeoutWorkItem?.cancel()
        finishDisconnect()
        onStatus(Texts_DirectLibre.connectionFailed)
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
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
    private func acceptsEvents(from peripheral: CBPeripheral) -> Bool {
        store.snapshot.owner.allowsWatchConnection && !stopRequested && !restartRequested
            && reconnectDelayAfterDisconnect == nil && self.peripheral === peripheral
            && peripheral.state == .connected
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard acceptsEvents(from: peripheral) else { return }
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
        guard acceptsEvents(from: peripheral) else { return }
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
        // Match CGMLibre2Transmitter: enable F002 notifications before attempting F001.
        peripheral.setNotifyValue(true, for: receiveCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard acceptsEvents(from: peripheral),
            characteristic.uuid == CBUUID(string: ConstantsLibre2.writeCharacteristicUUID)
        else { return }
        guard error == nil else { fail(Texts_DirectLibre.unlockWriteFailed); return }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard acceptsEvents(from: peripheral),
            characteristic.uuid == CBUUID(string: ConstantsLibre2.receiveCharacteristicUUID)
        else { return }
        guard error == nil, characteristic.isNotifying else {
            fail(Texts_DirectLibre.subscriptionFailed)
            return
        }
        guard !hasAttemptedUnlock, let session = store.snapshot.session, let writeCharacteristic else { return }
        do {
            // Subscription is confirmed; persist the next counter before the unlock can reach BLE.
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
            return
        }
        // Like the phone, do not disconnect a subscribed sensor while waiting for glucose.
        if lastReadingAt == nil {
            onStatus(Texts_DirectLibre.waitingForFirstReading)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard acceptsEvents(from: peripheral), hasAttemptedUnlock,
            characteristic.uuid == CBUUID(string: ConstantsLibre2.receiveCharacteristicUUID), error == nil,
            let value = characteristic.value, let session = store.snapshot.session,
            let frame = packetAssembler.append(value)
        else {
            return
        }
        processFrame(frame, session: session)
    }
}

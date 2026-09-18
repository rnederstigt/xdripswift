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
    // Local recovery can scan while cancellation finishes. Keep old handles only so
    // a subsequent ownership return still waits for every requested release.
    private var cancelledPeripherals: [ObjectIdentifier: CBPeripheral] = [:]

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

    // Capture bookkeeping never decides whether to connect, cancel or retry.
    private var attempt = 0
    private var attemptStartedAt: TimeInterval?
    private var resetID: String?
    private var resetStartedAt: TimeInterval?
    private var cancellationReason: String?
    private var notifications = 0
    private var frames = 0
    private var validFrames = 0
    private var rejectedFrames = 0
    private var firstNotificationReceived = false
    private var firstFrameReceived = false
    private var firstReadingReceived = false
    private var summaryAt = ProcessInfo.processInfo.systemUptime

    private var bluetoothState: String {
        switch centralManager.state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "unrecognized"
        }
    }

    private func trace(_ event: @autoclosure () -> String) {
        Libre2DiagnosticCapture.shared.record("BLE: " + event()
            + " attempt=\(attempt) reset=\(resetID ?? "none") state=\(connectionState)"
            + " owner=\(store.snapshot.owner) scan=\(centralManager.isScanning)"
            + " peripheral=\(peripheral.map { String(describing: $0.state) } ?? "none")")
    }

    private func elapsed(since time: TimeInterval?) -> String {
        time.map { String(format: "%.3fs", ProcessInfo.processInfo.systemUptime - $0) } ?? "unknown"
    }

    private func errorDetails(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "error=none" }
        return "error=\(error.domain)/\(error.code) \(error.localizedDescription.prefix(240))"
    }

    private func cancel(_ peripheral: CBPeripheral, using central: CBCentralManager, reason: String) {
        // This records an application request, not a confirmed radio disconnect.
        cancellationReason = reason
        trace("Disconnect requested: " + reason)
        cancelledPeripherals[ObjectIdentifier(peripheral)] = peripheral
        // Only use this connection's characteristic; a late callback may belong to an old handle.
        if self.peripheral === peripheral, let receiveCharacteristic {
            trace("F002 unsubscribe requested")
            peripheral.setNotifyValue(false, for: receiveCharacteristic)
        }
        central.cancelPeripheralConnection(peripheral)
    }

    private func recordFrameSummary() {
        guard notifications > 0 || frames > 0 else { return }
        trace("Frame summary notifications=\(notifications) frames=\(frames) valid=\(validFrames) rejected=\(rejectedFrames)"
            + " lastReadingAge=\(lastReadingAt.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "none")")
        notifications = 0
        frames = 0
        validFrames = 0
        rejectedFrames = 0
        summaryAt = ProcessInfo.processInfo.systemUptime
    }

    func recordCaptureSnapshot() {
        recordFrameSummary()
        trace("Snapshot bluetooth=\(bluetoothState) unlockAttempted=\(hasAttemptedUnlock)"
            + " lastReadingAge=\(lastReadingAt.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "none")")
    }

    // MARK: - Initialization

    init(store: Libre2SessionStore = .shared) {
        self.store = store
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Collection and handoff

    func start() {
        guard store.snapshot.owner.allowsWatchConnection else {
            trace("Start suppressed: ownership")
            return
        }
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
        guard peripheral == nil, !centralManager.isScanning else {
            trace("Start suppressed: existing connection or scan")
            return
        }
        reconnectWorkItem?.cancel()
        restartRequested = false

        onStatus(Texts_DirectLibre.connecting)
        if !scanOnNextAttempt, let peripheralID = store.snapshot.watchPeripheralID,
            let savedPeripheral = centralManager.retrievePeripherals(withIdentifiers: [peripheralID]).first {
            // Like the phone, leave a known peripheral's connect request pending while out of range.
            trace("Using saved peripheral handle")
            connect(savedPeripheral)
            return
        }
        scanOnNextAttempt = false
        connectionState = .scanning
        trace("Scan requested: Libre service")
        centralManager.scanForPeripherals(withServices: [CBUUID(string: ConstantsLibre2.serviceUUID)])
    }

    /// A deliberate double tap restarts even a fresh connection or pending attempt.
    /// Further taps in the same queue turn share the queued restart. Scanning does not
    /// wait for cancellation callbacks; handoff release still does.
    func restartConnection() {
        let tapID = String(UUID().uuidString.prefix(8))
        trace("Double tap requested tap=\(tapID)")
        guard store.snapshot.owner.allowsWatchConnection, !stopRequested else {
            trace("Double tap ignored tap=\(tapID): ownership/stop")
            return
        }
        guard centralManager.state == .poweredOn else {
            connectionState = .bluetoothUnavailable
            onStatus(connectionState.text)
            trace("Double tap ignored tap=\(tapID): Bluetooth unavailable")
            return
        }
        guard !restartRequested else {
            trace("Double tap coalesced tap=\(tapID): restart already queued")
            return
        }
        if resetID != nil { trace("Previous reset superseded by tap=\(tapID)") }
        resetID = tapID
        resetStartedAt = ProcessInfo.processInfo.systemUptime
        trace("Double tap accepted tap=\(tapID)")
        restartRequested = true
        connectionState = .restarting
        onStatus(Texts_DirectLibre.retryingConnection)
        recoverLocally(reason: "Manual reset")
    }

    /// Match the phone's local timeout path: cancel, forget transient connection state,
    /// and resume scanning. Retired callbacks cannot clear a new connecting/connected link.
    private func recoverLocally(reason: String) {
        reconnectWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        centralManager.stopScan()
        cancelledPeripherals = cancelledPeripherals.filter { $0.value.state != .disconnected }
        if let peripheral, peripheral.state != .disconnected {
            cancelledPeripherals[ObjectIdentifier(peripheral)] = peripheral
            if peripheral.state != .disconnecting {
                cancel(peripheral, using: centralManager, reason: reason)
            }
        }
        clearConnection()
        scanOnNextAttempt = true
        scheduleReconnect()
    }

    private func connect(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        attempt += 1
        attemptStartedAt = ProcessInfo.processInfo.systemUptime
        cancellationReason = nil
        trace("Connect requested")
        centralManager.connect(peripheral)
    }

    /// The completion grants permission to send RETURN_COMMIT; a cancellation request alone does not.
    func stop(completion: @escaping () -> Void) {
        trace("Stop requested; pending reset superseded by ownership return/reset")
        resetID = nil
        resetStartedAt = nil
        stopRequested = true
        restartRequested = false
        connectionState = .disconnecting
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
        if let peripheral, peripheral.state != .disconnected, peripheral.state != .disconnecting {
            cancel(peripheral, using: centralManager, reason: "Ownership release")
        }
        finishDisconnect()
    }

    private func clearConnection() {
        recordFrameSummary()
        trace("Local connection state cleared")
        peripheral = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        hasAttemptedUnlock = false
        lastReadingAt = nil
        packetAssembler.reset()
    }

    private func finishDisconnect() {
        cancelledPeripherals = cancelledPeripherals.filter { $0.value.state != .disconnected }
        if disconnectCompletion != nil {
            guard cancelledPeripherals.isEmpty, peripheral == nil || peripheral?.state == .disconnected else { return }
        }
        clearConnection()
        connectionState = restartRequested ? .restarting : .inactive
        let completion = disconnectCompletion
        disconnectCompletion = nil
        completion?()
    }

    /// A callback can be delivered after the same handle has begun a new connection.
    /// The current CoreBluetooth state wins over a queued terminal callback.
    private func acceptDisconnect(_ peripheral: CBPeripheral) -> Bool {
        guard peripheral.state == .disconnected else {
            trace("Ignored old terminal callback: peripheral is \(peripheral.state)")
            return false
        }
        let wasCancelled = cancelledPeripherals.removeValue(forKey: ObjectIdentifier(peripheral)) != nil
        if self.peripheral === peripheral { return true }
        trace(wasCancelled ? "Local cancellation completed while recovery continues" : "Ignored callback from old peripheral")
        if disconnectCompletion != nil { finishDisconnect() }
        return false
    }

    // MARK: - Connection timeouts and retry

    /// Match the phone's five-second limit for a scan-discovered connection only.
    private func scheduleConnectionTimeout() {
        connectionTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.store.snapshot.owner.allowsWatchConnection, !self.stopRequested else { return }
            self.trace("Scan-discovered connection timeout fired")
            self.scanOnNextAttempt = true
            self.cancelAndReconnect(Texts_DirectLibre.connectionTimedOut)
        }
        connectionTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ConstantsLibre2.connectionTimeout, execute: workItem)
    }

    private func cancelAndReconnect(_ status: String) {
        guard !restartRequested else {
            trace("Manual restart already queued")
            return
        }
        trace("Reconnect requested: \(status)")
        connectionState = .waitingToRetry
        onStatus(status)
        recoverLocally(reason: status)
    }

    private func scheduleReconnect(to peripheral: CBPeripheral? = nil) {
        // Like the phone, request reconnection without a deliberate backoff.
        guard store.snapshot.owner.allowsWatchConnection, !stopRequested else {
            trace("Retry suppressed: ownership/stop")
            return
        }
        trace("Retry scheduled without delay")
        reconnectWorkItem?.cancel()
        connectionState = restartRequested ? .restarting : .waitingToRetry
        let sessionID = store.snapshot.session?.id
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.store.snapshot.owner.allowsWatchConnection, !self.stopRequested else { return }
            self.trace("Retry executed")
            if let peripheral, self.store.snapshot.session?.id == sessionID,
                self.centralManager.state == .poweredOn, self.peripheral == nil,
                !self.centralManager.isScanning, !self.scanOnNextAttempt {
                // Normal disconnect/failure: reuse the callback's handle, as the phone does.
                self.trace("Reusing peripheral handle")
                self.onStatus(Texts_DirectLibre.connecting)
                self.connect(peripheral)
            } else {
                self.start()
            }
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now(), execute: workItem)
    }

    // MARK: - Glucose processing

    private func processFrame(_ frame: Data, session: Libre2WatchSession) {
        frames += 1
        if !firstFrameReceived {
            trace("First assembled 46-byte frame")
            firstFrameReceived = true
        }
        defer {
            if ProcessInfo.processInfo.systemUptime - summaryAt >= 60 { recordFrameSummary() }
        }
        do {
            let decryptedData = Data(try Libre2Core.decryptBLE(sensorUID: session.sensorUID, data: frame))
            let parsedData = Libre2Core.parseBLEData(
                decryptedData,
                calibration: session.calibration,
                state: &parserState
            )
            guard parsedData.sensorTimeInMinutes >= ConstantsLibre2.minimumSensorAgeInMinutes else {
                rejectedFrames += 1
                onStatus(Texts_DirectLibre.sensorWarmingUp)
                return
            }
            guard !parsedData.bleGlucose.isEmpty else {
                rejectedFrames += 1
                onStatus(Texts_DirectLibre.noFreshReading)
                return
            }

            validFrames += 1
            if !firstReadingReceived {
                trace("First valid reading connectElapsed=\(elapsed(since: attemptStartedAt)) resetElapsed=\(elapsed(since: resetStartedAt))")
                firstReadingReceived = true
                resetID = nil
                resetStartedAt = nil
            }
            connectionTimeoutWorkItem?.cancel()
            lastReadingAt = parsedData.bleGlucose.first?.timeStamp
            onStatus(Texts_DirectLibre.directConnected)
            if let latest = parsedData.bleGlucose.first {
                onCollectedReading(latest, parsedData.sensorTimeInMinutes, session)
            }
            onReadings(displaySamples(from: parsedData.bleGlucose), parsedData.sensorTimeInMinutes)
        } catch {
            rejectedFrames += 1
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
        trace("Bluetooth state changed: \(bluetoothState)")
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
                cancelledPeripherals.removeAll()
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

        guard peripheral.state == .disconnected else {
            trace("Advertisement ignored: peripheral is still \(peripheral.state)")
            return
        }
        cancelledPeripherals.removeValue(forKey: ObjectIdentifier(peripheral))
        trace("Matching advertisement discovered RSSI=\(RSSI)")
        central.stopScan()
        self.peripheral = peripheral
        do {
            try store.rememberWatchPeripheral(peripheral.identifier, sessionID: session.id)
        } catch {
            self.peripheral = nil
            cancelAndReconnect(Texts_DirectLibre.identityPersistenceFailed)
            return
        }
        connect(peripheral)
        scheduleConnectionTimeout()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.state == .connected else {
            trace("Ignored old connected callback")
            return
        }
        if self.peripheral === peripheral, connectionState == .connected {
            trace("Ignored duplicate connected callback")
            return
        }
        trace("Connected callback elapsed=\(elapsed(since: attemptStartedAt)) resetElapsed=\(elapsed(since: resetStartedAt))")
        guard store.snapshot.owner.allowsWatchConnection, !stopRequested,
            self.peripheral === peripheral, connectionState == .connecting
        else {
            cancel(peripheral, using: central, reason: "Late/unwanted connection callback")
            return
        }
        recordFrameSummary()
        firstNotificationReceived = false
        firstFrameReceived = false
        firstReadingReceived = false
        summaryAt = ProcessInfo.processInfo.systemUptime
        hasAttemptedUnlock = false
        packetAssembler.reset()
        scanOnNextAttempt = false
        connectionTimeoutWorkItem?.cancel()
        connectionState = .connected
        trace("Service discovery requested")
        peripheral.discoverServices([CBUUID(string: ConstantsLibre2.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard acceptDisconnect(peripheral) else { return }
        trace("Connection failed elapsed=\(elapsed(since: attemptStartedAt)) \(errorDetails(error))")
        connectionTimeoutWorkItem?.cancel()
        finishDisconnect()
        onStatus(Texts_DirectLibre.connectionFailed)
        scheduleReconnect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard acceptDisconnect(peripheral) else { return }
        trace("Disconnected callback requestedReason=\(cancellationReason ?? "none; unexpected") \(errorDetails(error))"
            + " lastReadingAge=\(lastReadingAt.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "none")")
        connectionTimeoutWorkItem?.cancel()
        let wasReturning = disconnectCompletion != nil
        finishDisconnect()
        if !wasReturning {
            onStatus(Texts_DirectLibre.disconnected)
            scheduleReconnect(to: peripheral)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension Libre2WatchCollector: CBPeripheralDelegate {
    private func acceptsEvents(from peripheral: CBPeripheral) -> Bool {
        store.snapshot.owner.allowsWatchConnection && !stopRequested && !restartRequested
            && connectionState == .connected && self.peripheral === peripheral
            && peripheral.state == .connected
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard acceptsEvents(from: peripheral) else { return }
        trace("Service discovery callback \(errorDetails(error))")
        if let error { onStatus(Texts_DirectLibre.failed(error.localizedDescription)) }
        // Match BluetoothTransmitter: use returned services even alongside an error.
        // Only a nil list disconnects; an empty list leaves the Bluetooth link connected.
        guard let services = peripheral.services else {
            onStatus(Texts_DirectLibre.serviceMissing)
            connectionState = .waitingToRetry
            // As on the phone, keep the handle until its disconnect callback starts reconnection.
            cancel(peripheral, using: centralManager, reason: Texts_DirectLibre.serviceMissing)
            return
        }
        if services.isEmpty { onStatus(Texts_DirectLibre.serviceMissing) }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard acceptsEvents(from: peripheral) else { return }
        trace("Characteristic discovery callback \(errorDetails(error))")
        if error != nil { onStatus(Texts_DirectLibre.characteristicDiscoveryFailed) }
        guard let characteristics = service.characteristics else {
            onStatus(Texts_DirectLibre.characteristicsMissing)
            return
        }
        // The phone uses whichever characteristics were returned. Setup errors do not
        // themselves cancel the link; a later disconnect or double tap runs setup again.
        for characteristic in characteristics {
            if characteristic.uuid == CBUUID(string: ConstantsLibre2.writeCharacteristicUUID) {
                writeCharacteristic = characteristic
            }
            if characteristic.uuid == CBUUID(string: ConstantsLibre2.receiveCharacteristicUUID) {
                receiveCharacteristic = characteristic
                trace("F002 subscription requested")
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        if writeCharacteristic == nil || receiveCharacteristic == nil {
            onStatus(Texts_DirectLibre.characteristicsMissing)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard acceptsEvents(from: peripheral),
            characteristic.uuid == CBUUID(string: ConstantsLibre2.writeCharacteristicUUID)
        else { return }
        trace("F001 write acknowledgement \(errorDetails(error)); acknowledgement is not glucose")
        if error != nil { onStatus(Texts_DirectLibre.unlockWriteFailed) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard acceptsEvents(from: peripheral),
            characteristic.uuid == CBUUID(string: ConstantsLibre2.receiveCharacteristicUUID)
        else { return }
        trace("F002 subscription callback notifying=\(characteristic.isNotifying) \(errorDetails(error))")
        guard error == nil, characteristic.isNotifying else {
            onStatus(Texts_DirectLibre.subscriptionFailed)
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
                trace("Unlock counter persisted; F001 write requested")
                peripheral.writeValue(Data(payload), for: writeCharacteristic, type: .withResponse)
            }
        } catch {
            cancelAndReconnect(Texts_DirectLibre.failed(error.localizedDescription))
            return
        }
        // Like the phone, do not disconnect a subscribed sensor while waiting for glucose.
        if lastReadingAt == nil {
            onStatus(Texts_DirectLibre.waitingForFirstReading)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if acceptsEvents(from: peripheral), hasAttemptedUnlock,
            characteristic.uuid == CBUUID(string: ConstantsLibre2.receiveCharacteristicUUID) {
            notifications += 1
            if !firstNotificationReceived {
                trace("First F002 notification \(errorDetails(error))")
                firstNotificationReceived = true
            }
            if error != nil { trace("F002 notification error \(errorDetails(error))") }
        }
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

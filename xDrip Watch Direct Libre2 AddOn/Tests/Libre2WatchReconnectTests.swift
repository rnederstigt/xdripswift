// Run with Scripts/run_tests.py switching; excluded from the ordinary SwiftPM test module.
#if LIBRE2_RECONNECT_TESTS
import Foundation

// These doubles expose only the CoreBluetooth API used by the production collector.
// Delegate events are delivered explicitly so cancellation never implies a confirmed disconnect.
protocol CBCentralManagerDelegate: AnyObject {}
protocol CBPeripheralDelegate: AnyObject {}
enum CBManagerState { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
enum CBPeripheralState { case disconnected, connecting, connected, disconnecting }
enum CBCharacteristicWriteType { case withResponse }
let CBAdvertisementDataLocalNameKey = "localName"
struct CBUUID: Equatable { let string: String }
struct CBCharacteristicProperties: OptionSet {
    let rawValue: Int
    static let write = Self(rawValue: 1)
    static let notify = Self(rawValue: 2)
}
final class CBCharacteristic {
    let uuid: CBUUID
    let properties: CBCharacteristicProperties = [.write, .notify]
    var isNotifying = false
    var value: Data?
    init(_ uuid: String) { self.uuid = CBUUID(string: uuid) }
}
final class CBService {
    let uuid = CBUUID(string: "FDE3")
    var characteristics: [CBCharacteristic]?
}
final class CBPeripheral {
    let identifier = UUID()
    let name: String? = "ABBOTT123456789"
    var state = CBPeripheralState.disconnected
    weak var delegate: CBPeripheralDelegate?
    var services: [CBService]?
    var writes: [Data] = []
    var notificationRequests = 0
    var bluetoothEvents: [String] = []
    var characteristicDiscoveries = 0
    var onWrite: () -> Void = {}
    func discoverServices(_ services: [CBUUID]) {}
    func discoverCharacteristics(_ characteristics: [CBUUID]?, for service: CBService) { characteristicDiscoveries += 1 }
    func writeValue(_ value: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        onWrite()
        writes.append(value)
    }
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        notificationRequests += 1
        bluetoothEvents.append(enabled ? "subscribe" : "unsubscribe")
    }
}
final class CBCentralManager {
    static var latest: CBCentralManager!
    var state = CBManagerState.poweredOn
    var isScanning = false
    var scans = 0
    var connections = 0
    var cancellations = 0
    var retrievals = 0
    var lastConnectedPeripheral: CBPeripheral?
    var known: [CBPeripheral] = []
    init(delegate: CBCentralManagerDelegate, queue: DispatchQueue) { Self.latest = self }
    func scanForPeripherals(withServices services: [CBUUID]) { isScanning = true; scans += 1 }
    func stopScan() { isScanning = false }
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral] {
        retrievals += 1
        return known.filter { identifiers.contains($0.identifier) }
    }
    func connect(_ peripheral: CBPeripheral) {
        connections += 1
        lastConnectedPeripheral = peripheral
        peripheral.state = .connecting
    }
    func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        cancellations += 1
        peripheral.bluetoothEvents.append("cancel")
        peripheral.state = .disconnecting
    }
}

// A virtual main queue runs the production collector's one-shot work items without sleeping.
final class DispatchWorkItem {
    let action: () -> Void
    var cancelled = false
    init(block: @escaping () -> Void) { action = block }
    func cancel() { cancelled = true }
}
struct DispatchTime {
    let seconds: Double
    static func now() -> Self { Self(seconds: DispatchQueue.main.now) }
    static func + (lhs: Self, rhs: Double) -> Self { Self(seconds: lhs.seconds + rhs) }
}
final class DispatchQueue {
    static let main = DispatchQueue()
    var now: Double = 0
    var pending: [(DispatchTime, DispatchWorkItem)] = []
    func asyncAfter(deadline: DispatchTime, execute work: DispatchWorkItem) { pending.append((deadline, work)) }
    func reset() { now = 0; pending = [] }
    func advance(_ seconds: Double) {
        let end = now + seconds
        while let next = pending.enumerated().filter({ $0.element.0.seconds <= end })
            .min(by: { $0.element.0.seconds < $1.element.0.seconds }) {
            pending.remove(at: next.offset)
            now = next.element.0.seconds
            if !next.element.1.cancelled { next.element.1.action() }
        }
        now = end
    }
}

private func data(_ hex: String) -> Data {
    let bytes = Array(hex)
    return Data(stride(from: 0, to: bytes.count, by: 2).map { UInt8(String(bytes[$0...$0 + 1]), radix: 16)! })
}

private final class Fixture {
    let peripheral = CBPeripheral()
    let write = CBCharacteristic("F001")
    let receive = CBCharacteristic("F002")
    let service = CBService()
    let store: Libre2SessionStore
    let collector: Libre2WatchCollector
    let central: CBCentralManager
    var disk: Libre2OwnershipRecord
    var readings = 0
    var failPersistence = false

    init(owner: Libre2Owner = .watch, saved: Bool = false) {
        DispatchQueue.main.reset()
        let session = Libre2WatchSession(
            id: UUID(), createdAt: Date(), sensorUID: data("e3a18e0100a407e0"),
            patchInfo: data("9d0830017317"), unlockCode: 42, unlockCount: 17,
            bluetoothName: "ABBOTT123456789", sensorSerial: "123456789",
            calibration: Libre2Calibration(slopeSlope: 0, offsetSlope: 0.1, slopeOffset: 0,
                offsetOffset: 0, extraSlope: 1, extraOffset: 0))
        disk = Libre2OwnershipRecord(owner: owner, session: session,
            watchPeripheralID: saved ? peripheral.identifier : nil)
        // The real journal writer is injected; the probe never touches application support files.
        var writer: ((Libre2OwnershipRecord) throws -> Void)?
        store = Libre2SessionStore(record: disk) { try writer?($0) }
        collector = Libre2WatchCollector(store: store)
        central = CBCentralManager.latest
        central.known = [peripheral]
        service.characteristics = [write, receive]
        peripheral.services = [service]
        writer = { [unowned self] record in
            if self.failPersistence { throw Libre2HandoffError.persistence }
            self.disk = record
        }
        peripheral.onWrite = { [unowned self] in
            precondition(self.receive.isNotifying, "F002 subscription must be confirmed before F001")
            precondition(self.disk.session!.unlockCount == UInt16(18 + self.peripheral.writes.count),
                "Counter must reach persistent storage before every F001 write")
        }
        collector.onReadings = { [unowned self] _, _ in self.readings += 1 }
    }

    func discover() {
        collector.centralManager(central, didDiscover: peripheral,
            advertisementData: [CBAdvertisementDataLocalNameKey: peripheral.name!], rssi: -50)
    }
    func connect() {
        peripheral.state = .connected
        collector.centralManager(central, didConnect: peripheral)
    }
    func subscribe() {
        collector.peripheral(peripheral, didDiscoverServices: nil)
        collector.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)
        receive.isNotifying = true
        collector.peripheral(peripheral, didUpdateNotificationStateFor: receive, error: nil)
        collector.peripheral(peripheral, didWriteValueFor: write, error: nil)
    }
    func disconnect() {
        peripheral.state = .disconnected
        collector.centralManager(central, didDisconnectPeripheral: peripheral, error: nil)
    }
    func deliverReading(_ frame: Data = data("ebb86eb952942ce055278df46b68ba1eacd3c78c7e800ea3890c61116679c2a3fcc220a95571ff760207682942f0")) {
        // Existing upstream encrypted fixture; actual assembly, crypto and native parsing run here.
        for range in [0..<20, 20..<40, 40..<46] {
            receive.value = frame.subdata(in: range)
            collector.peripheral(peripheral, didUpdateValueFor: receive, error: nil)
        }
    }
    func startReceiving() { collector.start(); discover(); connect(); subscribe(); deliverReading() }
}

@main
private enum ReconnectTests {
    static func main() throws {
        let captureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        Libre2DiagnosticCapture.shared = Libre2DiagnosticCapture(directory: captureDirectory)
        let cases: [(String, () throws -> Void)] = [
            ("Capture follows accepted/coalesced reset through disconnect and first valid reading", {
                let capture = Libre2DiagnosticCapture.shared
                let id = UUID()
                try capture.start(id: id)
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect(); f.subscribe()
                f.collector.restartConnection()
                f.collector.restartConnection()
                DispatchQueue.main.advance(0)
                precondition(f.central.isScanning && f.peripheral.state == .disconnecting)
                f.disconnect(); f.discover()
                f.connect(); f.subscribe(); f.deliverReading()
                f.collector.recordCaptureSnapshot()
                try capture.stop(id: id)
                let text = String(data: try capture.chunk(id: id, offset: 0), encoding: .utf8)!
                let milestones = ["Double tap requested", "Double tap accepted", "Disconnect requested: Manual reset",
                    "Double tap coalesced", "Retry executed", "Local cancellation completed while recovery continues"]
                var remaining = text[...]
                for milestone in milestones {
                    guard let range = remaining.range(of: milestone) else { preconditionFailure("Missing/order: " + milestone) }
                    remaining = remaining[range.upperBound...]
                }
                precondition(remaining.contains("First valid reading"))
                precondition(text.contains("Unlock counter persisted; F001 write requested"))
                precondition(text.contains("F001 write acknowledgement"))
                precondition(text.contains("Frame summary"))
                precondition(f.disk.session!.unlockCount == 19 && f.central.cancellations == 1)
            }),
            ("Capture records ignored resets and Bluetooth error without changing recovery", {
                let capture = Libre2DiagnosticCapture.shared
                let id = UUID()
                try capture.start(id: id)
                let blocked = Fixture(owner: .phone)
                blocked.collector.restartConnection()
                let f = Fixture()
                f.startReceiving()
                f.peripheral.state = .disconnected
                f.collector.centralManager(f.central, didDisconnectPeripheral: f.peripheral,
                    error: NSError(domain: "CBErrorDomain", code: 6))
                DispatchQueue.main.advance(0)
                try capture.stop(id: id)
                let text = String(data: try capture.chunk(id: id, offset: 0), encoding: .utf8)!
                precondition(text.contains("Double tap ignored"))
                precondition(text.contains("none; unexpected") && text.contains("CBErrorDomain/6"))
                precondition(blocked.central.connections == 0 && f.central.connections == 2)
            }),
            ("Notification confirmation precedes counter persistence and a single unlock write", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect()
                f.collector.peripheral(f.peripheral, didDiscoverCharacteristicsFor: f.service, error: nil)
                precondition(f.peripheral.notificationRequests == 1 && f.peripheral.writes.isEmpty)
                precondition(f.disk.session!.unlockCount == 17)
                f.deliverReading()
                precondition(f.readings == 0)
                f.receive.isNotifying = true
                f.collector.peripheral(f.peripheral, didUpdateNotificationStateFor: f.receive, error: nil)
                precondition(f.disk.session!.unlockCount == 18 && f.peripheral.writes.count == 1)
                // A reading can arrive before the write acknowledgement; notifications are already ready.
                f.deliverReading()
                precondition(f.readings == 1)
                f.collector.peripheral(f.peripheral, didWriteValueFor: f.write, error: nil)
                f.collector.peripheral(f.peripheral, didUpdateNotificationStateFor: f.receive, error: nil)
                precondition(f.peripheral.notificationRequests == 1 && f.peripheral.writes.count == 1)
            }),
            ("Failed or inactive subscription never consumes an unlock counter", {
                for error in [nil, Libre2HandoffError.invalidSession] {
                    let f = Fixture()
                    f.collector.start(); f.discover(); f.connect()
                    f.collector.peripheral(f.peripheral, didDiscoverCharacteristicsFor: f.service, error: nil)
                    f.receive.isNotifying = error != nil
                    f.collector.peripheral(f.peripheral, didUpdateNotificationStateFor: f.receive, error: error)
                    precondition(f.peripheral.writes.isEmpty && f.disk.session!.unlockCount == 17)
                    DispatchQueue.main.advance(300)
                    precondition(f.central.cancellations == 0 && f.central.connections == 1)
                    precondition(f.collector.connectionState == .connected)
                }
            }),
            ("Return during subscription prevents a late notification callback from unlocking", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect()
                f.collector.peripheral(f.peripheral, didDiscoverCharacteristicsFor: f.service, error: nil)
                try f.store.beginReturnToPhone(id: f.disk.session!.id)
                f.collector.stop {}
                f.receive.isNotifying = true
                f.collector.peripheral(f.peripheral, didUpdateNotificationStateFor: f.receive, error: nil)
                precondition(f.peripheral.writes.isEmpty && f.disk.session!.unlockCount == 17)
            }),
            ("Failed unlock acknowledgement keeps the link and counter until an actual disconnect", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect(); f.subscribe()
                f.collector.peripheral(f.peripheral, didWriteValueFor: f.write, error: Libre2HandoffError.invalidSession)
                DispatchQueue.main.advance(300)
                precondition(f.central.cancellations == 0 && f.central.connections == 1)
                precondition(f.collector.connectionState == .connected && f.disk.session!.unlockCount == 18)
                precondition(f.peripheral.writes.count == 1)
                f.disconnect(); DispatchQueue.main.advance(0)
                f.connect(); f.subscribe()
                precondition(f.disk.session!.unlockCount == 19 && f.peripheral.writes.count == 2)
            }),
            ("Service errors use available results; only a nil list disconnects as on phone", {
                for error in [nil, Libre2HandoffError.invalidSession] {
                    let available = Fixture()
                    available.collector.start(); available.discover(); available.connect()
                    available.collector.peripheral(available.peripheral, didDiscoverServices: error)
                    precondition(available.peripheral.characteristicDiscoveries == 1)
                    precondition(available.central.cancellations == 0 && available.collector.connectionState == .connected)
                    let empty = Fixture()
                    empty.collector.start(); empty.discover(); empty.connect()
                    empty.peripheral.services = []
                    empty.collector.peripheral(empty.peripheral, didDiscoverServices: error)
                    DispatchQueue.main.advance(300)
                    precondition(empty.peripheral.characteristicDiscoveries == 0 && empty.central.cancellations == 0)
                    precondition(empty.collector.connectionState == .connected && empty.central.connections == 1)
                    let missing = Fixture()
                    missing.collector.start(); missing.discover(); missing.connect()
                    missing.peripheral.services = nil
                    missing.collector.peripheral(missing.peripheral, didDiscoverServices: error)
                    precondition(missing.central.cancellations == 1 && missing.central.connections == 1)
                    DispatchQueue.main.advance(60)
                    precondition(missing.central.scans == 1 && !missing.central.isScanning)
                    precondition(missing.central.connections == 1 && missing.collector.connectionState == .waitingToRetry)
                    precondition(missing.peripheral.bluetoothEvents == ["cancel"])
                    let retrievals = missing.central.retrievals
                    missing.central.known = []
                    missing.disconnect(); DispatchQueue.main.advance(0)
                    precondition(missing.central.connections == 2 && missing.central.scans == 1)
                    precondition(missing.central.retrievals == retrievals && missing.central.lastConnectedPeripheral === missing.peripheral)
                    missing.peripheral.services = [missing.service]
                    missing.connect(); missing.subscribe(); missing.deliverReading()
                    precondition(missing.readings == 1 && missing.disk.session!.unlockCount == 18)
                }
            }),
            ("Connected cancellation unsubscribes before cancelling for reset, return and missing services", {
                for reason in ["reset", "return", "services"] {
                    let f = Fixture()
                    f.startReceiving()
                    var returned = false
                    switch reason {
                    case "reset": f.collector.restartConnection()
                    case "return":
                        try f.store.beginReturnToPhone(id: f.disk.session!.id)
                        f.collector.stop { returned = true }
                    default:
                        f.peripheral.services = nil
                        f.collector.peripheral(f.peripheral, didDiscoverServices: nil)
                    }
                    precondition(f.peripheral.bluetoothEvents == ["subscribe", "unsubscribe", "cancel"])
                    // A queued notification callback must not unlock again while cancellation is pending.
                    f.peripheral.state = .connected
                    f.collector.peripheral(f.peripheral, didUpdateNotificationStateFor: f.receive, error: nil)
                    precondition(f.disk.session!.unlockCount == 18 && f.peripheral.writes.count == 1)
                    precondition(!returned)
                    f.disconnect(); DispatchQueue.main.advance(0)
                    if reason == "return" { precondition(returned && f.central.connections == 1) }
                }
            }),
            ("Phone return supersedes missing-service recovery without reconnecting or cancelling twice", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect()
                f.peripheral.services = nil
                f.collector.peripheral(f.peripheral, didDiscoverServices: nil)
                try f.store.beginReturnToPhone(id: f.disk.session!.id)
                var returned = false
                f.collector.stop { returned = true }
                precondition(!returned && f.central.cancellations == 1)
                f.disconnect(); DispatchQueue.main.advance(60)
                precondition(returned && f.central.connections == 1 && f.central.scans == 1)
            }),
            ("Characteristic errors do not discard available channels or restart the link", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect()
                f.collector.peripheral(f.peripheral, didDiscoverCharacteristicsFor: f.service,
                    error: Libre2HandoffError.invalidSession)
                precondition(f.peripheral.notificationRequests == 1)
                f.receive.isNotifying = true
                f.collector.peripheral(f.peripheral, didUpdateNotificationStateFor: f.receive, error: nil)
                f.deliverReading()
                precondition(f.readings == 1 && f.disk.session!.unlockCount == 18)
                precondition(f.central.cancellations == 0 && f.collector.connectionState == .connected)
            }),
            ("Missing characteristics stay connected without automatic retries or unsafe unlocks", {
                for variant in 0..<4 {
                    let f = Fixture()
                    f.collector.start(); f.discover(); f.connect()
                    switch variant {
                    case 0: f.service.characteristics = nil
                    case 1: f.service.characteristics = []
                    case 2: f.service.characteristics = [f.write]
                    default: f.service.characteristics = [f.receive]
                    }
                    f.collector.peripheral(f.peripheral, didDiscoverCharacteristicsFor: f.service,
                        error: Libre2HandoffError.invalidSession)
                    if variant == 3 {
                        f.receive.isNotifying = true
                        f.collector.peripheral(f.peripheral, didUpdateNotificationStateFor: f.receive, error: nil)
                    }
                    DispatchQueue.main.advance(300)
                    precondition(f.collector.connectionState == .connected && f.central.cancellations == 0)
                    precondition(f.central.connections == 1 && f.peripheral.writes.isEmpty && f.disk.session!.unlockCount == 17)
                    precondition(f.peripheral.notificationRequests == (variant == 3 ? 1 : 0))
                }
            }),
            ("Double tap recovers a subscription failure with the first reserved counter", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect()
                f.collector.peripheral(f.peripheral, didDiscoverCharacteristicsFor: f.service, error: nil)
                f.collector.peripheral(f.peripheral, didUpdateNotificationStateFor: f.receive,
                    error: Libre2HandoffError.invalidSession)
                precondition(f.collector.connectionState == .connected && f.disk.session!.unlockCount == 17)
                f.collector.restartConnection()
                precondition(f.central.cancellations == 1)
                f.disconnect(); DispatchQueue.main.advance(0); f.discover()
                f.connect(); f.subscribe(); f.deliverReading()
                precondition(f.readings == 1 && f.disk.session!.unlockCount == 18 && f.central.connections == 2)
            }),
            ("Invalid decoded glucose is discarded and the next valid frame uses the same connection", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect(); f.subscribe()
                // Upstream fixture with its first 14 glucose bits zeroed and CRC recomputed.
                let invalid = data("ebb8e6bb52942ce055278df46b68ba1eacd3c78c7e800ea3890c61116679c2a3fcc220a95571ff76020768298167")
                let decoded = Data(try Libre2Core.decryptBLE(sensorUID: f.disk.session!.sensorUID, data: invalid))
                precondition(Libre2Core.readBits(decoded, 0, 0, 14) == 0)
                f.deliverReading(invalid)
                DispatchQueue.main.advance(300)
                precondition(f.readings == 0 && f.central.cancellations == 0 && f.collector.connectionState == .connected)
                f.deliverReading()
                precondition(f.readings == 1 && f.disk.session!.unlockCount == 18 && f.peripheral.writes.count == 1)
            }),
            ("Manual restart cancels a scan and coalesces taps until the new attempt", {
                let f = Fixture()
                f.collector.start()
                precondition(f.collector.connectionState == .scanning)
                DispatchQueue.main.advance(300)
                precondition(f.central.scans == 1 && f.central.isScanning)
                f.collector.restartConnection()
                f.collector.restartConnection()
                precondition(f.collector.connectionState == .restarting && !f.central.isScanning)
                DispatchQueue.main.advance(0)
                precondition(f.central.scans == 2 && f.central.isScanning)
                precondition(f.collector.connectionState == .scanning)
            }),
            ("Scan-discovered connect times out after five seconds, then scans without waiting for the disconnect callback", {
                let f = Fixture()
                f.collector.start(); f.discover()
                DispatchQueue.main.advance(4)
                precondition(f.central.cancellations == 0)
                DispatchQueue.main.advance(1)
                precondition(f.central.cancellations == 1 && f.central.scans == 2 && f.central.isScanning)
                f.disconnect(); DispatchQueue.main.advance(0)
                precondition(f.central.scans == 2)
            }),
            ("Recovery scans during cancellation and accepts rediscovery before the old callback", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect(); f.subscribe()
                f.collector.restartConnection(); DispatchQueue.main.advance(0)
                f.discover()
                precondition(f.central.isScanning && f.central.connections == 1)
                precondition(f.peripheral.state == .disconnecting)
                // CoreBluetooth has released the handle, but its terminal callback is still queued.
                f.peripheral.state = .disconnected
                f.discover()
                precondition(f.central.connections == 2 && f.collector.connectionState == .connecting)
                f.collector.centralManager(f.central, didDisconnectPeripheral: f.peripheral, error: nil)
                f.collector.centralManager(f.central, didFailToConnect: f.peripheral, error: nil)
                precondition(f.collector.connectionState == .connecting && f.central.cancellations == 1)
                f.connect(); f.subscribe()
                f.collector.centralManager(f.central, didDisconnectPeripheral: f.peripheral, error: nil)
                f.collector.centralManager(f.central, didFailToConnect: f.peripheral, error: nil)
                f.connect() // Duplicate connected callback must not reset authentication.
                f.collector.peripheral(f.peripheral, didUpdateNotificationStateFor: f.receive, error: nil)
                DispatchQueue.main.advance(10)
                precondition(f.collector.connectionState == .connected && f.central.scans == 2)
                precondition(f.disk.session!.unlockCount == 19 && f.peripheral.writes.count == 2)
            }),
            ("Late callbacks from a different retired handle do not disturb a new connection", {
                let f = Fixture()
                f.startReceiving(); f.collector.restartConnection(); DispatchQueue.main.advance(0)
                let replacement = CBPeripheral()
                f.collector.centralManager(f.central, didDiscover: replacement, advertisementData: [:], rssi: -50)
                replacement.state = .connected
                f.collector.centralManager(f.central, didConnect: replacement)
                f.collector.peripheral(replacement, didDiscoverCharacteristicsFor: f.service, error: nil)
                precondition(replacement.bluetoothEvents == ["subscribe"])
                // An unwanted old connection is cancelled again, without touching the new link.
                f.connect()
                precondition(replacement.bluetoothEvents == ["subscribe"])
                precondition(f.peripheral.bluetoothEvents == ["subscribe", "unsubscribe", "cancel", "cancel"])
                precondition(f.peripheral.state == .disconnecting && replacement.state == .connected)
                f.disconnect(); DispatchQueue.main.advance(10)
                precondition(f.collector.connectionState == .connected && f.central.connections == 2)
                precondition(f.central.cancellations == 2 && f.central.scans == 2)
            }),
            ("Known peripheral connects without scanning or a range timeout", {
                let f = Fixture(saved: true)
                f.collector.start()
                DispatchQueue.main.advance(600)
                precondition(f.collector.connectionState == .connecting)
                precondition(f.central.connections == 1 && f.central.scans == 0 && f.central.cancellations == 0)
            }),
            ("A late connection callback cannot revive an attempt already being cancelled", {
                let f = Fixture()
                f.collector.start(); f.discover()
                DispatchQueue.main.advance(5)
                f.connect()
                precondition(f.peripheral.state == .disconnecting && f.peripheral.writes.isEmpty)
            }),
            ("Missing saved peripheral falls back to scanning", {
                let f = Fixture(saved: true)
                f.central.known = []
                f.collector.start()
                precondition(f.central.scans == 1)
            }),
            ("Bluetooth connection cancels the deadline before setup or glucose", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect()
                DispatchQueue.main.advance(300)
                f.subscribe()
                DispatchQueue.main.advance(300)
                precondition(f.central.cancellations == 0)
                f.deliverReading()
                precondition(f.readings == 1)
            }),
            ("Unexpected disconnect reuses the peripheral without retrieval and advances the persisted counter", {
                let f = Fixture()
                f.startReceiving()
                let retrievals = f.central.retrievals
                f.central.known = [] // Reconnection must not depend on saved-handle retrieval.
                f.disconnect(); DispatchQueue.main.advance(0)
                precondition(f.central.connections == 2 && f.central.scans == 1)
                precondition(f.central.retrievals == retrievals && f.central.lastConnectedPeripheral === f.peripheral)
                f.connect(); f.subscribe()
                precondition(f.disk.session!.unlockCount == 19 && f.peripheral.writes.count == 2)
            }),
            ("Failed connection reuses its handle without retrieval or consuming an unlock", {
                let f = Fixture(saved: true)
                f.collector.start()
                let retrievals = f.central.retrievals
                f.central.known = []
                f.peripheral.state = .disconnected
                f.collector.centralManager(f.central, didFailToConnect: f.peripheral, error: Libre2HandoffError.invalidSession)
                DispatchQueue.main.advance(0)
                precondition(f.central.connections == 2 && f.central.scans == 0)
                precondition(f.central.retrievals == retrievals && f.central.lastConnectedPeripheral === f.peripheral)
                precondition(f.disk.session!.unlockCount == 17 && f.peripheral.writes.isEmpty)
                f.connect(); f.subscribe()
                precondition(f.disk.session!.unlockCount == 18 && f.peripheral.writes.count == 1)
            }),
            ("Ownership return cancels a queued peripheral reuse", {
                let f = Fixture()
                f.startReceiving(); f.disconnect()
                try f.store.beginReturnToPhone(id: f.disk.session!.id)
                var returned = false
                f.collector.stop { returned = true }
                DispatchQueue.main.advance(60)
                precondition(returned && f.central.connections == 1 && f.central.scans == 1)
            }),
            ("Bluetooth power loss cancels queued reuse; restoration retrieves the saved handle", {
                let f = Fixture()
                f.startReceiving(); f.disconnect()
                f.central.state = .poweredOff
                f.collector.centralManagerDidUpdateState(f.central)
                DispatchQueue.main.advance(60)
                precondition(f.central.connections == 1 && f.collector.connectionState == .bluetoothUnavailable)
                let retrievals = f.central.retrievals
                f.central.state = .poweredOn
                f.collector.centralManagerDidUpdateState(f.central)
                precondition(f.central.connections == 2 && f.central.retrievals == retrievals + 1)
                precondition(f.central.lastConnectedPeripheral === f.peripheral)
            }),
            ("Manual restart interrupts a fresh connection once and advances the persisted counter", {
                let f = Fixture()
                f.startReceiving()
                let historyCount = f.readings
                f.collector.restartConnection()
                f.collector.restartConnection()
                precondition(f.collector.connectionState == .restarting)
                precondition(f.central.cancellations == 1 && f.central.connections == 1)
                precondition(f.disk.session!.unlockCount == 18 && f.readings == historyCount)
                f.disconnect(); DispatchQueue.main.advance(0); f.discover()
                precondition(f.central.connections == 2 && f.collector.connectionState == .connecting)
                f.connect(); f.subscribe()
                precondition(f.disk.session!.unlockCount == 19 && f.peripheral.writes.count == 2)
            }),
            ("Manual retry recovers a connected session that never produced its first reading", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect(); f.subscribe()
                precondition(f.collector.connectionState == .connected)
                f.collector.restartConnection()
                precondition(f.central.cancellations == 1 && f.collector.connectionState == .restarting)
            }),
            ("Manual restart shares a queued immediate reconnect without duplicating it", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect()
                f.peripheral.services = nil
                f.collector.peripheral(f.peripheral, didDiscoverServices: nil)
                f.disconnect()
                precondition(f.central.connections == 1)
                f.collector.restartConnection()
                DispatchQueue.main.advance(0)
                precondition(f.central.scans == 2 && f.central.connections == 1)
                f.discover(); f.connect()
                DispatchQueue.main.advance(10)
                precondition(f.central.connections == 2)
            }),
            ("Manual restart cancels a pending known-peripheral connection", {
                let f = Fixture(saved: true)
                f.collector.start()
                f.collector.restartConnection(); f.collector.restartConnection()
                precondition(f.central.connections == 1 && f.central.cancellations == 1)
                DispatchQueue.main.advance(60)
                precondition(f.central.connections == 1)
                f.disconnect(); DispatchQueue.main.advance(0); f.discover()
                precondition(f.central.connections == 2 && f.collector.connectionState == .connecting)
            }),
            ("Manual restart ignores late service, subscription and frame callbacks", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect()
                f.collector.restartConnection()
                // Even an already queued callback reporting connected cannot unlock this attempt.
                f.peripheral.state = .connected
                f.subscribe(); f.deliverReading()
                precondition(f.peripheral.writes.isEmpty && f.peripheral.notificationRequests == 0 && f.readings == 0)
                precondition(f.disk.session!.unlockCount == 17)
            }),
            ("Manual restart adopts missing-service cancellation without a duplicate cancel", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect()
                f.peripheral.services = nil
                f.collector.peripheral(f.peripheral, didDiscoverServices: nil)
                f.collector.restartConnection(); f.collector.restartConnection()
                precondition(f.central.cancellations == 1 && f.collector.connectionState == .restarting)
                f.disconnect(); DispatchQueue.main.advance(0)
                precondition(f.central.scans == 2 && f.central.connections == 1)
                f.discover(); f.connect()
                DispatchQueue.main.advance(10)
                precondition(f.central.connections == 2)
            }),
            ("A cancelled pending connection can finish through didFailToConnect", {
                let f = Fixture(saved: true)
                f.collector.start(); f.collector.restartConnection()
                f.peripheral.state = .disconnected
                f.collector.centralManager(f.central, didFailToConnect: f.peripheral, error: nil)
                DispatchQueue.main.advance(0); f.discover()
                precondition(f.central.connections == 2 && f.collector.connectionState == .connecting)
            }),
            ("Connection state reports progress before the first reading and Bluetooth unavailability", {
                let f = Fixture()
                var states: [Libre2WatchCollector.ConnectionState] = []
                f.collector.onConnectionChanged = { states.append(f.collector.connectionState) }
                f.collector.start(); f.discover(); f.connect()
                precondition(states == [.scanning, .connecting, .connected])
                precondition(f.readings == 0 && f.collector.connectionState == .connected)
                f.central.state = .poweredOff
                f.collector.centralManagerDidUpdateState(f.central)
                f.collector.restartConnection()
                precondition(f.collector.connectionState == .bluetoothUnavailable)
                precondition(!f.collector.connectionState.isConnecting && f.central.cancellations == 0)
                precondition(Libre2WatchCollector.ConnectionState.restarting.isConnecting)
            }),
            ("Every non-Watch owner blocks start and manual retry", {
                for owner in [Libre2Owner.phone, .preparingWatch, .releasingPhone, .returningToPhone,
                    .releasingWatch, .returnRequested, .failed] {
                    let f = Fixture(owner: owner, saved: true)
                    f.collector.start(); f.collector.restartConnection()
                    precondition(f.central.connections == 0 && f.central.scans == 0 && f.peripheral.writes.isEmpty)
                }
            }),
            ("Phone return supersedes manual recovery and waits for confirmed disconnect", {
                let f = Fixture()
                f.startReceiving()
                f.collector.restartConnection()
                try f.store.beginReturnToPhone(id: f.disk.session!.id)
                var returned = false
                f.collector.stop { returned = true }
                f.collector.restartConnection()
                precondition(!returned)
                f.disconnect(); DispatchQueue.main.advance(300)
                precondition(returned && f.central.connections == 1)
            }),
            ("Return waits for a retired handle even when retrieval cannot find it", {
                let f = Fixture()
                f.startReceiving(); f.collector.restartConnection(); DispatchQueue.main.advance(0)
                f.central.known = []
                try f.store.beginReturnToPhone(id: f.disk.session!.id)
                var returned = false
                f.collector.stop { returned = true }
                precondition(!returned && !f.central.isScanning && f.central.cancellations == 1)
                f.disconnect(); DispatchQueue.main.advance(300)
                precondition(returned && f.central.connections == 1 && f.central.scans == 2)
            }),
            ("Return waits for both current and retired handles in either callback order", {
                for retiredFirst in [true, false] {
                    let f = Fixture()
                    f.startReceiving(); f.collector.restartConnection(); DispatchQueue.main.advance(0)
                    let replacement = CBPeripheral()
                    f.collector.centralManager(f.central, didDiscover: replacement, advertisementData: [:], rssi: -50)
                    replacement.state = .connected
                    f.collector.centralManager(f.central, didConnect: replacement)
                    try f.store.beginReturnToPhone(id: f.disk.session!.id)
                    var completions = 0
                    f.collector.stop { completions += 1 }
                    precondition(completions == 0 && f.central.cancellations == 2)
                    let first = retiredFirst ? f.peripheral : replacement
                    let last = retiredFirst ? replacement : f.peripheral
                    first.state = .disconnected
                    f.collector.centralManager(f.central, didDisconnectPeripheral: first, error: nil)
                    precondition(completions == 0)
                    last.state = .disconnected
                    f.collector.centralManager(f.central, didDisconnectPeripheral: last, error: nil)
                    DispatchQueue.main.advance(300)
                    precondition(completions == 1 && f.central.connections == 2 && f.central.scans == 2)
                }
            }),
            ("Persistence failure prevents an unlock write", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect()
                f.failPersistence = true
                f.subscribe()
                precondition(f.peripheral.writes.isEmpty && f.store.snapshot.owner == .failed)
            }),
            ("Bluetooth power restoration reconnects through the saved reference", {
                let f = Fixture()
                f.startReceiving()
                f.central.state = .poweredOff
                f.collector.centralManagerDidUpdateState(f.central)
                f.peripheral.state = .disconnected
                f.central.state = .poweredOn
                f.collector.centralManagerDidUpdateState(f.central)
                precondition(f.central.connections == 2 && f.central.scans == 1)
            }),
            ("Bluetooth reset during manual cancellation does not disable future manual retries", {
                let f = Fixture()
                f.startReceiving()
                f.collector.restartConnection()
                f.central.state = .poweredOff
                f.collector.centralManagerDidUpdateState(f.central)
                f.peripheral.state = .disconnected
                f.central.state = .poweredOn
                f.collector.centralManagerDidUpdateState(f.central)
                f.discover(); f.connect(); f.subscribe()
                f.collector.restartConnection()
                precondition(f.central.connections == 2 && f.central.cancellations == 2)
            }),
            ("Double tap preserves ordinary phone refresh and routes Direct mode to the collector", {
                let model = WatchStateModel()
                model.refreshAfterDoubleTap()
                precondition(model.phoneRequests == 1 && model.directLibre.retries == 0)
                model.directLibre.isDirect = true
                model.refreshAfterDoubleTap()
                precondition(model.phoneRequests == 1 && model.directLibre.retries == 1)
            })
        ]
        for (name, test) in cases { try test(); print("PASS: \(name)") }
        print("\(cases.count) Watch reconnect checks passed.")
    }
}
#endif

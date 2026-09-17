// Run with Scripts/check_watch_reconnect.py; excluded from the ordinary SwiftPM test module.
#if LIBRE2_RECONNECT_TESTS
import Foundation

// These doubles expose only the CoreBluetooth API used by the production collector.
// Delegate events are delivered explicitly so cancellation never implies a confirmed disconnect.
protocol CBCentralManagerDelegate: AnyObject {}
protocol CBPeripheralDelegate: AnyObject {}
enum CBManagerState { case poweredOn, poweredOff, resetting }
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
    var onWrite: () -> Void = {}
    func discoverServices(_ services: [CBUUID]) {}
    func discoverCharacteristics(_ characteristics: [CBUUID], for service: CBService) {}
    func writeValue(_ value: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        onWrite()
        writes.append(value)
    }
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) { notificationRequests += 1 }
}
final class CBCentralManager {
    static var latest: CBCentralManager!
    var state = CBManagerState.poweredOn
    var isScanning = false
    var scans = 0
    var connections = 0
    var cancellations = 0
    var known: [CBPeripheral] = []
    init(delegate: CBCentralManagerDelegate, queue: DispatchQueue) { Self.latest = self }
    func scanForPeripherals(withServices services: [CBUUID]) { isScanning = true; scans += 1 }
    func stopScan() { isScanning = false }
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral] {
        known.filter { identifiers.contains($0.identifier) }
    }
    func connect(_ peripheral: CBPeripheral) { connections += 1; peripheral.state = .connecting }
    func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        cancellations += 1
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
        let cases: [(String, () throws -> Void)] = [
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
                    precondition(f.central.cancellations == 1)
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
            ("Failed unlock acknowledgement keeps the attempted counter for reconnection", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect(); f.subscribe()
                f.collector.peripheral(f.peripheral, didWriteValueFor: f.write, error: Libre2HandoffError.invalidSession)
                precondition(f.central.cancellations == 1 && f.disk.session!.unlockCount == 18)
                f.disconnect(); DispatchQueue.main.advance(5)
                f.connect(); f.subscribe()
                precondition(f.disk.session!.unlockCount == 19 && f.peripheral.writes.count == 2)
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
            ("Scan-discovered connect times out after five seconds, then scans after confirmed disconnect", {
                let f = Fixture()
                f.collector.start(); f.discover()
                DispatchQueue.main.advance(4)
                precondition(f.central.cancellations == 0)
                DispatchQueue.main.advance(1)
                precondition(f.central.cancellations == 1 && f.central.scans == 1)
                f.disconnect(); DispatchQueue.main.advance(0)
                precondition(f.central.scans == 2)
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
            ("Unexpected disconnect reconnects immediately with the next persisted counter", {
                let f = Fixture()
                f.startReceiving()
                f.disconnect(); DispatchQueue.main.advance(0)
                precondition(f.central.connections == 2 && f.central.scans == 1)
                f.connect(); f.subscribe()
                precondition(f.disk.session!.unlockCount == 19 && f.peripheral.writes.count == 2)
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
                f.disconnect(); DispatchQueue.main.advance(0)
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
            ("Manual retry bypasses protocol-failure backoff without duplicating the later retry", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect()
                f.peripheral.services = []
                f.collector.peripheral(f.peripheral, didDiscoverServices: nil)
                f.disconnect()
                precondition(f.central.connections == 1)
                f.collector.restartConnection()
                DispatchQueue.main.advance(0)
                precondition(f.central.connections == 2)
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
                f.disconnect(); DispatchQueue.main.advance(0)
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
            ("Manual restart adopts a protocol cancellation without a duplicate cancel", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect()
                f.peripheral.services = []
                f.collector.peripheral(f.peripheral, didDiscoverServices: nil)
                f.collector.restartConnection(); f.collector.restartConnection()
                precondition(f.central.cancellations == 1 && f.collector.connectionState == .restarting)
                f.disconnect(); DispatchQueue.main.advance(0)
                precondition(f.central.connections == 2)
                DispatchQueue.main.advance(10)
                precondition(f.central.connections == 2)
            }),
            ("A cancelled pending connection can finish through didFailToConnect", {
                let f = Fixture(saved: true)
                f.collector.start(); f.collector.restartConnection()
                f.peripheral.state = .disconnected
                f.collector.centralManager(f.central, didFailToConnect: f.peripheral, error: nil)
                DispatchQueue.main.advance(0)
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
                f.connect(); f.subscribe()
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

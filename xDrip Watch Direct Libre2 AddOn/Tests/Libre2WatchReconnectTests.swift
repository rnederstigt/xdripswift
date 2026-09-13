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
    var onWrite: () -> Void = {}
    func discoverServices(_ services: [CBUUID]) {}
    func discoverCharacteristics(_ characteristics: [CBUUID], for service: CBService) {}
    func writeValue(_ value: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        onWrite()
        writes.append(value)
    }
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {}
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
        collector.peripheral(peripheral, didWriteValueFor: write, error: nil)
        receive.isNotifying = true
        collector.peripheral(peripheral, didUpdateNotificationStateFor: receive, error: nil)
    }
    func disconnect() {
        peripheral.state = .disconnected
        collector.centralManager(central, didDisconnectPeripheral: peripheral, error: nil)
    }
    func deliverReading() {
        // Existing upstream encrypted fixture; actual assembly, crypto and native parsing run here.
        let frame = data("ebb86eb952942ce055278df46b68ba1eacd3c78c7e800ea3890c61116679c2a3fcc220a95571ff760207682942f0")
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
            ("Scan stays active; repeated taps do not restart it", {
                let f = Fixture()
                f.collector.start()
                DispatchQueue.main.advance(300)
                f.collector.retryConnection()
                precondition(f.central.scans == 1 && f.central.isScanning)
            }),
            ("Scan-discovered connect times out after five seconds, then scans after confirmed disconnect", {
                let f = Fixture()
                f.collector.start(); f.discover()
                DispatchQueue.main.advance(4)
                precondition(f.central.cancellations == 0)
                f.collector.retryConnection()
                DispatchQueue.main.advance(1)
                precondition(f.central.cancellations == 1 && f.central.scans == 1)
                f.disconnect(); DispatchQueue.main.advance(0)
                precondition(f.central.scans == 2)
            }),
            ("Known peripheral connects without scanning or a range timeout", {
                let f = Fixture(saved: true)
                f.collector.start()
                DispatchQueue.main.advance(600)
                f.collector.retryConnection()
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
            ("Fresh connection is left alone; stale manual retry waits for disconnect and runs once", {
                let f = Fixture()
                f.startReceiving()
                f.collector.retryConnection()
                precondition(f.central.cancellations == 0)
                f.collector.retryConnection(at: .distantFuture)
                f.collector.retryConnection(at: .distantFuture)
                precondition(f.central.cancellations == 1 && f.central.connections == 1)
                f.disconnect(); DispatchQueue.main.advance(0)
                precondition(f.central.connections == 2)
            }),
            ("Manual retry recovers a connected session that never produced its first reading", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect(); f.subscribe()
                f.collector.retryConnection()
                precondition(f.central.cancellations == 0)
                f.collector.retryConnection(at: .distantFuture)
                precondition(f.central.cancellations == 1)
            }),
            ("Manual retry bypasses protocol-failure backoff without duplicating the later retry", {
                let f = Fixture()
                f.collector.start(); f.discover(); f.connect()
                f.peripheral.services = []
                f.collector.peripheral(f.peripheral, didDiscoverServices: nil)
                f.disconnect()
                precondition(f.central.connections == 1)
                f.collector.retryConnection()
                precondition(f.central.connections == 2)
                DispatchQueue.main.advance(10)
                precondition(f.central.connections == 2)
            }),
            ("Every non-Watch owner blocks start and manual retry", {
                for owner in [Libre2Owner.phone, .preparingWatch, .releasingPhone, .returningToPhone,
                    .releasingWatch, .returnRequested, .reclaimingPhone, .verifyingPhone, .failed] {
                    let f = Fixture(owner: owner, saved: true)
                    f.collector.start(); f.collector.retryConnection(at: .distantFuture)
                    precondition(f.central.connections == 0 && f.central.scans == 0 && f.peripheral.writes.isEmpty)
                }
            }),
            ("Phone return supersedes manual recovery and waits for confirmed disconnect", {
                let f = Fixture()
                f.startReceiving()
                f.collector.retryConnection(at: .distantFuture)
                try f.store.beginReturnToPhone(id: f.disk.session!.id)
                var returned = false
                f.collector.stop { returned = true }
                f.collector.retryConnection(at: .distantFuture)
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
                f.collector.retryConnection(at: .distantFuture)
                f.central.state = .poweredOff
                f.collector.centralManagerDidUpdateState(f.central)
                f.peripheral.state = .disconnected
                f.central.state = .poweredOn
                f.collector.centralManagerDidUpdateState(f.central)
                f.connect(); f.subscribe()
                f.collector.retryConnection(at: .distantFuture)
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

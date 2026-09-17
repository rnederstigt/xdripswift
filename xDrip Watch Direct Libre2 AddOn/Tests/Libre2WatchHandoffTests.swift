#if LIBRE2_HANDOFF_TESTS
import Foundation

final class WCSession {
    enum State { case activated }
    static let `default` = WCSession()
    var activationState = State.activated
    var isReachable = true
    var sent: [[String: Any]] = []
    func sendMessage(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void,
                     errorHandler: @escaping (Error) -> Void) {
        sent.append(message)
    }
}

final class Libre2WatchCollector {
    static var last: Libre2WatchCollector?
    var onStatus: (String) -> Void = { _ in }
    var onConnectionChanged: () -> Void = {}
    var onReadings: ([Libre2Sample], UInt16) -> Void = { _, _ in }
    var onCollectedReading: (Libre2Sample, UInt16, Libre2WatchSession) -> Void = { _, _, _ in }
    var connectionState: ConnectionState = .inactive
    var disconnect: (() -> Void)?
    var stops = 0
    var starts = 0
    var restarts = 0
    init() { Self.last = self }
    func start() { starts += 1 }
    func restartConnection() { restarts += 1 }
    func stop(completion: @escaping () -> Void) { stops += 1; disconnect = completion }
    func confirmDisconnect() {
        let callback = disconnect
        disconnect = nil
        callback?()
    }
}

// The script supplies the real WatchStateModel user-info method; only its collaborators are doubled.
enum Libre2WatchConnectivityTasks {
    static let shared = Libre2WatchConnectivityTasks.self
    static func receive(_ action: () -> Void) { action() }
}
final class WatchStateModel {
    let directLibre = MessageRoute()
    var relayCount = 0
    func processWatchPayloadFromDictionary(dictionary: [String: Any]) { relayCount += 1 }
}
final class MessageRoute {
    var retirements = 0
    var consumesAcknowledgement = false
    func receive(_ dictionary: [String: Any], reply: ([String: Any]) -> Void) { retirements += 1 }
    func receiveHistoryAcknowledgement(_ dictionary: [String: Any]) -> Bool { consumesAcknowledgement }
}

@main
enum HandoffTests {
    static func session() -> Libre2WatchSession {
        Libre2WatchSession(id: UUID(), createdAt: Date(), sensorUID: Data(repeating: 1, count: 8),
            patchInfo: Data(repeating: 1, count: 6), unlockCode: 42, unlockCount: 17,
            bluetoothName: "ABBOTT123", sensorSerial: "123",
            calibration: Libre2Calibration(slopeSlope: 0, offsetSlope: 0.1, slopeOffset: 0,
                offsetOffset: 0, extraSlope: 1, extraOffset: 0))
    }

    static func fixture(_ old: Libre2WatchSession) -> (Libre2SessionStore, Libre2WatchHandoff) {
        Libre2WatchCollector.last = nil
        let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .watch,
            session: old, watchMayHaveConnected: true)) { _ in }
        return (store, Libre2WatchHandoff(store: store))
    }

    static func main() throws {
        let host = WatchStateModel()
        host.session(.default, didReceiveUserInfo: [Libre2HandoffMessage.retiredIDsKey: [UUID().uuidString]])
        precondition(host.directLibre.retirements == 1 && host.relayCount == 0)
        host.directLibre.consumesAcknowledgement = true
        host.session(.default, didReceiveUserInfo: [:])
        precondition(host.relayCount == 0)
        host.directLibre.consumesAcknowledgement = false
        host.session(.default, didReceiveUserInfo: ["ordinary": true])
        precondition(host.relayCount == 1 && host.directLibre.retirements == 1)
        print("PASS: Production Watch user-info handler routes retirement, consumes history acknowledgements and preserves ordinary relay")
        let old = session()
        let retirement: [String: Any] = [Libre2HandoffMessage.retiredIDsKey: [old.id.uuidString]]
        do {
            let (store, handoff) = fixture(old)
            var replies = 0
            handoff.receive(retirement) { response in
                precondition(response["retiredHandoffsApplied"] as? Bool == true)
                replies += 1
            }
            handoff.receive(retirement) { response in
                precondition(response["retiredHandoffsApplied"] as? Bool == true)
                replies += 1
            }
            precondition(replies == 0 && Libre2WatchCollector.last?.stops == 1)
            precondition(store.snapshot.session?.unlockCount == old.unlockCount)
            Libre2WatchCollector.last?.confirmDisconnect()
            precondition(store.snapshot.owner == .phone && replies == 2)
            handoff.receive(retirement) { _ in replies += 1 }
            precondition(replies == 3 && Libre2WatchCollector.last?.stops == 1)
            print("PASS: Duplicate retirement shares one barrier, preserves the counter and is harmless after release")
        }
        do {
            let encoded = try JSONEncoder().encode(Libre2HandoffMessage(kind: .prepare, session: old))
            var obsolete = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            obsolete["kind"] = "revoke"
            let data = try JSONSerialization.data(withJSONObject: obsolete)
            for includeRetirement in [false, true] {
                let (store, handoff) = fixture(old)
                var dictionary: [String: Any] = [Libre2HandoffMessage.key: data]
                if includeRetirement { dictionary.merge(retirement) { _, ids in ids } }
                var rejected = false
                handoff.receive(dictionary) { rejected = $0["error"] != nil }
                precondition(rejected && store.snapshot.owner == .watch && store.snapshot.session == old)
                precondition(store.snapshot.retiredIDs.isEmpty && Libre2WatchCollector.last == nil)
            }
            print("PASS: Obsolete revoke messages are rejected alone or combined, without changing ownership or Bluetooth")
        }
        do {
            let (store, handoff) = fixture(old)
            var combined = retirement
            combined[Libre2HandoffMessage.key] = Data("invalid".utf8)
            var failed = false
            handoff.receive(combined) { failed = $0["error"] != nil }
            precondition(failed && store.snapshot.owner == .watch && store.snapshot.retiredIDs.isEmpty)
            precondition(Libre2WatchCollector.last == nil)
            print("PASS: Malformed combined payload fails validation before any retirement is persisted")
        }
        do {
            Libre2WatchCollector.last = nil
            let store = Libre2SessionStore(record: Libre2OwnershipRecord()) { _ in }
            let handoff = Libre2WatchHandoff(store: store)
            var reply: [String: Any]?
            handoff.receive(retirement) { reply = $0 }
            precondition(reply?["retiredHandoffsApplied"] as? Bool == true && store.snapshot.retiredIDs.contains(old.id))
            precondition(Libre2WatchCollector.last == nil)
            handoff.receive(try Libre2HandoffMessage(kind: .prepare, session: old).dictionary) { reply = $0 }
            precondition(reply?["error"] != nil && store.snapshot.owner == .phone)
            print("PASS: Retirement arriving before PREPARE prevents delayed activation without creating Bluetooth")
        }
        do {
            for owner: Libre2Owner in [.phone, .preparingWatch, .releasingPhone, .returnRequested,
                                      .returningToPhone, .releasingWatch, .failed] {
                Libre2WatchCollector.last = nil
                let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: owner, session: old)) { _ in }
                let handoff = Libre2WatchHandoff(store: store)
                var changes = 0
                handoff.onChange = { changes += 1 }
                handoff.restartConnection()
                precondition(changes == 1 && !handoff.indicatorText.isEmpty && Libre2WatchCollector.last == nil)
                precondition(store.snapshot.owner == owner && store.snapshot.session == old)
                precondition(!handoff.connectionState.isConnecting)
            }
            let (store, handoff) = fixture(old)
            handoff.restartConnection()
            precondition(Libre2WatchCollector.last?.restarts == 1 && store.snapshot.session == old)
            var changes = 0
            handoff.onChange = { changes += 1 }
            Libre2WatchCollector.last?.onConnectionChanged()
            Libre2WatchCollector.last?.onStatus("Connection progress")
            precondition(changes == 2, "Connection changes and logged progress must both refresh the display")
            Libre2WatchCollector.last?.connectionState = .restarting
            precondition(handoff.connectionState.isConnecting && handoff.indicatorText == Texts_DirectLibre.restarting)
            try store.beginReturnToPhone(id: old.id)
            precondition(!handoff.connectionState.isConnecting && handoff.indicatorText == Texts_DirectLibre.returning)
            print("PASS: Manual restart requires activated ownership; every blocked phase supplies status without creating Bluetooth")
        }
        do {
            let (store, handoff) = fixture(old)
            var replies = 0
            handoff.receive(retirement) { _ in replies += 1 }
            precondition(store.snapshot.owner == .releasingWatch && replies == 0)
            precondition(store.snapshot.session?.unlockCount == 17)
            precondition(Libre2WatchCollector.last?.starts == 0)
            Libre2WatchCollector.last?.confirmDisconnect()
            precondition(store.snapshot.owner == .phone && replies == 1)
            handoff.receive(retirement) { _ in replies += 1 }
            precondition(replies == 2 && Libre2WatchCollector.last?.disconnect == nil)
            print("PASS: Retirement persists and disables reconnect before disconnect; replies wait for confirmation")
        }
        do {
            let (store, handoff) = fixture(old)
            let next = session()
            var prepare = try Libre2HandoffMessage(kind: .prepare, session: next).dictionary
            prepare.merge(retirement) { _, value in value }
            var reply: [String: Any]?
            handoff.receive(prepare) { reply = $0 }
            precondition(store.snapshot.session?.id == old.id && reply == nil)
            var duplicateReplied = false
            handoff.receive(retirement) { _ in duplicateReplied = true }
            precondition(!duplicateReplied)
            Libre2WatchCollector.last?.confirmDisconnect()
            precondition(store.snapshot.owner == .preparingWatch && store.snapshot.session == next)
            precondition(duplicateReplied)
            precondition(reply?["ready"] as? String == next.id.uuidString)
            precondition(Libre2WatchCollector.last?.starts == 0)
            try store.activateWatch(id: next.id)
            handoff.receive(retirement) { _ in }
            precondition(store.snapshot.owner == .watch && store.snapshot.session == next)
            precondition(Libre2WatchCollector.last?.disconnect == nil)
            print("PASS: Overlapping retirements share disconnect without losing PREPARE; late retirement cannot stop the new handoff")
        }
        do {
            let (store, _) = fixture(old)
            _ = try store.retireOnWatch([old.id])
            let restartedStore = Libre2SessionStore(record: store.snapshot) { _ in }
            let handoff = Libre2WatchHandoff(store: restartedStore)
            handoff.restore()
            precondition(restartedStore.snapshot.owner == .releasingWatch)
            Libre2WatchCollector.last?.confirmDisconnect()
            precondition(restartedStore.snapshot.owner == .phone)
            print("PASS: Restart during retirement completes local disconnect without a return transaction")
        }
        do {
            let (store, handoff) = fixture(old)
            var failed = false
            handoff.receive([Libre2HandoffMessage.retiredIDsKey: [old.id.uuidString, "invalid"]]) {
                failed = $0["error"] != nil
            }
            precondition(failed && store.snapshot.owner == .watch && Libre2WatchCollector.last == nil)
            print("PASS: Malformed retirement cannot partially revoke a session")
        }
        do {
            let (store, handoff) = fixture(old)
            var failed = false
            handoff.receive(try Libre2HandoffMessage(kind: .requestReturn, session: session()).dictionary) {
                failed = $0["error"] != nil
            }
            precondition(failed && store.snapshot.owner == .watch)
            print("PASS: Unrelated return still rejected without changing ownership")
        }
    }
}
#endif

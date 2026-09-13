// Run with Scripts/check_history_delivery.py; the platform coordinator is not a SwiftPM target.
#if LIBRE2_HISTORY_TESTS
import Foundation

enum Libre2HandoffError: Error { case invalidSession }
enum WKExtension {
    static let applicationDidBecomeActiveNotification = Notification.Name("test-watch-activation")
}
final class DispatchQueue {
    static let main = DispatchQueue()
    func async(execute work: @escaping () -> Void) { work() }
}
final class Libre2ActivityLog {
    static let shared = Libre2ActivityLog()
    func record(_ message: String) {}
}
enum WCSessionActivationState { case activated, inactive }
struct WCSessionUserInfoTransfer { let userInfo: [String: Any] }
final class WCSession {
    struct Request {
        let message: [String: Any]
        let reply: ([String: Any]) -> Void
        let error: (Error) -> Void
    }
    static var `default` = WCSession()
    var activationState = WCSessionActivationState.activated
    var isReachable = true
    var requests: [Request] = []
    var outstandingUserInfoTransfers: [WCSessionUserInfoTransfer] = []
    func sendMessage(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void,
                     errorHandler: @escaping (Error) -> Void) {
        requests.append(Request(message: message, reply: replyHandler, error: errorHandler))
    }
    func transferUserInfo(_ dictionary: [String: Any]) {
        outstandingUserInfoTransfers.append(.init(userInfo: dictionary))
    }
}

private func expect(_ condition: Bool) { precondition(condition) }

private final class Fixture {
    let old = Libre2HistoryReading(sessionID: UUID(), sensorUID: Data(repeating: 1, count: 8),
        sensorMinute: 100, date: Date().addingTimeInterval(-120), glucose: 100)
    let current = Libre2HistoryReading(sessionID: UUID(), sensorUID: Data(repeating: 2, count: 8),
        sensorMinute: 100, date: Date().addingTimeInterval(-60), glucose: 110)
    let queue: Libre2HistoryQueue
    let sync: Libre2WatchHistorySync
    var failPersistence = false
    var disk = Libre2HistoryQueue.State()
    var session: WCSession { .default }

    init(reachable: Bool = true) throws {
        WCSession.default = WCSession()
        WCSession.default.isReachable = reachable
        var writer: ((Libre2HistoryQueue.State) throws -> Void)?
        queue = Libre2HistoryQueue { try writer?($0) }
        sync = Libre2WatchHistorySync(queue: queue)
        writer = { [unowned self] state in
            if self.failPersistence { throw Libre2HistoryError.unavailable }
            self.disk = state
        }
        try queue.append(old)
        try queue.append(current)
        sync.flush()
    }

    func request(_ index: Int = 0) throws -> Libre2HistoryBatch {
        try Libre2HistoryBatch.decode(session.requests[index].message)
    }
    func rejection(_ batch: Libre2HistoryBatch) throws -> [String: Any] {
        try Libre2HistoryRejection(batchID: batch.id, readingIDs: [old.id]).dictionary
    }
}

@main
private enum HistoryDeliveryTests {
    static func main() throws {
        let cases: [(String, () throws -> Void)] = [
            ("Interactive rejection retains unmatched readings before sending the valid remainder", {
                let f = try Fixture()
                let first = try f.request()
                f.session.requests[0].reply(try f.rejection(first))
                expect(f.disk.unresolved == [f.old] && f.session.requests.count == 2)
                let next = try f.request(1)
                expect(next.id != first.id && next.readings == [f.current])
                f.session.requests[1].reply(try Libre2HistoryAcknowledgement(batch: next).dictionary)
                expect(f.queue.state.pending.isEmpty && f.disk.unresolved == [f.old])
                expect(f.sync.receive(try Libre2HistoryAcknowledgement(batch: first).dictionary))
                expect(f.disk.unresolved == [f.old])
            }),
            ("A queued rejection followed by an interactive duplicate still starts the next batch", {
                let f = try Fixture()
                let reply = try f.rejection(f.request())
                expect(f.sync.receive(reply))
                expect(f.session.requests.count == 1)
                f.session.requests[0].reply(reply)
                expect(f.session.requests.count == 2)
                expect(try f.request(1).readings == [f.current])
            }),
            ("Queued delivery advances after rejection while the phone is unreachable interactively", {
                let f = try Fixture(reachable: false)
                let first = try Libre2HistoryBatch.decode(f.session.outstandingUserInfoTransfers[0].userInfo)
                expect(f.sync.receive(try f.rejection(first)))
                expect(f.session.outstandingUserInfoTransfers.count == 2)
                let next = try Libre2HistoryBatch.decode(f.session.outstandingUserInfoTransfers[1].userInfo)
                expect(next.readings == [f.current] && f.disk.unresolved == [f.old])
            }),
            ("Generic database or legacy-phone errors leave the batch available for retry", {
                let f = try Fixture()
                let first = try f.request()
                f.session.requests[0].reply(["error": "Store temporarily unavailable"])
                expect(f.queue.state.batch == first && f.queue.state.unresolved.isEmpty)
                f.sync.resume()
                expect(try f.request(1) == first)
            }),
            ("Transport failure queues the same batch without quarantining any readings", {
                let f = try Fixture()
                let first = try f.request()
                f.session.requests[0].error(Libre2HistoryError.unavailable)
                let queued = try Libre2HistoryBatch.decode(f.session.outstandingUserInfoTransfers[0].userInfo)
                expect(queued == first && f.queue.state.unresolved.isEmpty)
            }),
            ("Cleanup inspects without writing and acknowledges only a persisted deletion", {
                let f = try Fixture()
                f.session.requests[0].reply(try f.rejection(f.request()))
                let before = f.disk
                var inspected: Libre2UnresolvedReadings?
                expect(f.sync.receiveCleanup(try Libre2HistoryCleanupRequest.inspect.dictionary) {
                    inspected = try! Libre2UnresolvedReadings.decode($0)
                })
                expect(inspected?.count == 1 && f.disk == before)
                expect(f.sync.receiveCleanup(try Libre2HistoryCleanupRequest.delete(inspected!).dictionary) {
                    expect(f.disk.unresolved.isEmpty)
                    expect(try! Libre2UnresolvedReadings.decode($0).count == 0)
                })
                expect(f.disk.pending == before.pending && f.disk.batch == before.batch)
                expect(f.disk.lastCollectedMinute == before.lastCollectedMinute)
                expect(f.session.requests.count == 2 && f.session.outstandingUserInfoTransfers.isEmpty)
            }),
            ("Cleanup reports persistence errors and rejects duplicates without deleting newer data", {
                let f = try Fixture()
                f.session.requests[0].reply(try f.rejection(f.request()))
                let deletion = try Libre2HistoryCleanupRequest.delete(f.queue.unresolvedReadings).dictionary
                f.failPersistence = true
                expect(f.sync.receiveCleanup(deletion) { expect($0["error"] != nil) })
                expect(f.disk.unresolved == [f.old])
                f.failPersistence = false
                expect(f.sync.receiveCleanup(deletion) { expect($0["error"] == nil) })
                let next = try f.request(1)
                try f.queue.retainUnresolved(.init(batchID: next.id, readingIDs: [f.current.id]))
                expect(f.sync.receiveCleanup(deletion) { expect($0["error"] != nil) })
                expect(f.disk.unresolved == [f.current])
            }),
            ("Malformed cleanup is rejected and unrelated messages are left to their existing route", {
                let f = try Fixture()
                let before = f.disk
                expect(f.sync.receiveCleanup([Libre2HistoryCleanupRequest.key: "invalid"]) {
                    expect($0["error"] != nil)
                })
                expect(!f.sync.receiveCleanup([:]) { _ in preconditionFailure("Unexpected reply") })
                expect(f.disk == before)
            }),
            ("Rejection persistence failure cannot clear the batch or release the next upload", {
                let f = try Fixture()
                let first = try f.request()
                f.failPersistence = true
                f.session.requests[0].reply(try f.rejection(first))
                expect(f.disk.batch == first && f.disk.unresolved.isEmpty && f.session.requests.count == 1)
                f.failPersistence = false
                f.sync.resume()
                expect(try f.request(1) == first)
                f.session.requests[1].reply(try f.rejection(first))
                expect(f.session.requests.count == 3 && f.disk.unresolved == [f.old])
            })
        ]
        for (name, test) in cases { try test(); print("PASS: \(name)") }
        print("\(cases.count) Watch history delivery checks passed.")
    }
}
#endif

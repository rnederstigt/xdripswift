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
final class WCSessionUserInfoTransfer {
    let userInfo: [String: Any]
    var isCancelled = false
    var isFinished = false
    var onCancel: (() -> Void)?
    init(userInfo: [String: Any]) { self.userInfo = userInfo }
    func cancel() {
        onCancel?()
        isCancelled = true
    }
}
final class WCSession {
    struct Request {
        let message: [String: Any]
        let reply: ([String: Any]) -> Void
        let error: (Error) -> Void
    }
    static var `default` = WCSession()
    var activationState = WCSessionActivationState.activated
    var isReachable = true
    private var allRequests: [Request] = []
    var requests: [Request] { allRequests.filter { $0.message[Libre2HistoryBatch.latestKey] == nil } }
    var latestRequests: [Request] { allRequests.filter { $0.message[Libre2HistoryBatch.latestKey] as? Bool == true } }
    var applicationContext: [String: Any] = [:]
    var contextUpdates: [[String: Any]] = []
    var failContextUpdate = false
    var onContext: (() -> Void)?
    func updateApplicationContext(_ context: [String: Any]) throws {
        onContext?()
        if failContextUpdate { throw Libre2HistoryError.unavailable }
        applicationContext = context
        contextUpdates.append(context)
    }
    var onSend: (([String: Any]) -> Void)?
    var onTransfer: (() -> Void)?
    private var transfers: [WCSessionUserInfoTransfer] = []
    var outstandingUserInfoTransfers: [WCSessionUserInfoTransfer] {
        transfers.filter { !$0.isCancelled && !$0.isFinished }
    }
    func sendMessage(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void,
                     errorHandler: @escaping (Error) -> Void) {
        onSend?(message)
        allRequests.append(Request(message: message, reply: replyHandler, error: errorHandler))
    }
    func transferUserInfo(_ dictionary: [String: Any]) {
        onTransfer?()
        transfers.append(.init(userInfo: dictionary))
    }
}

private func expect(_ condition: Bool) { precondition(condition) }

private final class TestClock { var date = Date() }

private final class Fixture {
    let old = Libre2HistoryReading(sessionID: UUID(), sensorUID: Data(repeating: 1, count: 8),
        sensorMinute: 100, date: Date().addingTimeInterval(-120), glucose: 100)
    let current = Libre2HistoryReading(sessionID: UUID(), sensorUID: Data(repeating: 2, count: 8),
        sensorMinute: 100, date: Date().addingTimeInterval(-60), glucose: 110)
    let queue: Libre2HistoryQueue
    let sync: Libre2WatchHistorySync
    let clock: TestClock
    var failPersistence = false
    var disk = Libre2HistoryQueue.State()
    var session: WCSession { .default }

    init(reachable: Bool = true) throws {
        WCSession.default = WCSession()
        WCSession.default.isReachable = reachable
        var writer: ((Libre2HistoryQueue.State) throws -> Void)?
        queue = Libre2HistoryQueue { try writer?($0) }
        let clock = TestClock()
        self.clock = clock
        sync = Libre2WatchHistorySync(queue: queue, now: { clock.date })
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
            ("Latest context advances while unreachable history is outstanding or awaiting acknowledgement", {
                let f = try Fixture(reachable: false)
                let first = f.disk.batch!
                expect(try Libre2HistoryBatch.decode(f.session.applicationContext).readings == [f.current])
                for minute in 101...102 {
                    if minute == 102 { f.session.outstandingUserInfoTransfers[0].isFinished = true }
                    let newer = Libre2HistoryReading(sessionID: f.current.sessionID, sensorUID: f.current.sensorUID,
                        sensorMinute: UInt16(minute), date: Date().addingTimeInterval(Double(minute)), glucose: 115)
                    try f.queue.append(newer)
                    f.sync.flush()
                    expect(try Libre2HistoryBatch.decode(f.session.applicationContext).readings == [newer])
                    expect(f.disk.batch == first)
                }
                expect(f.session.contextUpdates.count == 3 && f.disk.pending.count == 4)
                expect(f.session.latestRequests.isEmpty && f.session.requests.isEmpty)
                expect(f.session.outstandingUserInfoTransfers.isEmpty)
            }),
            ("Restart and repeated events do not republish the context or rewind it to older history", {
                let f = try Fixture(reachable: false)
                let context = try Libre2HistoryBatch.decode(f.session.applicationContext)
                f.sync.flush()
                f.sync.resume()
                let sync = Libre2WatchHistorySync(queue: Libre2HistoryQueue(state: f.disk) { _ in })
                sync.resume()
                expect(f.session.contextUpdates.count == 1)
                // Simulate a recovered journal containing only older history; WCSession
                // still retains the previously published newest context.
                let older = Libre2HistoryQueue { _ in }
                try older.append(f.old)
                Libre2WatchHistorySync(queue: older).flush()
                expect(try Libre2HistoryBatch.decode(f.session.applicationContext) == context)
                expect(f.session.contextUpdates.count == 1)
            }),
            ("Context failure preserves live delivery and retries on an existing event", {
                let f = try Fixture()
                f.session.failContextUpdate = true
                let newer = Libre2HistoryReading(sessionID: f.current.sessionID, sensorUID: f.current.sensorUID,
                    sensorMinute: 101, date: Date(), glucose: 115)
                try f.queue.append(newer)
                f.sync.flush()
                expect(f.session.contextUpdates.count == 1)
                expect(try Libre2HistoryBatch.decode(f.session.latestRequests.last!.message).readings == [newer])
                f.session.failContextUpdate = false
                f.sync.flush()
                expect(f.session.contextUpdates.count == 2 && f.disk.pending.count == 3)
            }),
            ("Context failure does not block queued history or remove durable readings", {
                let f = try Fixture(reachable: false)
                let first = f.disk.batch!
                f.session.failContextUpdate = true
                let newer = Libre2HistoryReading(sessionID: f.current.sessionID, sensorUID: f.current.sensorUID,
                    sensorMinute: 101, date: Date(), glucose: 115)
                try f.queue.append(newer)
                expect(f.sync.receive(try Libre2HistoryAcknowledgement(batch: first).dictionary))
                expect(f.disk.pending == [newer])
                expect(try Libre2HistoryBatch.decode(f.session.outstandingUserInfoTransfers[0].userInfo).readings == [newer])
                expect(f.session.contextUpdates.count == 1)
            }),
            ("Inactive connectivity waits for activation before publishing latest context", {
                let f = try Fixture(reachable: false)
                let newer = Libre2HistoryReading(sessionID: f.current.sessionID, sensorUID: f.current.sensorUID,
                    sensorMinute: 101, date: Date(), glucose: 115)
                try f.queue.append(newer)
                f.session.activationState = .inactive
                f.sync.flush()
                expect(f.session.contextUpdates.count == 1)
                f.session.activationState = .activated
                f.sync.flush()
                expect(f.session.contextUpdates.count == 2)
            }),
            ("Completed background transfer waits five minutes despite new readings, stale replies and foreground events", {
                let f = try Fixture(reachable: false)
                let first = f.disk.batch!
                let transfer = f.session.outstandingUserInfoTransfers[0]
                transfer.isFinished = true
                let submitted = f.clock.date
                for minute in 1...4 {
                    f.clock.date = submitted.addingTimeInterval(Double(minute) * 60)
                    try f.queue.append(.init(sessionID: f.current.sessionID, sensorUID: f.current.sensorUID,
                        sensorMinute: UInt16(100 + minute), date: f.clock.date, glucose: 115))
                    f.sync.flush()
                    f.sync.resume()
                    let stale = Libre2HistoryBatch(readings: first.readings)
                    expect(f.sync.receive(try Libre2HistoryAcknowledgement(batch: stale).dictionary))
                    expect(f.session.outstandingUserInfoTransfers.isEmpty && f.disk.batch == first)
                }
                f.clock.date = submitted.addingTimeInterval(299)
                f.sync.flush()
                expect(f.session.outstandingUserInfoTransfers.isEmpty)
                f.clock.date = submitted.addingTimeInterval(300)
                f.sync.flush()
                expect(f.session.outstandingUserInfoTransfers.count == 1)
                expect(try Libre2HistoryBatch.decode(f.session.outstandingUserInfoTransfers[0].userInfo) == first)
                expect(f.disk.pending.count == 6 && f.disk.lastBackgroundSubmission == f.clock.date)
                f.session.outstandingUserInfoTransfers[0].isFinished = true
                f.sync.resume()
                expect(f.session.outstandingUserInfoTransfers.isEmpty)
            }),
            ("Restart preserves the wait while restored reachability still delivers the newest sample", {
                let f = try Fixture(reachable: false)
                let first = f.disk.batch!
                f.session.outstandingUserInfoTransfers[0].isFinished = true
                let newer = Libre2HistoryReading(sessionID: f.current.sessionID, sensorUID: f.current.sensorUID,
                    sensorMinute: 101, date: Date(), glucose: 115)
                try f.queue.append(newer)
                let restored = Libre2HistoryQueue(state: f.disk) { _ in }
                let sync = Libre2WatchHistorySync(queue: restored, now: { f.clock.date })
                f.clock.date.addTimeInterval(60)
                f.session.isReachable = true
                sync.resume()
                expect(f.session.requests.isEmpty && f.session.outstandingUserInfoTransfers.isEmpty)
                expect(try Libre2HistoryBatch.decode(f.session.latestRequests[0].message).readings == [newer])
                f.session.isReachable = false
                expect(sync.receive(try Libre2HistoryAcknowledgement(batch: first).dictionary))
                expect(restored.state.pending == [newer])
                expect(f.session.outstandingUserInfoTransfers.count == 1)
                expect(try Libre2HistoryBatch.decode(f.session.outstandingUserInfoTransfers[0].userInfo).readings == [newer])
            }),
            ("Background reservation must persist before submission and a failed save permits a later retry", {
                let f = try Fixture()
                let first = try f.request()
                f.failPersistence = true
                f.session.requests[0].error(Libre2HistoryError.unavailable)
                expect(f.session.outstandingUserInfoTransfers.isEmpty && f.disk.lastBackgroundSubmission == nil)
                f.failPersistence = false
                f.session.isReachable = false
                f.session.onTransfer = { expect(f.disk.lastBackgroundSubmission == f.clock.date && f.disk.batch == first) }
                f.sync.flush()
                expect(f.session.outstandingUserInfoTransfers.count == 1)
            }),
            ("Failed transfers retain a bounded retry and late completions cannot extend a newer reservation", {
                let f = try Fixture(reachable: false)
                let old = f.session.outstandingUserInfoTransfers[0]
                old.isFinished = true
                f.sync.flush()
                expect(f.session.outstandingUserInfoTransfers.isEmpty)
                f.clock.date.addTimeInterval(300)
                f.sync.flush()
                expect(f.session.outstandingUserInfoTransfers.count == 1)
                let retryDate = f.disk.lastBackgroundSubmission
                f.clock.date.addTimeInterval(30)
                expect(f.disk.lastBackgroundSubmission == retryDate)
                // An outstanding transfer remains with WCSession even after the interval.
                f.clock.date.addTimeInterval(600)
                f.sync.flush()
                expect(f.session.outstandingUserInfoTransfers.count == 1)
            }),
            ("Background cancellation occurs only after a persisted batch resolution", {
                let f = try Fixture(reachable: false)
                let transfer = f.session.outstandingUserInfoTransfers[0]
                let acknowledgement = try Libre2HistoryAcknowledgement(batch: f.disk.batch!).dictionary
                f.failPersistence = true
                expect(f.sync.receive(acknowledgement))
                expect(!transfer.isCancelled)
                f.failPersistence = false
                transfer.onCancel = {
                    expect(f.disk.batch == nil && f.disk.pending.isEmpty)
                }
                expect(f.sync.receive(acknowledgement))
                expect(transfer.isCancelled)
            }),
            ("New readings bypass both an unanswered history request and an unanswered latest request", {
                let f = try Fixture()
                let history = try f.request()
                expect(f.session.latestRequests.count == 1)
                let newer = Libre2HistoryReading(sessionID: f.current.sessionID, sensorUID: f.current.sensorUID,
                    sensorMinute: 101, date: Date(), glucose: 115)
                try f.queue.append(newer)
                f.session.onSend = { message in
                    expect(f.disk.pending.contains(newer))
                    expect(try! Libre2HistoryBatch.decode(message).readings == [newer])
                }
                f.sync.flush()
                expect(f.session.requests.count == 1 && f.session.latestRequests.count == 2)
                expect(f.disk.batch == history && f.disk.pending.count == 3)
                let latest = try Libre2HistoryBatch.decode(f.session.latestRequests[1].message)
                f.session.latestRequests[1].reply(try Libre2HistoryAcknowledgement(batch: latest).dictionary)
                f.session.latestRequests[0].error(Libre2HistoryError.unavailable)
                f.sync.flush()
                expect(f.session.latestRequests.count == 2 && f.session.contextUpdates.count == 2 && f.disk.pending.count == 3)
                expect(f.disk.batch == history)
            }),
            ("A queued history batch cannot block a newly collected reading", {
                let f = try Fixture(reachable: false)
                let history = f.disk.batch!
                let newer = Libre2HistoryReading(sessionID: f.current.sessionID, sensorUID: f.current.sensorUID,
                    sensorMinute: 101, date: Date(), glucose: 115)
                try f.queue.append(newer)
                f.session.isReachable = true
                f.sync.flush()
                expect(try Libre2HistoryBatch.decode(f.session.latestRequests[0].message).readings == [newer])
                expect(f.session.requests.isEmpty && f.disk.batch == history)
                expect(f.session.outstandingUserInfoTransfers.count == 1)
            }),
            ("Collection persists before either route and a failed save sends nothing", {
                let f = try Fixture()
                let session = Libre2WatchSession(id: f.current.sessionID, createdAt: Date(),
                    sensorUID: f.current.sensorUID, patchInfo: Data(repeating: 1, count: 6),
                    unlockCode: 42, unlockCount: 1, bluetoothName: "ABBOTT123", sensorSerial: "123",
                    calibration: Libre2Calibration(slopeSlope: 0, offsetSlope: 0.1,
                        slopeOffset: 0, offsetOffset: 0, extraSlope: 1, extraOffset: 0))
                let sample = Libre2Sample(timeStamp: Date(), glucoseLevelRaw: 115)
                f.failPersistence = true
                f.sync.collect(sample, sensorMinute: 101, session: session)
                expect(f.session.latestRequests.count == 1 && f.session.contextUpdates.count == 1 && f.disk.pending.count == 2)
                f.failPersistence = false
                f.session.onContext = { expect(f.disk.pending.last?.sensorMinute == 101) }
                f.session.onSend = { _ in expect(f.disk.pending.last?.sensorMinute == 101) }
                f.sync.collect(sample, sensorMinute: 101, session: session)
                expect(f.session.latestRequests.count == 2 && f.disk.pending.count == 3)
                f.session.latestRequests[1].error(Libre2HistoryError.unavailable)
            }),
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
            ("A queued rejection releases the next batch before the old interactive reply arrives", {
                let f = try Fixture()
                let reply = try f.rejection(f.request())
                expect(f.sync.receive(reply))
                expect(f.session.requests.count == 2)
                f.session.requests[0].reply(reply)
                f.sync.flush()
                expect(f.session.requests.count == 2)
                expect(try f.request(1).readings == [f.current])
            }),
            ("Queued delivery advances after rejection while the phone is unreachable interactively", {
                let f = try Fixture(reachable: false)
                let first = try Libre2HistoryBatch.decode(f.session.outstandingUserInfoTransfers[0].userInfo)
                expect(f.sync.receive(try f.rejection(first)))
                expect(f.session.outstandingUserInfoTransfers.count == 1)
                let next = try Libre2HistoryBatch.decode(f.session.outstandingUserInfoTransfers[0].userInfo)
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
            ("Reachability sends only the latest reading and leaves the queued history transfer intact", {
                let f = try Fixture(reachable: false)
                let transfer = f.session.outstandingUserInfoTransfers[0]
                let queued = try Libre2HistoryBatch.decode(transfer.userInfo)
                f.sync.flush()
                expect(f.session.requests.isEmpty && f.session.outstandingUserInfoTransfers.count == 1)
                f.session.isReachable = true
                f.sync.flush()
                expect(f.session.requests.isEmpty && f.session.latestRequests.count == 1)
                let latest = try Libre2HistoryBatch.decode(f.session.latestRequests[0].message)
                expect(latest.readings == [f.current] && latest.id != queued.id)
                expect(!transfer.isCancelled && f.disk.batch == queued)
                f.sync.flush()
                expect(f.session.requests.isEmpty && f.session.latestRequests.count == 1)
                f.session.latestRequests[0].reply(try Libre2HistoryAcknowledgement(batch: latest).dictionary)
                expect(!transfer.isCancelled && f.disk.batch == queued)
                transfer.onCancel = { expect(f.disk.batch == nil && f.disk.pending.isEmpty) }
                expect(f.sync.receive(try Libre2HistoryAcknowledgement(batch: queued).dictionary))
                expect(transfer.isCancelled && f.queue.state.pending.isEmpty)
            }),
            ("Failed latest delivery leaves one history transfer and retries on restored reachability", {
                let f = try Fixture(reachable: false)
                f.session.isReachable = true
                f.sync.flush()
                let first = f.disk.batch!
                f.session.latestRequests[0].error(Libre2HistoryError.unavailable)
                f.sync.flush()
                expect(f.session.requests.isEmpty && f.session.latestRequests.count == 1)
                expect(f.session.outstandingUserInfoTransfers.count == 1)
                expect(f.disk.batch == first)
                f.session.isReachable = false
                f.sync.flush()
                f.session.isReachable = true
                f.sync.flush()
                expect(f.session.requests.isEmpty && f.session.latestRequests.count == 2)
                expect(try Libre2HistoryBatch.decode(f.session.latestRequests[1].message).readings == [f.current])
                expect(f.session.outstandingUserInfoTransfers.count == 1)
            }),
            ("Background acknowledgement drains newer readings; late replies and errors cannot release their live send", {
                for lateError in [false, true] {
                    let f = try Fixture()
                    let first = try f.request()
                    let newer = Libre2HistoryReading(sessionID: f.current.sessionID, sensorUID: f.current.sensorUID,
                        sensorMinute: 101, date: Date(), glucose: 115)
                    try f.queue.append(newer)
                    let acknowledgement = try Libre2HistoryAcknowledgement(batch: first).dictionary
                    expect(f.sync.receive(acknowledgement))
                    expect(f.session.requests.count == 2)
                    expect(try f.request(1).readings == [newer])
                    expect(f.session.outstandingUserInfoTransfers.isEmpty)
                    if lateError { f.session.requests[0].error(Libre2HistoryError.unavailable) }
                    else { f.session.requests[0].reply(acknowledgement) }
                    f.sync.flush()
                    expect(f.session.requests.count == 2 && f.session.outstandingUserInfoTransfers.isEmpty)
                    f.session.requests[1].reply(try Libre2HistoryAcknowledgement(batch: f.request(1)).dictionary)
                    expect(f.disk.pending.isEmpty)
                }
            }),
            ("Failed acknowledgement persistence preserves both the outbox and background fallback", {
                let f = try Fixture(reachable: false)
                let transfer = f.session.outstandingUserInfoTransfers[0]
                f.session.isReachable = true
                f.sync.flush()
                let first = f.disk.batch!
                let acknowledgement = try Libre2HistoryAcknowledgement(batch: first).dictionary
                f.failPersistence = true
                expect(f.sync.receive(acknowledgement))
                expect(!transfer.isCancelled && f.disk.batch == first && f.session.requests.isEmpty)
                f.failPersistence = false
                f.sync.resume()
                expect(f.session.requests.isEmpty)
                expect(f.sync.receive(acknowledgement))
                expect(transfer.isCancelled && f.disk.pending.isEmpty)
            }),
            ("Restart sends the latest persisted reading without promoting an existing history transfer", {
                let f = try Fixture(reachable: false)
                let first = f.disk.batch!
                let restored = Libre2HistoryQueue(state: f.disk) { _ in }
                let sync = Libre2WatchHistorySync(queue: restored)
                f.session.isReachable = true
                sync.flush()
                expect(f.session.requests.isEmpty && f.session.latestRequests.count == 1)
                expect(try Libre2HistoryBatch.decode(f.session.latestRequests[0].message).readings == [f.current])
                expect(f.session.outstandingUserInfoTransfers.count == 1)
                expect(sync.receive(try Libre2HistoryAcknowledgement(batch: first).dictionary))
                expect(restored.state.pending.isEmpty && f.session.outstandingUserInfoTransfers.isEmpty)
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

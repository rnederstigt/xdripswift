// Run with Scripts/check_history_delivery.py. Database operations are storage spies;
// receive, importNext and respond are taken unchanged from the production coordinator.
#if LIBRE2_PHONE_HISTORY_TESTS
import Foundation

enum Libre2HandoffError: Error { case invalidSession }
enum ConstantsFollower { static let maximumBgReadingAgeForAlertsInSeconds: TimeInterval = 300 }
final class Libre2ActivityLog {
    static let shared = Libre2ActivityLog()
    var isTracingEnabled = true
    var deliveryEvents: [(event: String, reading: Libre2HistoryReading, details: String, date: Date)] = []
    func record(_ message: String) {}
    func recordDelivery(_ event: String, reading: Libre2HistoryReading, details: String = "", now: Date = Date()) {
        deliveryEvents.append((event, reading, details, now))
    }
}
final class Libre2HistoryRegistry {}
final class CoreDataManager {
    var saved: [Libre2HistoryBatch] = []
    var failNextSave = false
    var rejectNextSave = false
    var pauseNextSave = false
    var resumeSave: CheckedContinuation<Void, Never>?
}
final class WCSession {
    enum Activation { case activated }
    let activationState = Activation.activated
    var transfers: [[String: Any]] = []
    func transferUserInfo(_ message: [String: Any]) { transfers.append(message) }
}

final class WatchManager {
    let directLibreHistory: Libre2PhoneHistorySync
    init(_ sync: Libre2PhoneHistorySync) { directLibreHistory = sync }
}

@main
private enum PhoneHistoryDeliveryTests {
    @MainActor static func main() async throws {
        let store = CoreDataManager(), session = WCSession()
        let sync = Libre2PhoneHistorySync(coreDataManager: store, session: session)
        let sensorSession = UUID(), uid = Data(repeating: 1, count: 8)
        func batch(_ minute: UInt16) -> Libre2HistoryBatch {
            Libre2HistoryBatch(readings: [.init(sessionID: sensorSession, sensorUID: uid,
                sensorMinute: minute, date: Date().addingTimeInterval(Double(Int(minute) - 122) * 60), glucose: 120)])
        }
        let first = batch(100), history = batch(101), earlier = batch(118), latest = batch(119)
        var replies: [UUID] = [], superseded: [UUID] = [], dates: [Date] = []
        let observer = NotificationCenter.default.addObserver(
            forName: Libre2PhoneHistorySync.didImport, object: nil, queue: nil
        ) { notification in
            if let date = notification.userInfo?[Libre2PhoneHistoryUpdate.currentReadingDateKey] as? Date {
                dates.append(date)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        func enqueue(_ batch: Libre2HistoryBatch, live: Bool) throws {
            let message = try live ? batch.latestDictionary : batch.dictionary
            precondition(sync.receive(message) { reply in
                if reply["superseded"] as? Bool == true {
                    precondition(reply[Libre2HistoryAcknowledgement.key] == nil)
                    superseded.append(batch.id)
                } else {
                    precondition(try! Libre2HistoryAcknowledgement.decode(reply).batchID == batch.id)
                    precondition(store.saved.contains(batch))
                    replies.append(batch.id)
                }
            })
        }
        try enqueue(first, live: false)
        try enqueue(history, live: false)
        try enqueue(earlier, live: true)
        try enqueue(latest, live: true)
        // An out-of-order live message must not replace a newer one that is waiting.
        try enqueue(earlier, live: true)
        for _ in 0..<10_000 where replies.count < 3 { await Task.yield() }
        precondition(replies == [first.id, latest.id, history.id])
        precondition(superseded == [earlier.id, earlier.id])
        precondition(dates == [latest.readings[0].date])
        let latestEvents = Libre2ActivityLog.shared.deliveryEvents.filter { $0.reading == latest.readings[0] }
        precondition(latestEvents.map(\.event) == ["Phone received latest", "Phone import started", "Phone saved (1 inserted)"])
        print("PASS: Latest import follows the current save and precedes queued history; older live messages coalesce without save acknowledgements")

        try enqueue(latest, live: false)
        for _ in 0..<10_000 where replies.count < 4 { await Task.yield() }
        precondition(replies.count == 4 && dates.count == 1)
        print("PASS: Historical redelivery of the latest value does not repeat current-reading notification")

        store.failNextSave = true
        var failed = false
        let failingMessage = try batch(120).latestDictionary
        precondition(sync.receive(failingMessage) { reply in
            precondition(reply["error"] != nil && reply[Libre2HistoryAcknowledgement.key] == nil)
            failed = true
        })
        for _ in 0..<10_000 where !failed { await Task.yield() }
        precondition(failed && replies.count == 4 && dates.count == 1)
        precondition(session.transfers.isEmpty)
        precondition(Libre2ActivityLog.shared.deliveryEvents.last!.event.hasPrefix("Phone import failed:"))
        print("PASS: Latest import failure cannot acknowledge storage or announce a current reading")
        let recordedAt = Date().addingTimeInterval(-3)
        let receipt = Libre2PhoneHistorySync.Receipt(route: "userInfo", date: recordedAt,
            uptime: ProcessInfo.processInfo.systemUptime - 3)
        let diagnosticBatch = batch(121)
        let diagnosticMessage = try diagnosticBatch.dictionary
        precondition(sync.receive(diagnosticMessage, receipt: receipt))
        let events = Libre2ActivityLog.shared.deliveryEvents.filter { $0.reading == diagnosticBatch.readings[0] }
        precondition(events.map(\.event) == ["Phone callback entered", "Phone main handler started", "Phone received history"])
        precondition(events[0].date == recordedAt && events[1].date > recordedAt)
        precondition(events[0].details.contains("route=userInfo"))
        let delay = Double(events[1].details.components(separatedBy: "mainQueueWaitMs=")[1])!
        precondition(delay >= 3_000 && delay < 4_000)
        let eventCount = Libre2ActivityLog.shared.deliveryEvents.count
        precondition(!sync.receive(["ordinary": true], receipt: receipt))
        precondition(Libre2ActivityLog.shared.deliveryEvents.count == eventCount)
        for _ in 0..<10_000 where session.transfers.isEmpty { await Task.yield() }
        let acknowledgement = try Libre2HistoryAcknowledgement.decode(session.transfers[0])
        precondition(acknowledgement.batchID == diagnosticBatch.id)
        print("PASS: Callback timing survives the main-queue wait and ignores unrelated messages")
        let manager = WatchManager(sync)
        let context = batch(122)
        let transfersBefore = session.transfers.count
        let datesBefore = dates.count
        manager.session(session, didReceiveApplicationContext: try context.latestDictionary)
        for _ in 0..<10_000 where !store.saved.contains(context) { await Task.yield() }
        precondition(store.saved.contains(context) && dates.count == datesBefore + 1)
        precondition(session.transfers.count == transfersBefore)
        let contextEvents = Libre2ActivityLog.shared.deliveryEvents.filter { $0.reading == context.readings[0] }
        precondition(contextEvents.map(\.event) == ["Phone callback entered", "Phone main handler started",
            "Phone received latest", "Phone import started", "Phone saved (1 inserted)"])
        precondition(contextEvents[0].details.contains("route=applicationContext"))
        print("PASS: Production application-context delegate imports latest data, records callback timing and sends no history acknowledgement")

        let savesBefore = store.saved.count
        // A late/duplicate context must not announce an older value as current.
        manager.session(session, didReceiveApplicationContext: try earlier.latestDictionary)
        manager.session(session, didReceiveApplicationContext: try context.latestDictionary)
        for _ in 0..<10_000 where store.saved.count < savesBefore + 2 { await Task.yield() }
        precondition(store.saved.count == savesBefore + 2 && dates.count == datesBefore + 1)
        precondition(session.transfers.count == transfersBefore)
        for _ in 0..<100 { await Task.yield() }
        let eventsBefore = Libre2ActivityLog.shared.deliveryEvents.count
        manager.session(session, didReceiveApplicationContext: ["ordinary": true])
        manager.session(session, didReceiveApplicationContext: try history.dictionary)
        for _ in 0..<10 { await Task.yield() }
        precondition(Libre2ActivityLog.shared.deliveryEvents.count == eventsBefore)
        precondition(store.saved.count == savesBefore + 2)
        print("PASS: Late/duplicate contexts do not repeat current-reading effects; unrelated or historical contexts are ignored")
        // Multiple routes share only an in-flight save; each sender keeps its own batch ID.
        for outcome in ["success", "failure", "rejection"] {
            let a = batch(123), b = Libre2HistoryBatch(readings: a.readings)
            let c = Libre2HistoryBatch(readings: a.readings)
            store.pauseNextSave = true
            store.failNextSave = outcome == "failure"
            store.rejectNextSave = outcome == "rejection"
            let saveCount = store.saved.count, transferCount = session.transfers.count
            var liveReply: [String: Any]?
            let live = try a.latestDictionary
            precondition(sync.receive(live) { liveReply = $0 })
            for _ in 0..<10_000 where store.resumeSave == nil { await Task.yield() }
            precondition(store.resumeSave != nil)
            // Background history requires a queued acknowledgement, context requires none.
            let historical = try b.dictionary
            precondition(sync.receive(historical))
            let background = try c.latestDictionary
            precondition(sync.receive(background))
            precondition(liveReply == nil && session.transfers.count == transferCount)
            let continuation = store.resumeSave!
            store.resumeSave = nil
            continuation.resume()
            for _ in 0..<10_000 where liveReply == nil { await Task.yield() }
            precondition(liveReply != nil)
            if outcome == "success" {
                precondition(store.saved.count == saveCount + 1)
                precondition(try! Libre2HistoryAcknowledgement.decode(liveReply!).batchID == a.id)
                precondition(session.transfers.count == transferCount + 1)
                precondition(try! Libre2HistoryAcknowledgement.decode(session.transfers.last!).batchID == b.id)
            } else if outcome == "rejection" {
                precondition(store.saved.count == saveCount)
                precondition(try! Libre2HistoryRejection.decode(liveReply!).batchID == a.id)
                precondition(session.transfers.count == transferCount + 1)
                precondition(try! Libre2HistoryRejection.decode(session.transfers.last!).batchID == b.id)
            } else {
                precondition(liveReply!["error"] != nil)
                precondition(store.saved.count == saveCount && session.transfers.count == transferCount)
            }
            print("PASS: Shared in-flight import \(outcome) preserves per-batch responses and never acknowledges early")
        }
        print("9 phone import scheduling/diagnostic checks passed (storage spies, not Core Data).")
    }
}
#endif

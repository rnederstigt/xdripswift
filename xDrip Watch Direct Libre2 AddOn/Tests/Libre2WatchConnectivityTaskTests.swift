// Run with Scripts/check_watch_background_tasks.py; real KVO and main-queue dispatch.
#if LIBRE2_BACKGROUND_TASK_TESTS
import Foundation

@objc enum WCSessionActivationState: Int { case notActivated, inactive, activated }
final class WCSession: NSObject {
    static let `default` = WCSession()
    @objc dynamic var activationState = WCSessionActivationState.notActivated
    @objc dynamic var hasContentPending = false
}

// Capture diagnostics without introducing WatchKit into this host-side scheduling test.
enum Libre2LifecycleDiagnostics {
    static var events: [(String, String)] = []
    static func recordSession(_ name: String, session: WCSession, details: String = "") {
        events.append((name, details))
    }
}

@main private enum BackgroundTaskTests {
    @MainActor static func main() async {
        func settle() async { for _ in 0..<100 { await Task.yield() } }
        let session = WCSession()
        let tasks = Libre2WatchConnectivityTasks(session: session)
        var finished = false
        let initial = Task { @MainActor in await tasks.handle(); finished = true }
        await settle()
        precondition(!finished)
        session.hasContentPending = true
        session.activationState = .activated
        await settle()
        precondition(!finished)
        session.hasContentPending = false
        await initial.value
        precondition(finished)
        print("PASS: Waits for activation and pending content before completing")

        var events: [String] = []
        // This nested main-queue work models the queued revoke path in WatchStateModel.
        tasks.receive {
            events.append("receipt")
            tasks.receive { events.append("nested receipt") }
        }
        await tasks.handle()
        events.append("completed")
        precondition(events == ["receipt", "nested receipt", "completed"])
        print("PASS: Framework completion cannot overtake queued or nested receipt processing")

        session.hasContentPending = true
        let cancelled = Task { @MainActor in await tasks.handle() }
        var otherFinished = false
        let other = Task { @MainActor in await tasks.handle(); otherFinished = true }
        await settle()
        cancelled.cancel()
        await cancelled.value
        precondition(!otherFinished)
        session.hasContentPending = false
        await other.value
        precondition(otherFinished)
        print("PASS: Expiration releases its waiter without completing another task")

        session.hasContentPending = true
        let inactive = Task { @MainActor in await tasks.handle() }
        await settle()
        session.activationState = .inactive
        await inactive.value
        print("PASS: Inactive sessions release background tasks")

        // Repeat cancellation/registration to exercise either ordering and observer reuse.
        session.activationState = .activated
        for _ in 0..<20 {
            let task = Task { @MainActor in await tasks.handle() }
            task.cancel()
            await task.value
        }
        session.hasContentPending = false
        await tasks.handle()
        print("PASS: Early cancellation and repeated tasks leave no stranded continuation")

        let starts = Libre2LifecycleDiagnostics.events.filter { $0.0 == "WC background task started" }
        let finishes = Libre2LifecycleDiagnostics.events.filter { $0.0 == "WC background task finished" }
        precondition(!starts.isEmpty && starts.count == finishes.count)
        for start in starts {
            precondition(finishes.filter { $0.1.hasPrefix(start.1 + " ") }.count == 1)
        }
        precondition(finishes.contains { $0.1.contains("cancelled=true") })
        precondition(finishes.contains { $0.1.contains("cancelled=false") })
        print("PASS: Lifecycle records pair every started task with exactly one completion or cancellation")
    }
}
#endif

import Foundation
import WatchConnectivity

/// Finishes system-provided WatchConnectivity tasks after the framework and our main-queue
/// receipts drain. It neither activates another session nor requests extra background time.
// Mutable state is either main-actor isolated or protected by lock.
final class Libre2WatchConnectivityTasks: @unchecked Sendable {
    static let shared = Libre2WatchConnectivityTasks()
    private let session: WCSession
    private let lock = NSLock()
    private var pendingReceipts = 0
    @MainActor private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @MainActor private var observations: [NSKeyValueObservation] = []

    init(session: WCSession = .default) { self.session = session }

    /// Reserve before dispatching: hasContentPending can become false before main runs.
    /// Nested receipts reserve their own work, including asynchronous revoke handling.
    func receive(_ action: @escaping () -> Void) {
        lock.lock()
        pendingReceipts += 1
        lock.unlock()
        DispatchQueue.main.async {
            action()
            self.lock.lock()
            self.pendingReceipts -= 1
            self.lock.unlock()
            self.finishIfReady()
        }
    }

    @MainActor func handle() async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        Libre2LifecycleDiagnostics.recordSession("WC background task started", session: session,
            details: "task=\(id.uuidString.prefix(8))")
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                if observations.isEmpty {
                    observations = [
                        session.observe(\.activationState) { [weak self] _, _ in self?.stateChanged() },
                        session.observe(\.hasContentPending) { [weak self] _, _ in self?.stateChanged() }
                    ]
                }
                finishIfReady()
            }
        } onCancel: {
            // SwiftUI cancels the task when its execution allowance expires.
            Task { @MainActor in self.finish(id, cancelled: true) }
        }
    }

    private func stateChanged() {
        Libre2LifecycleDiagnostics.recordSession("WC background task state changed", session: session)
        DispatchQueue.main.async { self.finishIfReady() }
    }

    @MainActor private func finishIfReady() {
        lock.lock()
        let receiving = pendingReceipts > 0
        lock.unlock()
        guard !receiving else { return }
        // Wait for initial activation; an inactive session cannot deliver more content.
        guard session.activationState == .inactive
            || (session.activationState == .activated && !session.hasContentPending) else { return }
        for id in Array(waiters.keys) { finish(id) }
    }

    @MainActor private func finish(_ id: UUID, cancelled: Bool = false) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        if waiters.isEmpty { observations.removeAll() }
        Libre2LifecycleDiagnostics.recordSession("WC background task finished", session: session,
            details: "task=\(id.uuidString.prefix(8)) cancelled=\(cancelled)")
        continuation.resume()
    }
}

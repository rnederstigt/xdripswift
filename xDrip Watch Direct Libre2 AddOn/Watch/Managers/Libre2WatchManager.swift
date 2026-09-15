import Foundation

/// The Watch host supplies its existing history and accepts display updates.
protocol Libre2WatchDisplay: AnyObject {
    var libreReadingHistory: [Libre2Sample] { get }
    var libreUsesMgDl: Bool { get }
    var libreLatestReadingDate: Date? { get }
    func applyLibreReadings(_ batch: Libre2ReadingBatch)
    func updateDirectLibreSensorAge(_ age: UInt16)
    func refreshLibreConnectionStatus()
}

/// One entry point for Watch messages, source selection and reading conversion.
/// The handoff controller continues to own the collector and persisted transaction.
final class Libre2WatchManager {
    private weak var display: Libre2WatchDisplay?
    private let handoff = Libre2WatchHandoff()
    private let historySync = Libre2WatchHistorySync()
    private let locationSession = Libre2WatchLocationSession()

    init(display: Libre2WatchDisplay) {
        self.display = display
        handoff.onCollectedReading = { [weak self] sample, sensorMinute, session in
            self?.historySync.collect(sample, sensorMinute: sensorMinute, session: session)
        }
        handoff.onStatus = { [weak self] _ in
            self?.display?.refreshLibreConnectionStatus()
        }
        handoff.onReadings = { [weak self] samples, sensorAge in
            self?.acceptDirectReadings(samples, sensorAge: sensorAge)
        }
    }

    var isDirect: Bool { handoff.isDirect }
    var isConnected: Bool { handoff.isConnected }
    var indicatorText: String { handoff.indicatorText }

    func restore() { handoff.restore() }

    func retryConnection() { handoff.retryConnection() }

    func connectionActivated() { historySync.resume() }

    /// Existing host hook also accepts sensor-matching rejections; no extra WCSession route is needed.
    @discardableResult
    func receiveHistoryAcknowledgement(_ dictionary: [String: Any]) -> Bool {
        historySync.receive(dictionary)
    }

    func receive(_ dictionary: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            if self.locationSession.receive(dictionary, reply: reply) { return }
            if self.historySync.receiveCleanup(dictionary, reply: reply) { return }
            guard dictionary[Libre2HandoffMessage.key] != nil else { reply([:]); return }
            self.handoff.receive(dictionary, reply: reply)
        }
    }

    func recordReachability() {
        DispatchQueue.main.async {
            self.handoff.recordReachability()
            self.historySync.flush()
        }
    }

    // MARK: - Direct collection display path (phone relay stays in the host)

    private func acceptDirectReadings(_ samples: [Libre2Sample], sensorAge: UInt16) {
        guard let display else { return }
        display.updateDirectLibreSensorAge(sensorAge)
        let history = Libre2ReadingPipeline.merging(samples, with: display.libreReadingHistory)
        let trend = Libre2ReadingPipeline.trend(from: history, isMgDl: display.libreUsesMgDl)
        accept(
            Libre2ReadingBatch(
                values: history.map(\.glucoseLevelRaw),
                dates: history.map { $0.timeStamp.timeIntervalSince1970 },
                slope: trend.slopeOrdinal,
                delta: trend.delta,
                generatedAt: Date()))
    }

    @discardableResult
    private func accept(_ batch: Libre2ReadingBatch) -> Bool {
        guard let display, batch.isAcceptable(after: display.libreLatestReadingDate) else { return false }
        display.applyLibreReadings(batch)
        return true
    }
}

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
final class Libre2WatchAddOn {
    private weak var display: Libre2WatchDisplay?
    private let handoff = Libre2WatchHandoff()
    private let historySync = Libre2WatchHistorySync()
    private(set) var status = Texts_DirectLibre.phoneRelay

    init(display: Libre2WatchDisplay) {
        self.display = display
        handoff.onCollectedReading = { [weak self] sample, sensorMinute, session in
            self?.historySync.collect(sample, sensorMinute: sensorMinute, session: session)
        }
        handoff.onStatus = { [weak self] status in
            self?.status = status
            self?.display?.refreshLibreConnectionStatus()
        }
        handoff.onReadings = { [weak self] samples, sensorAge in
            self?.acceptDirectReadings(samples, sensorAge: sensorAge)
        }
    }

    var isDirect: Bool { handoff.isDirect }
    var isReceiving: Bool { handoff.isReceiving }
    var indicatorText: String { handoff.indicatorText }

    var glucoseSourceStatus: String {
        let stale = display?.libreReadingHistory.first.map {
            Date().timeIntervalSince($0.timeStamp) > ConstantsLibre2.recentReadingInterval
        } ?? true
        return Texts_DirectLibre.readingStatus(source: (isDirect ? WatchGlucoseSource.directLibre2 : .phoneRelay).title, isStale: stale)
    }

    func restore() { handoff.restore() }

    func connectionActivated() { historySync.resume() }

    @discardableResult
    func receiveHistoryAcknowledgement(_ dictionary: [String: Any]) -> Bool {
        historySync.receive(dictionary)
    }

    func receive(_ dictionary: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard dictionary[Libre2HandoffMessage.key] != nil else { reply([:]); return }
        DispatchQueue.main.async { self.handoff.receive(dictionary, reply: reply) }
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
        let trend = Libre2ReadingPipeline.trend(from: history)
        accept(
            Libre2ReadingBatch(
                values: history.map(\.glucoseLevelRaw),
                dates: history.map { $0.timeStamp.timeIntervalSince1970 },
                slope: trend.slopeOrdinal,
                delta: display.libreUsesMgDl ? trend.delta : trend.delta / 18.0182,
                generatedAt: Date()))
    }

    @discardableResult
    private func accept(_ batch: Libre2ReadingBatch) -> Bool {
        guard let display, batch.isAcceptable(after: display.libreLatestReadingDate) else { return false }
        display.applyLibreReadings(batch)
        return true
    }
}

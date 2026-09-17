import Foundation

/// A small local activity journal. Call on main; never pass sensor credentials or payloads.
final class Libre2ActivityLog {
    static let shared = Libre2ActivityLog(shouldRecord: {
        Libre2SessionStore.shared.snapshot.hasExperimentalState
    })
    static let didChange = Notification.Name("Libre2ActivityLogDidChange")
    static let maximumEntries = 240
    static let requestKey = "libre2ActivityLogRequest"
    private static let entriesKey = "libre2ActivityLogEntries"
    private static let maximumSnapshotBytes = 60_000
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let storageKey = "phoneControlledLibreActivityLog"
    private let defaults: UserDefaults
    private let shouldRecord: () -> Bool
    var isPageVisible = false
    private(set) var entries: [Libre2DiagnosticEntry]

    init(defaults: UserDefaults = .standard, shouldRecord: @escaping () -> Bool = { true }) {
        self.defaults = defaults
        self.shouldRecord = shouldRecord
        let saved = defaults.data(forKey: Self.storageKey)
        let decoded = saved.flatMap { try? JSONDecoder().decode([Libre2DiagnosticEntry].self, from: $0) } ?? []
        entries = Array(decoded.suffix(Self.maximumEntries))
    }

    func record(_ message: String, now: Date = Date()) {
        // Diagnostics stay dormant outside experiment/page use.
        guard isPageVisible || shouldRecord() else { return }
        guard !message.isEmpty, entries.last?.message != message else { return }
        entries.append(Libre2DiagnosticEntry(id: UUID(), date: now, message: message))
        entries = Array(entries.suffix(Self.maximumEntries))
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Explicit read-only snapshot request. No automatic transfers.
    @discardableResult
    func receive(_ dictionary: [String: Any], reply: ([String: Any]) -> Void) -> Bool {
        guard dictionary[Self.requestKey] != nil else { return false }
        do {
            guard dictionary[Self.requestKey] as? Bool == true else { throw Libre2HistoryError.invalidBatch }
            var recent = entries
            var data = try JSONEncoder().encode(recent)
            // Preserve the newest records if unusually long error messages exceed the budget.
            while data.count > Self.maximumSnapshotBytes, !recent.isEmpty {
                recent.removeFirst()
                data = try JSONEncoder().encode(recent)
            }
            reply([Self.entriesKey: data])
        } catch { reply(["error": error.localizedDescription]) }
        return true
    }

    static func decodeSnapshot(_ dictionary: [String: Any]) throws -> [Libre2DiagnosticEntry] {
        guard let data = dictionary[entriesKey] as? Data, data.count <= maximumSnapshotBytes else {
            throw Libre2HistoryError.invalidBatch
        }
        let entries = try JSONDecoder().decode([Libre2DiagnosticEntry].self, from: data)
        guard entries.count <= maximumEntries, Set(entries.map(\.id)).count == entries.count,
            entries.allSatisfy({ $0.date.timeIntervalSince1970.isFinite }) else {
            throw Libre2HistoryError.invalidBatch
        }
        return entries
    }

    static func report(phone: [Libre2DiagnosticEntry], watch: [Libre2DiagnosticEntry], capturedAt: Date?) -> String {
        let records = (phone.map { ("iPhone", $0) } + watch.map { ("Watch", $0) })
            .sorted { $0.1.date < $1.1.date }
        let snapshot = capturedAt.map { timestampFormatter.string(from: $0) } ?? "not loaded"
        return "Direct Libre activity (UTC)\nWatch snapshot: \(snapshot)\n"
            + records.map { source, entry in
                "\(timestampFormatter.string(from: entry.date)) [\(source)] \(entry.message)"
            }.joined(separator: "\n")
    }

    /// This never touches the ownership journal or the sensor unlock counter.
    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

import Foundation

/// A small local activity journal. Call on main; never pass sensor credentials or payloads.
final class Libre2ActivityLog {
    struct Entry: Codable, Identifiable {
        let id: UUID
        let date: Date
        let message: String
    }

    static let shared = Libre2ActivityLog(shouldRecord: {
        Libre2SessionStore.shared.snapshot.hasExperimentalState
    })
    static let didChange = Notification.Name("Libre2ActivityLogDidChange")
    static let maximumEntries = 240
    static let requestKey = "libre2ActivityLogRequest"
    static let tracingKey = "libre2DetailedDiagnostics"
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
    private(set) var entries: [Entry]

    var isTracingEnabled: Bool {
        get { defaults.bool(forKey: Self.tracingKey) }
        set { defaults.set(newValue, forKey: Self.tracingKey) }
    }

    init(defaults: UserDefaults = .standard, shouldRecord: @escaping () -> Bool = { true }) {
        self.defaults = defaults
        self.shouldRecord = shouldRecord
        let saved = defaults.data(forKey: Self.storageKey)
        let decoded = saved.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = Array(decoded.suffix(Self.maximumEntries))
    }

    func record(_ message: String, now: Date = Date()) {
        // Diagnostics stay dormant outside experiment/page use.
        guard isPageVisible || shouldRecord() else { return }
        guard !message.isEmpty, entries.last?.message != message else { return }
        entries.append(Entry(id: UUID(), date: now, message: message))
        entries = Array(entries.suffix(Self.maximumEntries))
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Correlate both devices without glucose values, sensor UID or unlock credentials.
    func recordDelivery(_ event: String, reading: Libre2HistoryReading, details: String = "", now: Date = Date()) {
        guard isTracingEnabled else { return }
        record("Delivery: \(event) | sample=\(Self.timestampFormatter.string(from: reading.date))"
            + " minute=\(reading.sensorMinute) handoff=\(reading.sessionID.uuidString.prefix(8))"
            + (details.isEmpty ? "" : " | \(details)"), now: now)
    }

    func recordTrace(_ message: @autoclosure () -> String) {
        guard isTracingEnabled else { return }
        record(message())
    }

    /// Explicit snapshot request, optionally changing tracing. No automatic transfers.
    @discardableResult
    func receive(_ dictionary: [String: Any], additionalEntries: [Entry] = [], reply: ([String: Any]) -> Void) -> Bool {
        guard dictionary[Self.requestKey] != nil else { return false }
        do {
            guard dictionary[Self.requestKey] as? Bool == true else { throw Libre2HistoryError.invalidBatch }
            if let enabled = dictionary[Self.tracingKey] {
                guard let enabled = enabled as? Bool else { throw Libre2HistoryError.invalidBatch }
                isTracingEnabled = enabled
                record(enabled ? "Detailed diagnostics enabled." : "Detailed diagnostics disabled.")
            }
            var recent = Array((entries + additionalEntries).sorted { $0.date < $1.date }.suffix(Self.maximumEntries))
            var data = try JSONEncoder().encode(recent)
            // Preserve the newest records if unusually long error messages exceed the budget.
            while data.count > Self.maximumSnapshotBytes, !recent.isEmpty {
                recent.removeFirst()
                data = try JSONEncoder().encode(recent)
            }
            reply([Self.entriesKey: data, Self.tracingKey: isTracingEnabled])
        } catch { reply(["error": error.localizedDescription]) }
        return true
    }

    static func decodeSnapshot(_ dictionary: [String: Any]) throws -> [Entry] {
        guard let data = dictionary[entriesKey] as? Data, data.count <= maximumSnapshotBytes else {
            throw Libre2HistoryError.invalidBatch
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        guard entries.count <= maximumEntries, Set(entries.map(\.id)).count == entries.count,
            entries.allSatisfy({ $0.date.timeIntervalSince1970.isFinite }) else {
            throw Libre2HistoryError.invalidBatch
        }
        return entries
    }

    static func report(phone: [Entry], watch: [Entry], capturedAt: Date?) -> String {
        let records = (phone.map { ("iPhone", $0) } + watch.map { ("Watch", $0) })
            .sorted { $0.1.date < $1.1.date }
        let snapshot = capturedAt.map { timestampFormatter.string(from: $0) } ?? "not loaded"
        return "Direct Libre delivery diagnostics (UTC)\nWatch snapshot: \(snapshot)\n"
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

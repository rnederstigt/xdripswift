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
    static let maximumEntries = 80
    private static let storageKey = "phoneControlledLibreActivityLog"
    private let defaults: UserDefaults
    private let shouldRecord: () -> Bool
    var isPageVisible = false
    private(set) var entries: [Entry]

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

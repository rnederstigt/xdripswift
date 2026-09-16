import Foundation

/// The complication is a separate process. It alone writes this bounded journal in the
/// app group; Watch cache-write diagnostics stay in the Watch's ordinary activity log.
final class Libre2ComplicationDiagnostics {
    struct Entry: Codable {
        let id: UUID
        let date: Date
        let message: String
    }

    static let shared = Libre2ComplicationDiagnostics(
        defaults: (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String)
            .flatMap { UserDefaults(suiteName: $0) },
        namespace: Bundle.main.object(forInfoDictionaryKey: "MainAppBundleIdentifier") as? String ?? "unconfigured")
    static let maximumEntries = 240
    private let defaults: UserDefaults?
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults?, namespace: String) {
        self.defaults = defaults
        key = "directLibreComplicationDiagnostics.\(namespace)"
    }

    /// Written by the Watch app, read by the complication. This flag only enables logging.
    func setEnabled(_ enabled: Bool) {
        guard defaults?.bool(forKey: key + ".enabled") != enabled else { return }
        defaults?.set(enabled, forKey: key + ".enabled")
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return readEntries()
    }

    func record(_ event: String, value: Double?, sampleDate: Date?, displayValue: String,
                details: String = "", now: Date = Date()) {
        guard defaults?.bool(forKey: key + ".enabled") == true else { return }
        lock.lock()
        defer { lock.unlock() }
        var records = readEntries()
        records.append(Entry(id: UUID(), date: now, message: Self.message(event,
            value: value, sampleDate: sampleDate, displayValue: displayValue, details: details)))
        if let data = try? JSONEncoder().encode(Array(records.suffix(Self.maximumEntries))) {
            defaults?.set(data, forKey: key)
        }
    }

    static func message(_ event: String, value: Double?, sampleDate: Date?, displayValue: String,
                        details: String = "") -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sample = sampleDate.flatMap { $0.timeIntervalSince1970.isFinite ? formatter.string(from: $0) : nil } ?? "none"
        let glucose = value.flatMap { $0.isFinite ? String($0) : nil } ?? "none"
        return "Complication: \(event) | sample=\(sample) mgdL=\(glucose) display=\(displayValue)"
            + (details.isEmpty ? "" : " | \(details)")
    }

    private func readEntries() -> [Entry] {
        guard let data = defaults?.data(forKey: key),
            let records = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return Array(records.suffix(Self.maximumEntries))
    }
}

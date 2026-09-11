import Foundation

/// Uploads contain converted mg/dL, never sensor credentials or display-clamped values.
/// Sensor minutes identify measurements across reconnects, retries and separate handoffs.
struct Libre2HistoryReading: Codable, Equatable {
    let sessionID: UUID
    let sensorUID: Data
    let sensorMinute: UInt16
    let date: Date
    let glucose: Double

    var sensorKey: String { sensorUID.map { String(format: "%02x", $0) }.joined() }
    var id: String { "direct-libre-watch:\(sensorKey):\(sensorMinute)" }

    func validate(now: Date = Date()) throws {
        guard sensorUID.count == 8, sensorMinute >= ConstantsLibre2.minimumSensorAgeInMinutes,
            date.timeIntervalSince1970.isFinite, date > Date(timeIntervalSince1970: 0),
            date <= now.addingTimeInterval(300), glucose.isFinite,
            glucose > 0, glucose < ConstantsLibre2.maximumValidGlucose
        else { throw Libre2HistoryError.invalidReading }
    }
}

struct Libre2HistoryBatch: Codable, Equatable {
    static let key = "libre2HistoryBatch"
    static let maximumReadings = 120
    let version: Int
    let id: UUID
    let readings: [Libre2HistoryReading]

    init(readings: [Libre2HistoryReading]) {
        version = 1
        id = UUID()
        self.readings = readings
    }

    func validate(now: Date = Date()) throws {
        guard version == 1, !readings.isEmpty, readings.count <= Self.maximumReadings,
            Set(readings.map(\.id)).count == readings.count
        else { throw Libre2HistoryError.invalidBatch }
        try readings.forEach { try $0.validate(now: now) }
    }

    var dictionary: [String: Any] { get throws { [Self.key: try JSONEncoder().encode(self)] } }

    static func decode(_ dictionary: [String: Any]) throws -> Self {
        guard let data = dictionary[key] as? Data, data.count <= 100_000 else {
            throw Libre2HistoryError.invalidBatch
        }
        let batch = try JSONDecoder().decode(Self.self, from: data)
        try batch.validate()
        return batch
    }
}

/// This is an application acknowledgement, sent only after the phone's database save succeeds.
struct Libre2HistoryAcknowledgement: Codable {
    static let key = "libre2HistoryAcknowledgement"
    let batchID: UUID
    let readingIDs: [String]

    init(batch: Libre2HistoryBatch) {
        batchID = batch.id
        readingIDs = batch.readings.map(\.id)
    }

    var dictionary: [String: Any] { get throws { [Self.key: try JSONEncoder().encode(self)] } }

    static func decode(_ dictionary: [String: Any]) throws -> Self {
        guard let data = dictionary[key] as? Data, data.count <= 100_000 else {
            throw Libre2HistoryError.invalidBatch
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

enum Libre2HistoryError: LocalizedError {
    case invalidReading, invalidBatch, unknownSensor, staleAcknowledgement, unavailable

    var errorDescription: String? {
        switch self {
        case .invalidReading: return "Direct Libre history contains an invalid reading."
        case .invalidBatch: return "Direct Libre history format is not supported."
        case .unknownSensor: return "Direct Libre history could not be matched to its original iPhone sensor. Readings remain on the Watch."
        case .staleAcknowledgement: return "Ignored an outdated Direct Libre history acknowledgement."
        case .unavailable: return "Direct Libre history storage is unavailable."
        }
    }
}

/// Small atomic journals, separate from ownership and the unlock counter. A corrupt file is
/// reported to the caller rather than silently replaced with an empty queue or sensor registry.
enum Libre2HistoryFile {
    static func url(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneControlledLibre", isDirectory: true)
            .appendingPathComponent(name)
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL, fallback: T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }
}

import Foundation

/// Interactive settings only: never queue a location start for later delivery.
enum Libre2LocationRequest: Codable, Equatable {
    case inspect
    case setEnabled(Bool)

    static let key = "directLibreLocation"

    var dictionary: [String: Any] {
        get throws { [Self.key: try JSONEncoder().encode(self)] }
    }

    static func decode(_ dictionary: [String: Any]) throws -> Self {
        guard let data = dictionary[key] as? Data else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing location request")) }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

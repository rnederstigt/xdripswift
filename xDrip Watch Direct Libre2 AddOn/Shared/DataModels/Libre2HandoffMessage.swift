import Foundation

/// Message shape used by both existing WatchConnectivity delegates.
/// The proof of concept has a separate message key and requires both updated companion apps.
struct Libre2HandoffMessage: Codable {
    enum Kind: String, Codable {
        case prepare
        case activate
        case returnPrepare
        case returnCommit
        case requestReturn
        case revoke
    }

    static let key = "phoneControlledLibre2Handoff"
    static let retiredIDsKey = "phoneControlledLibre2RetiredIDs"

    /// Retirements survive NFC clearing the session payload. Never infer retirement from age.
    static func retiredIDs(from dictionary: [String: Any]) throws -> Set<UUID>? {
        guard let value = dictionary[retiredIDsKey] else { return nil }
        guard let strings = value as? [String] else { throw Libre2HandoffError.invalidSession }
        let ids = strings.compactMap(UUID.init(uuidString:))
        guard ids.count == strings.count else { throw Libre2HandoffError.invalidSession }
        return Set(ids)
    }

    let kind: Kind
    let session: Libre2WatchSession

    var dictionary: [String: Any] {
        get throws {
            [Self.key: try JSONEncoder().encode(self)]
        }
    }

    static func decode(_ dictionary: [String: Any]) throws -> Self {
        guard let data = dictionary[key] as? Data else {
            throw Libre2HandoffError.invalidSession
        }
        let message = try JSONDecoder().decode(Self.self, from: data)
        try message.session.validate()
        return message
    }
}

enum Libre2HandoffError: Error, LocalizedError {
    case invalidSession
    case staleSession
    case invalidTransition
    case counterExhausted
    case persistence
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidSession:
            return Texts_DirectLibre.invalidSession
        case .staleSession:
            return Texts_DirectLibre.staleSession
        case .invalidTransition:
            return Texts_DirectLibre.invalidTransition
        case .counterExhausted:
            return Texts_DirectLibre.counterExhausted
        case .persistence:
            return Texts_DirectLibre.persistenceFailed
        case .unavailable:
            return Texts_DirectLibre.unavailable
        }
    }
}

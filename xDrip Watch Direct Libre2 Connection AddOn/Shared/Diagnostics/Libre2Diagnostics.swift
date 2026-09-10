import Foundation

struct Libre2ChecklistItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    var showsDetailWhenSatisfied = false
    /// nil means the check cannot run until the handoff reaches its next phase.
    let isSatisfied: Bool?
}

struct Libre2ChecklistGroup: Identifiable {
    enum ID: Hashable { case watch, sensor, phone }
    let id: ID
    let title: String
    let items: [Libre2ChecklistItem]
    var note: String?
}

/// The one phone switch button follows the persisted transaction, not a separate UI toggle.
enum Libre2PhoneSwitchAction: Equatable {
    case switchToWatch, returnToPhone, retryPhoneRecovery, unavailable
}

extension Libre2OwnershipRecord {
    var phoneSwitchAction: Libre2PhoneSwitchAction {
        switch owner {
        case .phone:
            return .switchToWatch
        case .preparingWatch, .releasingPhone, .watch, .returnRequested, .returningToPhone:
            return session == nil ? .unavailable : .returnToPhone
        case .reclaimingPhone, .verifyingPhone:
            return reclaim?.nfcConfirmed == true ? .retryPhoneRecovery : .unavailable
        case .releasingWatch, .failed:
            return .unavailable
        }
    }
}

/// A received BLE reading and permission to transfer are separate observations.
/// This is an in-memory snapshot for the current phone connection, never a cached database reading.
struct Libre2PhoneReadingStatus {
    private(set) var lastReadingAt: Date?
    private(set) var verifiedUnlockCode: UInt32?

    mutating func receivedBLEReading(at date: Date, verifiedUnlockCode: UInt32?) {
        guard lastReadingAt.map({ date >= $0 }) ?? true else { return }
        lastReadingAt = date
        self.verifiedUnlockCode = verifiedUnlockCode
    }

    func hasRecentReading(at now: Date = Date()) -> Bool {
        guard let lastReadingAt else { return false }
        let age = now.timeIntervalSince(lastReadingAt)
        return age >= 0 && age < ConstantsLibre2.recentReadingInterval
    }

    func hasRecentVerifiedReading(at now: Date = Date()) -> Bool {
        verifiedUnlockCode != nil && hasRecentReading(at: now)
    }
}

/// A small local activity journal. Call on main; never pass sensor credentials or payloads.
final class Libre2ActivityLog {
    struct Entry: Codable, Identifiable {
        let id: UUID
        let date: Date
        let message: String
    }

    static let shared = Libre2ActivityLog()
    static let maximumEntries = 80
    private static let storageKey = "phoneControlledLibreActivityLog"
    private let defaults: UserDefaults
    private(set) var entries: [Entry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.storageKey)
        let decoded = saved.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = Array(decoded.suffix(Self.maximumEntries))
    }

    func record(_ message: String, now: Date = Date()) {
        guard !message.isEmpty, entries.last?.message != message else { return }
        entries.append(Entry(id: UUID(), date: now, message: message))
        entries = Array(entries.suffix(Self.maximumEntries))
        save()
    }

    /// This never touches the ownership journal or the sensor unlock counter.
    func clear() {
        entries.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

extension Libre2Owner {
    var displayTitle: String {
        switch self {
        case .phone: return Texts_DirectLibre.phoneOwnsLibre
        case .preparingWatch: return Texts_DirectLibre.preparingWatch
        case .releasingPhone: return Texts_DirectLibre.disconnectingPhone
        case .watch: return Texts_DirectLibre.watchOwnsLibre
        case .returnRequested: return Texts_DirectLibre.returnRequested
        case .returningToPhone, .releasingWatch: return Texts_DirectLibre.returning
        case .reclaimingPhone: return Texts_DirectLibre.reclaimScanning
        case .verifyingPhone: return Texts_DirectLibre.reclaimVerifying
        case .failed: return Texts_DirectLibre.ownershipUnresolved
        }
    }
}

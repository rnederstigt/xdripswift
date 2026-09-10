import Foundation

enum Libre2Owner: String, Codable {
    /// The iPhone can connect and authenticate.
    case phone
    /// PREPARE is persisted. The current phone connection stays open, but new unlocks stop.
    case preparingWatch
    /// Watch replied READY. Phone is disconnecting or retrying ACTIVATE.
    case releasingPhone
    /// Watch may connect and reserve new unlock counters.
    case watch
    /// Watch's counter is frozen while RETURN_PREPARE is acknowledged.
    case returningToPhone
    /// Watch is disconnecting or retrying RETURN_COMMIT.
    case releasingWatch
    /// Phone requested cancellation/return; stale forward callbacks must no longer activate Watch.
    case returnRequested
    /// Explicit NFC recovery has started; phone BLE remains blocked.
    case reclaimingPhone
    /// NFC completed and the previous phone connection closed; a new phone login may proceed.
    case verifyingPhone
    /// A journal error prevents either device from assuming ownership.
    case failed

    // PREPARE freezes new authentication while the existing phone connection remains alive.
    var allowsPhoneConnection: Bool {
        self == .phone || self == .verifyingPhone
    }

    var allowsWatchConnection: Bool {
        self == .watch
    }
}

struct Libre2OwnershipRecord: Codable, Equatable {
    var owner: Libre2Owner = .phone
    var session: Libre2WatchSession?
    var retiredIDs: Set<UUID> = []
    var watchMayHaveConnected = false
    var watchPeripheralID: UUID?
    var reclaim: Libre2ReclaimState?
}

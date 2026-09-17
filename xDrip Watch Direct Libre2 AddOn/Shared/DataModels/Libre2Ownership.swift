import Foundation

/// Persisted handoff phases, not Bluetooth connection status. Keep raw values stable
/// for installed builds; only the phone can request a switch or supersede it via NFC.
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
    /// Ownership is unresolved, including an interrupted NFC reset; BLE remains blocked.
    case failed

    var canRequestReturn: Bool {
        switch self {
        case .preparingWatch, .releasingPhone, .watch, .returnRequested, .returningToPhone: return true
        default: return false
        }
    }

    var isReturningToPhone: Bool {
        self == .returningToPhone || self == .releasingWatch
    }

    // PREPARE freezes new authentication while the existing phone connection remains alive.
    var allowsPhoneConnection: Bool {
        self == .phone
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
    var nfcCredentials: Libre2NFCCredentials?
    /// A user-requested ordinary NFC scan supersedes an abandoned Direct Libre session.
    /// BLE stays blocked until fresh provisioning and confirmed phone disconnect complete.
    var phoneNFCResetCode: UInt32?

    // Preserve the installed journal format while giving the active credential field its current name.
    private enum CodingKeys: String, CodingKey {
        case owner, session, retiredIDs, watchMayHaveConnected, watchPeripheralID, phoneNFCResetCode
        case nfcCredentials = "reclaim"
    }

    /// Every asynchronous reply must still belong to the same transaction and phase.
    func matches(id: UUID, owner: Libre2Owner) -> Bool {
        self.owner == owner && session?.id == id
    }

    /// Returning to phone does not discard credentials needed for later logins/recovery.
    var hasExperimentalState: Bool {
        owner != .phone || session != nil || nfcCredentials != nil || phoneNFCResetCode != nil
    }
}

// MARK: - Journal validation

extension Libre2OwnershipRecord {
    /// Validate stored credentials and the current handoff phase before restoring collection.
    func validateRestoredState() throws {
        try session?.validate()
        try nfcCredentials?.validate()
        if let code = phoneNFCResetCode {
            guard owner == .failed, code != 42, code <= UInt32.max - UInt32(UInt16.max) else {
                throw Libre2HandoffError.invalidSession
            }
        }
        if owner != .phone && owner != .failed && session == nil {
            throw Libre2HandoffError.invalidSession
        }
    }
}

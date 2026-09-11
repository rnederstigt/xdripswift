import Foundation

/// The one phone switch button follows the persisted transaction, not a separate UI toggle.
enum Libre2PhoneSwitchAction: Equatable {
    case switchToWatch, returnToPhone, unavailable
}

extension Libre2OwnershipRecord {
    var phoneSwitchAction: Libre2PhoneSwitchAction {
        switch owner {
        case .phone:
            return .switchToWatch
        case .preparingWatch, .releasingPhone, .watch, .returnRequested, .returningToPhone:
            return session == nil ? .unavailable : .returnToPhone
        case .reclaimingPhone, .verifyingPhone, .releasingWatch, .failed:
            return .unavailable
        }
    }
}

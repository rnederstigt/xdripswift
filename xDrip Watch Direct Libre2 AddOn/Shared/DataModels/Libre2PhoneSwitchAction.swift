import Foundation

/// The one phone switch button follows the persisted transaction, not a separate UI toggle.
enum Libre2PhoneSwitchAction: Equatable {
    case switchToWatch, returnToPhone, unavailable
}

extension Libre2OwnershipRecord {
    var phoneSwitchAction: Libre2PhoneSwitchAction {
        if owner == .phone { return .switchToWatch }
        return owner.canRequestReturn && session != nil ? .returnToPhone : .unavailable
    }
}

import Foundation

struct Libre2ChecklistItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    var showsDetailWhenSatisfied = false
    let isSatisfied: Bool
}

struct Libre2ChecklistGroup: Identifiable {
    enum ID: Hashable { case watch, sensor, phone }
    let id: ID
    let title: String
    let items: [Libre2ChecklistItem]
    var note: String?
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
        case .reclaimingPhone, .verifyingPhone, .failed: return Texts_DirectLibre.ownershipUnresolved
        }
    }
}

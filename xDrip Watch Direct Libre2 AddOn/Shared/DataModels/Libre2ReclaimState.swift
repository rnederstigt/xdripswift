import Foundation

/// Credentials saved after a Direct Libre NFC reset. The legacy name and fields remain
/// Codable-compatible with prototypes that had a separate Reclaim via NFC workflow.
struct Libre2ReclaimState: Codable, Equatable {
    let id: UUID
    let sensorUID: Data
    let unlockCode: UInt32
    var nfcConfirmed = false
    var unlockCount: UInt16 = 0

    func validate() throws {
        guard sensorUID.count == 8, unlockCode <= UInt32.max - UInt32(UInt16.max) else {
            throw Libre2HandoffError.invalidSession
        }
    }
}

import Foundation

/// Credentials retained after an ordinary NFC scan resets Direct Libre.
/// Presence means provisioning completed; an unfinished scan uses phoneNFCResetCode.
struct Libre2NFCCredentials: Codable, Equatable {
    let sensorUID: Data
    let unlockCode: UInt32
    var unlockCount: UInt16 = 0

    func validate() throws {
        guard sensorUID.count == 8, unlockCode <= UInt32.max - UInt32(UInt16.max) else {
            throw Libre2HandoffError.invalidSession
        }
    }
}

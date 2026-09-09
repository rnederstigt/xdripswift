import Foundation

/// Credentials and conversion parameters frozen for one ownership handoff.
/// The Codable property names are part of the persisted and WatchConnectivity formats.
struct Libre2WatchSession: Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let sensorUID: Data
    let patchInfo: Data
    let unlockCode: UInt32
    var unlockCount: UInt16
    let bluetoothName: String
    let sensorSerial: String
    let calibration: Libre2Calibration

    func validate() throws {
        guard sensorUID.count == 8,
              patchInfo.count >= 6,
              unlockCode <= UInt32.max - UInt32(UInt16.max),
              !bluetoothName.isEmpty,
              !sensorSerial.isEmpty,
              calibration.isValid else {
            throw Libre2HandoffError.invalidSession
        }
    }

    /// Counter differences are allowed during return; the handoff and credentials must match.
    func matchesHandoff(_ other: Self) -> Bool {
        id == other.id
            && sensorUID == other.sensorUID
            && patchInfo == other.patchInfo
            && unlockCode == other.unlockCode
            && bluetoothName == other.bluetoothName
            && calibration == other.calibration
    }
}

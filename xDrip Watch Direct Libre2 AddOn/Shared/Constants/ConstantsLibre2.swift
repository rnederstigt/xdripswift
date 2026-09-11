import Foundation

/// Protocol values and timing limits shared by the two Libre transports.
enum ConstantsLibre2 {

    // MARK: - BLE protocol

    static let serviceUUID = "FDE3"
    static let receiveCharacteristicUUID = "F002"
    static let writeCharacteristicUUID = "F001"
    static let encryptedFrameSize = 46
    static let decryptedFrameSize = 44

    // MARK: - Timing

    static let maximumFragmentInterval: TimeInterval = 3
    static let recentReadingInterval: TimeInterval = 180
    static let connectionTimeout: TimeInterval = 30
    static let reconnectDelay: TimeInterval = 5

    // MARK: - Glucose conversion and validation

    static let minimumSensorAgeInMinutes: UInt16 = 60
    static let maximumValidGlucose: Double = 3000
    static let maximumDisplayGlucose: Double = 600
    static let rawGlucoseMultiplier: Double = 117.64705
}

import Foundation

/// Operations the add-on needs from the existing iPhone sensor implementation.
/// The adapter owns xDrip-specific types; handoff and recovery use this interface.
protocol Libre2PhoneSensor: AnyObject {
    var isConnected: Bool { get }
    var usesNativeAlgorithm: Bool { get }
    func prepareDirectWatch(completion: @escaping (Result<Libre2WatchSession, Error>) -> Void)
    func connect()
    func disconnect(completion: @escaping () -> Void)
    func startBLEScanning()
}

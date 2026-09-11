import Foundation

/// Shared Direct Libre strings, following the app's Texts_ convention.
/// English defaults preserve the experimental UI until translations are supplied.
class Texts_DirectLibre {
    private static let filename = "DirectLibre"

    // MARK: - Reading source and connection status

    static let phoneRelay = NSLocalizedString(
        "phoneRelay", tableName: filename, bundle: .main, value: "iPhone Relay",
        comment: "Direct Libre experiment")

    static let prepared = NSLocalizedString(
        "prepared", tableName: filename, bundle: .main, value: "Prepared",
        comment: "Direct Libre experiment")

    static let connecting = NSLocalizedString(
        "connecting", tableName: filename, bundle: .main, value: "Connecting",
        comment: "Direct Libre experiment")

    static let directConnected = NSLocalizedString(
        "directConnected", tableName: filename, bundle: .main, value: "Direct Connected",
        comment: "Direct Libre experiment")

    static let returning = NSLocalizedString(
        "returning", tableName: filename, bundle: .main, value: "Returning",
        comment: "Direct Libre experiment")

    static let preparingWatch = NSLocalizedString(
        "preparingWatch", tableName: filename, bundle: .main, value: "Preparing Watch",
        comment: "Direct Libre experiment")

    static let disconnectingPhone = NSLocalizedString(
        "disconnectingPhone", tableName: filename, bundle: .main, value: "Disconnecting iPhone",
        comment: "Direct Libre experiment")

    static let watchOwnsLibre = NSLocalizedString(
        "watchOwnsLibre", tableName: filename, bundle: .main, value: "Watch selected",
        comment: "Direct Libre experiment")

    static let phoneOwnsLibre = NSLocalizedString(
        "phoneOwnsLibre", tableName: filename, bundle: .main, value: "iPhone selected",
        comment: "Direct Libre experiment")

    // MARK: - Handoff controls

    static let invalidSession = NSLocalizedString(
        "invalidSession", tableName: filename, bundle: .main,
        value: "Invalid Libre session or missing sensor conversion parameters.",
        comment: "Direct Libre experiment")

    static let staleSession = NSLocalizedString(
        "staleSession", tableName: filename, bundle: .main, value: "Stale handoff rejected.",
        comment: "Direct Libre experiment")

    static let invalidTransition = NSLocalizedString(
        "invalidTransition", tableName: filename, bundle: .main,
        value: "Ownership is unresolved. Keep both apps open and retry the current handoff.",
        comment: "Direct Libre experiment")

    static let counterExhausted = NSLocalizedString(
        "counterExhausted", tableName: filename, bundle: .main,
        value: "Libre unlock counter exhausted. Return ownership and provision again on iPhone.",
        comment: "Direct Libre experiment")

    static let persistenceFailed = NSLocalizedString(
        "persistenceFailed", tableName: filename, bundle: .main,
        value: "Could not save Libre ownership. Bluetooth remains disabled.",
        comment: "Direct Libre experiment")

    static let unavailable = NSLocalizedString(
        "unavailable", tableName: filename, bundle: .main,
        value: "A recent supported Libre BLE reading and a reachable Watch are required.",
        comment: "Direct Libre experiment")

    // MARK: - Handoff recovery

    static let waitingForPhoneTransport = NSLocalizedString(
        "waitingForPhoneTransport", tableName: filename, bundle: .main,
        value: "Waiting for Libre transport. Phone Bluetooth remains disabled.",
        comment: "Direct Libre experiment")

    static let waitingForWatchDisconnect = NSLocalizedString(
        "waitingForWatchDisconnect", tableName: filename, bundle: .main,
        value: "Returning from Watch; awaiting confirmed Watch disconnect",
        comment: "Direct Libre experiment")

    static let watchUnreachable = NSLocalizedString(
        "watchUnreachable", tableName: filename, bundle: .main,
        value: "Watch unreachable. Phone Bluetooth stays disabled; keep both apps open and retry.",
        comment: "Direct Libre experiment")

    static let handoffRejected = NSLocalizedString(
        "handoffRejected", tableName: filename, bundle: .main, value: "Handoff rejected",
        comment: "Direct Libre experiment")

    static let returnRetryInstructions = NSLocalizedString(
        "returnRetryInstructions", tableName: filename, bundle: .main,
        value: "Returning — keep both apps open; acknowledgement will retry automatically",
        comment: "Direct Libre experiment")

    static let ownershipUnresolved = NSLocalizedString(
        "ownershipUnresolved", tableName: filename, bundle: .main,
        value: "Failed: ownership unresolved; phone must remain disabled",
        comment: "Direct Libre experiment")

    static let noSavedSession = NSLocalizedString(
        "noSavedSession", tableName: filename, bundle: .main, value: "Failed: no saved session",
        comment: "Direct Libre experiment")

    static let phoneUnreachable = NSLocalizedString(
        "phoneUnreachable", tableName: filename, bundle: .main,
        value: "Returning: iPhone unreachable. Keep both apps open and retry.",
        comment: "Direct Libre experiment")

    static let returnRejected = NSLocalizedString(
        "returnRejected", tableName: filename, bundle: .main, value: "return rejected",
        comment: "Direct Libre experiment")

    // MARK: - Bluetooth collection

    static let bluetoothUnavailable = NSLocalizedString(
        "bluetoothUnavailable", tableName: filename, bundle: .main,
        value: "Failed: Bluetooth unavailable",
        comment: "Direct Libre experiment")

    static let enableBluetoothToReturn = NSLocalizedString(
        "enableBluetoothToReturn", tableName: filename, bundle: .main,
        value: "Returning: enable Bluetooth to confirm disconnect",
        comment: "Direct Libre experiment")

    static let connectionTimedOut = NSLocalizedString(
        "connectionTimedOut", tableName: filename, bundle: .main,
        value: "Failed: Libre connection timed out",
        comment: "Direct Libre experiment")

    static let invalidReading = NSLocalizedString(
        "invalidReading", tableName: filename, bundle: .main, value: "Failed: invalid Libre reading",
        comment: "Direct Libre experiment")

    static let sensorWarmingUp = NSLocalizedString(
        "sensorWarmingUp", tableName: filename, bundle: .main, value: "Failed: sensor warming up",
        comment: "Direct Libre experiment")

    static let noFreshReading = NSLocalizedString(
        "noFreshReading", tableName: filename, bundle: .main, value: "Failed: no fresh Libre reading",
        comment: "Direct Libre experiment")

    static let frameAuthenticationFailed = NSLocalizedString(
        "frameAuthenticationFailed", tableName: filename, bundle: .main,
        value: "Failed: Libre frame authentication",
        comment: "Direct Libre experiment")

    static let identityPersistenceFailed = NSLocalizedString(
        "identityPersistenceFailed", tableName: filename, bundle: .main,
        value: "Failed: could not persist Libre identity",
        comment: "Direct Libre experiment")

    static let connectionFailed = NSLocalizedString(
        "connectionFailed", tableName: filename, bundle: .main,
        value: "Failed: Libre connection failed", comment: "Direct Libre experiment"
    )

    static let disconnected = NSLocalizedString(
        "disconnected", tableName: filename, bundle: .main, value: "Connecting: Libre disconnected",
        comment: "Direct Libre experiment")

    static let serviceMissing = NSLocalizedString(
        "serviceMissing", tableName: filename, bundle: .main, value: "Failed: Libre service missing",
        comment: "Direct Libre experiment")

    static let characteristicDiscoveryFailed = NSLocalizedString(
        "characteristicDiscoveryFailed", tableName: filename, bundle: .main,
        value: "Failed: characteristic discovery",
        comment: "Direct Libre experiment")

    static let characteristicsMissing = NSLocalizedString(
        "characteristicsMissing", tableName: filename, bundle: .main,
        value: "Failed: Libre characteristics missing",
        comment: "Direct Libre experiment")

    static let subscriptionFailed = NSLocalizedString(
        "subscriptionFailed", tableName: filename, bundle: .main, value: "Failed: Libre subscription",
        comment: "Direct Libre experiment")

    static let unlockWriteFailed = NSLocalizedString(
        "unlockWriteFailed", tableName: filename, bundle: .main,
        value: "Failed: Libre unlock write. Counter retained.",
        comment: "Direct Libre experiment")

    // MARK: - Formatted status messages

    static func failed(_ reason: String) -> String {
        let format = NSLocalizedString(
            "failedFormat", tableName: filename, bundle: .main, value: "Failed: %@",
            comment: "Direct Libre error with reason")
        return String(format: format, reason)
    }

    static func handoffFailed(_ reason: String) -> String {
        let format = NSLocalizedString(
            "handoffFailedFormat", tableName: filename, bundle: .main,
            value: "Handoff failed: %@. Retry with both apps open.",
            comment: "Forward handoff error with reason")
        return String(format: format, reason)
    }

    static func returnFailed(_ reason: String) -> String {
        let format = NSLocalizedString(
            "returnFailedFormat", tableName: filename, bundle: .main,
            value: "Returning: %@. Retry Return to iPhone.",
            comment: "Return handoff error with reason")
        return String(format: format, reason)
    }

    static let experimentTitle = NSLocalizedString(
        "experimentTitle", tableName: filename, bundle: .main, value: "Direct Libre (Experimental)",
        comment: "Direct Libre experiment")

    static let checklistTitle = NSLocalizedString(
        "checklistTitle", tableName: filename, bundle: .main, value: "Connection checklist",
        comment: "Direct Libre experiment")

    static let watchReachable = NSLocalizedString(
        "watchReachable", tableName: filename, bundle: .main, value: "Watch app reachable",
        comment: "Direct Libre experiment")

    static let reachabilityHelp = NSLocalizedString(
        "reachabilityHelp", tableName: filename, bundle: .main,
        value:
            "For handoff or return, keep both xDrip apps open and nearby. Direct Watch collection can continue while the iPhone is unreachable.",
        comment: "Direct Libre experiment")

    static let watchInstalledHelp = NSLocalizedString(
        "watchInstalledHelp", tableName: filename, bundle: .main,
        value: "Install this build of xDrip on your paired Watch.",
        comment: "Direct Libre experiment")

    static let masterMode = NSLocalizedString(
        "masterMode", tableName: filename, bundle: .main, value: "Master mode enabled",
        comment: "Direct Libre experiment")

    static let masterHelp = NSLocalizedString(
        "masterHelp", tableName: filename, bundle: .main,
        value: "The iPhone must collect from the Libre sensor directly.",
        comment: "Direct Libre experiment")

    static let nativeAlgorithm = NSLocalizedString(
        "nativeAlgorithm", tableName: filename, bundle: .main, value: "Libre Native Algorithm enabled",
        comment: "Direct Libre experiment")

    static let nativeHelp = NSLocalizedString(
        "nativeHelp", tableName: filename, bundle: .main,
        value: "Select Native Algorithm for the connected Libre 2 sensor.",
        comment: "Direct Libre experiment")

    static let unlockEnabled = NSLocalizedString(
        "unlockEnabled", tableName: filename, bundle: .main, value: "Unlock payload enabled",
        comment: "Direct Libre experiment")

    static let unlockHelp = NSLocalizedString(
        "unlockHelp", tableName: filename, bundle: .main,
        value: "Turn off Suppress Unlock Payload, then wait for a new Libre reading.",
        comment: "Direct Libre experiment")

    static let freshReading = NSLocalizedString(
        "freshReading", tableName: filename, bundle: .main, value: "Recent Libre reading",
        comment: "Direct Libre experiment")

    static let phoneConnected = NSLocalizedString(
        "phoneConnected", tableName: filename, bundle: .main, value: "iPhone connected to Libre",
        comment: "Direct Libre experiment")

    static let phoneConnectedHelp = NSLocalizedString(
        "phoneConnectedHelp", tableName: filename, bundle: .main,
        value: "Start with a working Libre BLE connection on the iPhone.",
        comment: "Direct Libre experiment")

    static let connectToWatch = NSLocalizedString(
        "connectToWatch", tableName: filename, bundle: .main, value: "Switch to Watch",
        comment: "Direct Libre experiment")

    static let cancelReturn = NSLocalizedString(
        "cancelReturn", tableName: filename, bundle: .main, value: "Switch to iPhone",
        comment: "Direct Libre experiment")

    static let returnRequested = NSLocalizedString(
        "returnRequested", tableName: filename, bundle: .main,
        value: "Return requested; waiting for Watch",
        comment: "Direct Libre experiment")

    static let activityLog = NSLocalizedString(
        "activityLog", tableName: filename, bundle: .main, value: "Recent activity",
        comment: "Direct Libre experiment")

    static let emptyLog = NSLocalizedString(
        "emptyLog", tableName: filename, bundle: .main, value: "No activity yet.",
        comment: "Direct Libre experiment")

    static let requestSent = NSLocalizedString(
        "requestSent", tableName: filename, bundle: .main, value: "Asked Watch to return ownership",
        comment: "Direct Libre experiment")

    static let prepareSent = NSLocalizedString(
        "prepareSent", tableName: filename, bundle: .main, value: "Sending sensor handoff to Watch",
        comment: "Direct Libre experiment")

    static let activateSent = NSLocalizedString(
        "activateSent", tableName: filename, bundle: .main,
        value: "iPhone disconnected; activating Watch",
        comment: "Direct Libre experiment")

    static let returnPrepareSent = NSLocalizedString(
        "returnPrepareSent", tableName: filename, bundle: .main,
        value: "Sending final sensor state to iPhone",
        comment: "Direct Libre experiment")

    static let returnCommitSent = NSLocalizedString(
        "returnCommitSent", tableName: filename, bundle: .main,
        value: "Watch disconnected; completing return",
        comment: "Direct Libre experiment")

    static let watchReachableLog = NSLocalizedString(
        "watchReachableLog", tableName: filename, bundle: .main, value: "Watch became reachable",
        comment: "Direct Libre experiment")

    static let watchUnreachableLog = NSLocalizedString(
        "watchUnreachableLog", tableName: filename, bundle: .main, value: "Watch is not reachable",
        comment: "Direct Libre experiment")

    static let phoneReachableLog = NSLocalizedString(
        "phoneReachableLog", tableName: filename, bundle: .main, value: "iPhone became reachable",
        comment: "Direct Libre experiment")

    static let phoneUnreachableLog = NSLocalizedString(
        "phoneUnreachableLog", tableName: filename, bundle: .main, value: "iPhone is not reachable",
        comment: "Direct Libre experiment")

    static let checkPassed = NSLocalizedString(
        "checkPassed", tableName: filename, bundle: .main, value: "Ready",
        comment: "Direct Libre experiment")

    static let checkMissing = NSLocalizedString(
        "checkMissing", tableName: filename, bundle: .main, value: "Needs attention",
        comment: "Direct Libre experiment")

    static let directWaiting = NSLocalizedString(
        "directWaiting", tableName: filename, bundle: .main, value: "Direct Libre · waiting / stale",
        comment: "Phone-controlled Libre proof of concept")

    static let phoneLoginVerified = NSLocalizedString(
        "phoneLoginVerified", tableName: filename, bundle: .main,
        value: "Phone login and reading verified", comment: "Direct Libre checklist")
    static let phoneLoginHelp = NSLocalizedString(
        "phoneLoginHelp", tableName: filename, bundle: .main,
        value:
            "Requires a successful xDrip unlock write and a native BLE reading after sensor warm-up. An already-streaming connection may need Verify phone connection.",
        comment: "Direct Libre checklist")
    static let noPhoneBLEReading = NSLocalizedString(
        "noPhoneBLEReading", tableName: filename, bundle: .main,
        value:
            "No Libre BLE reading observed on this connection yet. Waiting for the next sensor update; stored, NFC and relayed readings do not count.",
        comment: "Direct Libre checklist")
    static func lastPhoneBLEReading(_ date: Date) -> String {
        let format = NSLocalizedString(
            "lastPhoneBLEReading", tableName: filename, bundle: .main,
            value: "Last Libre BLE reading: %@. Must be less than 3 minutes old.",
            comment: "Direct Libre checklist; time of last actual BLE reading")
        return String(format: format, date.formatted(date: .omitted, time: .standard))
    }
    static let verifyPhoneConnection = NSLocalizedString(
        "verifyPhoneConnection", tableName: filename, bundle: .main,
        value: "Verify phone connection", comment: "Direct Libre checklist")
    static let verifyPhoneConnectionHelp = NSLocalizedString(
        "verifyPhoneConnectionHelp", tableName: filename, bundle: .main,
        value:
            "Reconnects xDrip over Bluetooth using the existing sensor credentials. Keep Bluetooth on and wait for fresh glucose. No NFC scan is performed.",
        comment: "Direct Libre checklist")
    static let verifyingPhoneConnection = NSLocalizedString(
        "verifyingPhoneConnection", tableName: filename, bundle: .main,
        value: "Verifying phone connection: reconnecting over BLE. Keep Bluetooth on and wait for the next sensor reading.",
        comment: "Direct Libre checklist")
    static let phoneBLEReadingReceived = NSLocalizedString(
        "phoneBLEReadingReceived", tableName: filename, bundle: .main,
        value: "Fresh Libre BLE reading received on iPhone", comment: "Direct Libre diagnostic log")
    static let phoneLoginWritten = NSLocalizedString(
        "phoneLoginWritten", tableName: filename, bundle: .main,
        value: "Phone unlock write acknowledged; waiting for a fresh reading", comment: "Direct Libre diagnostic log")
    static let phoneLoginWriteFailed = NSLocalizedString(
        "phoneLoginWriteFailed", tableName: filename, bundle: .main,
        value: "Phone unlock write failed; receiving glucose alone does not verify the phone login", comment: "Direct Libre diagnostic log")

    // MARK: - Compact phone control page

    static let watchAppSection = NSLocalizedString(
        "watchAppSection", tableName: filename, bundle: .main,
        value: "Watch app", comment: "Direct Libre checklist group")
    static let sensorSection = NSLocalizedString(
        "sensorSection", tableName: filename, bundle: .main,
        value: "Sensor settings", comment: "Direct Libre checklist group")
    static let phoneConnectionSection = NSLocalizedString(
        "phoneConnectionSection", tableName: filename, bundle: .main,
        value: "iPhone connection", comment: "Direct Libre checklist group")
    static let watchAppReady = NSLocalizedString(
        "watchAppReady", tableName: filename, bundle: .main,
        value: "Companion app installed and ready", comment: "Direct Libre checklist")
    static let phoneConnectionPaused = NSLocalizedString(
        "phoneConnectionPaused", tableName: filename, bundle: .main,
        value:
            "The iPhone connection is paused while Watch is selected or a switch is unresolved. These checks resume when the phone reconnects.",
        comment: "Direct Libre checklist")
    static let retryReturnToPhone = NSLocalizedString(
        "retryReturnToPhone", tableName: filename, bundle: .main,
        value: "Retry return to iPhone", comment: "Direct Libre switch button")
    static let ordinaryScanRecovery = NSLocalizedString(
        "ordinaryScanRecovery", tableName: filename, bundle: .main,
        value: "If return cannot finish, use the ordinary Libre Add/Connect NFC scan to reset Direct Libre and connect the sensor on iPhone. The Watch does not need to be reachable.",
        comment: "Direct Libre recovery through the original sensor screen")
    static let showMoreActivity = NSLocalizedString(
        "showMoreActivity", tableName: filename, bundle: .main,
        value: "Show more", comment: "Show five more Direct Libre activity entries")
    static let showLessActivity = NSLocalizedString(
        "showLessActivity", tableName: filename, bundle: .main,
        value: "Show less", comment: "Collapse Direct Libre activity to five entries")

}

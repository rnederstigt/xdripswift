import Foundation
import WatchConnectivity

/// Presentation for Advanced Settings; connection transitions stay in Libre2PhoneHandoff.
extension Libre2PhoneHandoff {
    var checklistGroups: [Libre2ChecklistGroup] {
        let session = WCSession.default
        let activated = session.activationState == .activated
        return [
            Libre2ChecklistGroup(
                id: .watch, title: Texts_DirectLibre.watchAppSection,
                items: [
                    Libre2ChecklistItem(
                        id: "installed", title: Texts_DirectLibre.watchAppReady, detail: Texts_DirectLibre.watchInstalledHelp,
                        isSatisfied: activated && session.isPaired && session.isWatchAppInstalled),
                    Libre2ChecklistItem(
                        id: "reachable", title: Texts_DirectLibre.watchReachable, detail: Texts_DirectLibre.reachabilityHelp,
                        isSatisfied: reachable),
                ]),
            Libre2ChecklistGroup(
                id: .sensor, title: Texts_DirectLibre.sensorSection,
                items: [
                    Libre2ChecklistItem(
                        id: "master", title: Texts_DirectLibre.masterMode, detail: Texts_DirectLibre.masterHelp,
                        isSatisfied: UserDefaults.standard.isMaster),
                    Libre2ChecklistItem(
                        id: "native", title: Texts_DirectLibre.nativeAlgorithm, detail: Texts_DirectLibre.nativeHelp,
                        isSatisfied: sensor?.usesNativeAlgorithm == true),
                    Libre2ChecklistItem(
                        id: "unlock", title: Texts_DirectLibre.unlockEnabled, detail: Texts_DirectLibre.unlockHelp,
                        isSatisfied: !UserDefaults.standard.suppressUnLockPayLoad),
                ]),
            Libre2ChecklistGroup(
                id: .phone, title: Texts_DirectLibre.phoneConnectionSection,
                items: [
                    Libre2ChecklistItem(
                        id: "connected", title: Texts_DirectLibre.phoneConnected, detail: Texts_DirectLibre.phoneConnectedHelp,
                        isSatisfied: sensor?.isConnected == true),
                    Libre2ChecklistItem(
                        id: "reading", title: Texts_DirectLibre.freshReading, detail: readingDetail,
                        showsDetailWhenSatisfied: true, isSatisfied: readingStatus.hasRecentReading()),
                    Libre2ChecklistItem(
                        id: "phoneLogin", title: Texts_DirectLibre.phoneLoginVerified, detail: Texts_DirectLibre.phoneLoginHelp,
                        isSatisfied: readingStatus.hasRecentVerifiedReading()
                            && readingStatus.verifiedUnlockCode == UserDefaults.standard.libreActiveSensorUnlockCode),
                ], note: owner.allowsPhoneConnection ? nil : Texts_DirectLibre.phoneConnectionPaused),
        ]
    }

    var switchButtonTitle: String {
        switch Libre2SessionStore.shared.snapshot.phoneSwitchAction {
        case .switchToWatch: return Texts_DirectLibre.connectToWatch
        case .returnToPhone:
            return [.returnRequested, .returningToPhone].contains(owner)
                ? Texts_DirectLibre.retryReturnToPhone : Texts_DirectLibre.cancelReturn
        case .unavailable: return Texts_DirectLibre.cancelReturn
        }
    }

    var switchButtonSymbol: String {
        Libre2SessionStore.shared.snapshot.phoneSwitchAction == .switchToWatch ? "applewatch" : "iphone"
    }

    var canSwitchDevice: Bool {
        guard !isStarting, !isVerifyingPhoneConnection, !Libre2SessionStore.shared.phoneNFCIsActive else { return false }
        switch Libre2SessionStore.shared.snapshot.phoneSwitchAction {
        case .switchToWatch: return canStart
        case .returnToPhone: return canCancel
        case .unavailable: return false
        }
    }

    /// Cancellation and retry reuse the existing protocol; this never changes ownership directly.
    func switchDevice() {
        guard canSwitchDevice else { return }
        switch Libre2SessionStore.shared.snapshot.phoneSwitchAction {
        case .switchToWatch: start()
        case .returnToPhone: cancelAndReturn()
        case .unavailable: break
        }
    }

    private var readingDetail: String {
        guard let date = readingStatus.lastReadingAt else { return Texts_DirectLibre.noPhoneBLEReading }
        return Texts_DirectLibre.lastPhoneBLEReading(date)
    }

}

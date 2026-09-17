"""Latest/history delivery and downstream phone routing checks."""
import subprocess

from test_support import ADDON as addon, REPO as repo, block, fixture, run_swift, test_directory


def history_delivery():
    with test_directory("direct-libre-history-") as work:
        source = work / "Libre2WatchHistorySync.swift"
        source.write_text((addon / "Watch/Managers/Libre2WatchHistorySync.swift").read_text()
                          .replace("import WatchConnectivity\n", "").replace("import WatchKit\n", ""))
        executable = work / "history-tests"
        run_swift(executable, [
            *[str(addon / path) for path in [
                "Shared/Constants/ConstantsLibre2.swift", "Shared/Protocol/Libre2BLEData.swift",
                "Shared/Protocol/Libre2Calibration.swift", "Shared/DataModels/Libre2WatchSession.swift",
                "Shared/Managers/Libre2JournalFile.swift", "Shared/DataModels/Libre2History.swift", "Shared/Managers/Libre2HistoryQueue.swift",
                "Tests/Libre2WatchHistoryDeliveryTests.swift"]],
            source,
        ], flags=["-swift-version", "5", "-D", "LIBRE2_HISTORY_TESTS"])

        # Run the phone's unchanged receive/import scheduling and response methods with a
        # storage spy. Real Core Data behaviour is covered by the hosted iPhone tests.
        phone = (addon / "iPhone/Managers/Libre2PhoneHistorySync.swift").read_text()
        phone = phone[:phone.index("    @MainActor\n    private func register(")]
        phone = phone.replace("import CoreData\n", "").replace("import WatchConnectivity\n", "")
        phone += fixture("PhoneHistoryStorage")
        # Exercise the actual host delegate hook, including its main-queue dispatch.
        host = (addon.parent / "xDrip/Managers/Watch/WatchManager.swift").read_text()
        hook = host[host.index("    func session(_: WCSession, didReceiveApplicationContext"):
                    host.index("    func session(_: WCSession, didReceiveMessageData")]
        phone += "\nextension WatchManager {\n" + hook + "}\n"
        source = work / "Libre2PhoneHistorySync.swift"
        source.write_text(phone)
        run_swift(executable, [
            *[str(addon / path) for path in [
                "Shared/Constants/ConstantsLibre2.swift", "Shared/Protocol/Libre2BLEData.swift",
                "Shared/Protocol/Libre2Calibration.swift", "Shared/DataModels/Libre2WatchSession.swift",
                "Shared/Managers/Libre2JournalFile.swift", "Shared/DataModels/Libre2History.swift", "Shared/DataModels/Libre2PhoneHistoryUpdate.swift",
                "Tests/Libre2PhoneHistoryDeliveryTests.swift"]],
            source,
        ], flags=["-swift-version", "5", "-D", "LIBRE2_PHONE_HISTORY_TESTS"])


def phone_import_routing():
    path = 'xDrip/Managers/Application/RootApplicationCoordinator.swift'
    source = (repo / path).read_text()
    baseline = subprocess.check_output(['git', 'show', '87a0e0c6528be6ec3b3cc9d332e7b8ddc457a6c0:' + path], cwd=repo, text=True)

    old = block(baseline, 'if newReadingCreated {')
    shared_start = source.index('    private func processStoredGlucoseData(')
    shared_body = block(source[shared_start:], '    ) {')
    shared = source[shared_start:source.index('    ) {', shared_start) + len('    ) {')] + shared_body + '}'
    handler_body = block(source, '    @objc private func handleDirectLibreHistoryDidImport(_ notification: Notification) {')
    phone = block(source, 'if newReadingCreated {')
    harness = fixture('PhoneImportRouting',
        old=old,
        phone=phone,
        shared=shared,
        handler_body=handler_body)
    with test_directory('direct-libre-import-') as work:
        main = work / 'ImportRouting.swift'
        main.write_text(harness)
        executable = work / 'import-tests'
        run_swift(executable, [
            addon / 'Shared/DataModels/Libre2PhoneHistoryUpdate.swift',
            main,
        ], flags=['-swift-version', '5'])

    # Execute the actual delayed-buffer adapter with database/settings doubles. This
    # checks the values passed to the existing sharing manager, not an app-group write.
    processing = (addon / 'iPhone/Managers/Libre2PhoneReadingProcessing.swift').read_text()
    prepare = block(processing, 'static func prepareDelayedSharing(coreDataManager: CoreDataManager?, loopManager: LoopManager?, now: Date = Date()) {')
    sharing = fixture('PhoneSharing',
        prepare=prepare)
    with test_directory('direct-libre-sharing-') as work:
        main = work / 'Sharing.swift'
        main.write_text(sharing)
        executable = work / 'sharing-tests'
        run_swift(executable, [
            repo / 'xDrip/BluetoothTransmitter/CGM/Generic/GlucoseData.swift',
            repo / 'xDrip/Managers/Loop/BgReading+LoopShare.swift',
            repo / 'xDrip/Constants/ConstantsShareWithLoop.swift',
            main,
        ], flags=['-swift-version', '5'])

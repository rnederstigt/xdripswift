"""Preferences, background task lifecycle, location and notification checks."""
import re
import subprocess

from test_support import ADDON as addon, REPO as repo, fixture, run_swift, test_directory


def watch_preferences():
    host_path = 'xDrip Watch App/DataModels/WatchStateModel.swift'
    host = (repo / host_path).read_text()
    # This reviewed host baseline includes the delivery/lifecycle hooks added after the
    # original preference work. Compare the whole file; no adapter-only change needs a host edit.
    expected = subprocess.check_output(['git', 'show', '047151ce40d054e504daaf1e636201a926b333f1:' + host_path], cwd=repo, text=True)
    # Remove exactly the retired investigation hooks from the reviewed baseline.
    expected = re.sub(r'^ *Libre2LifecycleDiagnostics\.recordSession\([^\n]*\n(?: *details:[^\n]*\n)?', '', expected, flags=re.M)
    expected = re.sub(r'^ *recordLibreComplicationCache\([^\n]*\n', '', expected, flags=re.M)
    expected = expected.replace('    func session(_: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {\n        directLibre.historyTransferFinished(userInfoTransfer.userInfo, error: error)\n    }\n', '')
    expected = expected.replace('if userInfo[Libre2HandoffMessage.retiredIDsKey] != nil\n                || (try? Libre2HandoffMessage.decode(userInfo).kind) == .revoke {', 'if userInfo[Libre2HandoffMessage.retiredIDsKey] != nil {')
    assert host == expected, 'Host changes exceed the reviewed functional hooks and diagnostic removals'
    assert host.index('restoreDirectLibrePreferences()') < host.index('directLibre.restore()')
    assert 'processedUpdate = processStatusFromDictionary(dictionary: statusDictionary)' in host

    adapter = (addon / 'Watch/DataModels/WatchStateModel+DirectLibre.swift').read_text().replace(
        'Libre2WatchPreferences()', 'Libre2WatchPreferences(defaults: testDefaults)')
    code = fixture('WatchPreferences',
        adapter=adapter)
    with test_directory('direct-libre-preferences-') as work:
        main = work / 'PreferencesProbe.swift'
        main.write_text(code)
        binary = work / 'preferences-tests'
        sources = [addon / 'Shared/Managers/Libre2WatchPreferences.swift',
                   addon / 'Shared/DataModels/Libre2LocationRequest.swift',
                   addon / 'Shared/Constants/ConstantsLibre2.swift',
                   addon / 'Shared/Managers/Libre2ReadingPipeline.swift',
                   repo / 'xDrip Watch Complication/DataModels/ComplicationSharedUserDefaultsModel.swift']
        run_swift(binary, [
            *map(str, sources),
            main,
        ], flags=['-swift-version', '5'])


def watch_background_tasks():
    with test_directory("libre-background-tasks-") as work:
        source = work / "Libre2WatchConnectivityTasks.swift"
        source.write_text((addon / "Watch/Managers/Libre2WatchConnectivityTasks.swift").read_text()
                          .replace("import WatchConnectivity\n", ""))
        executable = work / "tests"
        run_swift(executable, [
            source,
            addon / "Tests/Libre2WatchConnectivityTaskTests.swift",
        ], flags=["-swift-version", "5", "-D", "LIBRE2_BACKGROUND_TASK_TESTS"], timeout=30)


def watch_location():
    with test_directory("direct-libre-location-") as work:
        helper = work / "Libre2WatchLocationSession.swift"
        helper.write_text((addon / "Watch/Managers/Libre2WatchLocationSession.swift").read_text()
                          .replace("import CoreLocation", "import Foundation").replace("import WatchKit", ""))
        owner = work / "Libre2Owner.swift"
        owner.write_text((addon / "Shared/DataModels/Libre2Ownership.swift").read_text()
                         .split("struct Libre2OwnershipRecord:")[0])
        executable = work / "location-tests"
        run_swift(executable, [
            helper,
            owner,
            addon / "Shared/Managers/Libre2WatchPreferences.swift",
            addon / "Shared/DataModels/Libre2LocationRequest.swift",
            addon / "Shared/Texts/Texts_DirectLibre.swift",
            addon / "Tests/Libre2WatchLocationTests.swift",
        ], flags=["-swift-version", "5", "-D", "LIBRE2_LOCATION_TESTS"])


def watch_notification():
    with test_directory("direct-libre-notification-") as work:
        helper = work / "Libre2WatchNotificationTest.swift"
        helper.write_text((addon / "Watch/Managers/Libre2WatchNotificationTest.swift").read_text()
                          .replace("import UserNotifications", "").replace("import WatchKit", ""))
        executable = work / "notification-tests"
        run_swift(executable, [
            helper,
            addon / "Shared/DataModels/Libre2NotificationTest.swift",
            addon / "Shared/DataModels/Libre2LocationRequest.swift",
            addon / "Shared/Texts/Texts_DirectLibre.swift",
            addon / "Tests/Libre2WatchNotificationTests.swift",
        ], flags=["-swift-version", "5", "-D", "LIBRE2_NOTIFICATION_TESTS"])

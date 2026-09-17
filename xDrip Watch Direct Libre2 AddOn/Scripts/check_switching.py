"""Switching, NFC retirement delivery and collector reconnection checks."""

from test_support import ADDON as addon, declaration, fixture, run_swift, test_directory


def phone_handoff():
    source = (addon / 'iPhone/Managers/Libre2PhoneHandoff.swift').read_text()

    code = fixture('PhoneHandoff',
        phone_methods='\n'.join(declaration(source, '    ' + name) for name in [
        'var reachable:', 'private struct WatchAvailability:', 'func recordReachability()',
        'private var retiredSessionsDictionary:', 'func notifyWatchOfNFCReset()',
        'private func syncRetiredSessions()']))
    with test_directory('direct-libre-phone-handoff-') as work:
        main = work / 'main.swift'
        main.write_text(code)
        run_swift(work / 'phone-handoff-tests', [main], flags=['-swift-version', '5'])


def watch_handoff():
    with test_directory("libre-handoff-") as work:
        source = work / "Libre2WatchHandoff.swift"
        source.write_text((addon / "Watch/Managers/Libre2WatchHandoff.swift").read_text()
                          .replace("import WatchConnectivity\n", ""))
        # Compile the collector's real progress model alongside the transport double.
        collector = (addon / "Watch/BluetoothTransmitter/Libre2WatchCollector.swift").read_text()
        start = collector.index("    enum ConnectionState {")
        end = collector.index("    // MARK: - Properties", start)
        state = work / "ConnectionState.swift"
        state.write_text("extension Libre2WatchCollector {\n" + collector[start:end] + "}\n")
        # Compile the actual host user-info route too, so removed wire cases cannot linger there.
        host = (addon.parent / "xDrip Watch App/DataModels/WatchStateModel.swift").read_text()
        hook = declaration(host, "    func session(_: WCSession, didReceiveUserInfo")
        routing = work / "WatchStateModel.swift"
        routing.write_text("extension WatchStateModel {\n" + hook + "\n}")
        executable = work / "tests"
        run_swift(executable, [
            *map(str, sorted((addon / "Shared").rglob("*.swift"))),
            source,
            state,
            routing,
            addon / "Tests/Libre2WatchHandoffTests.swift",
        ], flags=["-swift-version", "5", "-D", "LIBRE2_HANDOFF_TESTS"], timeout=30)


def watch_reconnect():
    collector = addon / "Watch/BluetoothTransmitter/Libre2WatchCollector.swift"

    # Execute the actual gesture routing without pulling the whole SwiftUI model into host tests.
    extension = (addon / "Watch/DataModels/WatchStateModel+DirectLibre.swift").read_text()
    gesture = fixture('GestureRouting',
        double_tap=declaration(extension, "    func refreshAfterDoubleTap"))

    with test_directory("direct-libre-reconnect-") as work:
        source = work / collector.name
        source.write_text(collector.read_text().replace("import CoreBluetooth\n", "", 1))
        routing = work / "GestureRouting.swift"
        routing.write_text(gesture)
        executable = work / "reconnect-tests"
        run_swift(executable, [
            *map(str, sorted((addon / "Shared").rglob("*.swift"))),
            source,
            routing,
            addon / "Tests/Libre2WatchReconnectTests.swift",
        ], flags=["-swift-version", "5", "-D", "LIBRE2_RECONNECT_TESTS"])

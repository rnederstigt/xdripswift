#!/usr/bin/env python3
"""Exercise the real Watch collector with deterministic Bluetooth and timer doubles.

Only the CoreBluetooth import is removed from a temporary copy. Shared persistence,
counter reservation, crypto and parsing execute unchanged. This checks app policy,
not watchOS radio behaviour; also build with the real Watch SDK and test on device.
All compiler products live in an automatically removed temporary directory.
"""
from pathlib import Path
from swift_test_runner import run_swift, test_directory

addon = Path(__file__).resolve().parents[1]
collector = addon / "Watch/BluetoothTransmitter/Libre2WatchCollector.swift"


def method(source, name):
    start = source.index("    func " + name)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


# Execute the actual gesture routing without pulling the whole SwiftUI model into host tests.
extension = (addon / "Watch/DataModels/WatchStateModel+DirectLibre.swift").read_text()
gesture = """
final class DirectMode {
    var isDirect = false
    var retries = 0
    func restartConnection() { retries += 1 }
}
final class WatchStateModel {
    let directLibre = DirectMode()
    var phoneRequests = 0
    func requestWatchStateUpdate() { phoneRequests += 1 }
""" + method(extension, "refreshAfterDoubleTap") + "\n}\n"

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

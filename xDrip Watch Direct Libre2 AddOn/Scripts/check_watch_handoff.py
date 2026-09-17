#!/usr/bin/env python3
"""Run the Watch handoff coordinator with explicit transport/disconnect callbacks."""
from pathlib import Path
from swift_test_runner import run_swift, test_directory

addon = Path(__file__).resolve().parents[1]
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
    start = host.index("    func session(_: WCSession, didReceiveUserInfo")
    brace = host.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (host[end] == "{") - (host[end] == "}")
        end += 1
    routing = work / "WatchStateModel.swift"
    routing.write_text("extension WatchStateModel {\n" + host[start:end] + "\n}")
    executable = work / "tests"
    run_swift(executable, [
        *map(str, sorted((addon / "Shared").rglob("*.swift"))),
        source,
        state,
        routing,
        addon / "Tests/Libre2WatchHandoffTests.swift",
    ], flags=["-swift-version", "5", "-D", "LIBRE2_HANDOFF_TESTS"], timeout=30)

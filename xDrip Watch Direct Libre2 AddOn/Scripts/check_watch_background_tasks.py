#!/usr/bin/env python3
"""Exercise production background-task handling with an observable WCSession double."""
from pathlib import Path
from swift_test_runner import run_swift, test_directory

addon = Path(__file__).resolve().parents[1]
with test_directory("libre-background-tasks-") as work:
    source = work / "Libre2WatchConnectivityTasks.swift"
    source.write_text((addon / "Watch/Managers/Libre2WatchConnectivityTasks.swift").read_text()
                      .replace("import WatchConnectivity\n", ""))
    executable = work / "tests"
    run_swift(executable, [
        source,
        addon / "Tests/Libre2WatchConnectivityTaskTests.swift",
    ], flags=["-swift-version", "5", "-D", "LIBRE2_BACKGROUND_TASK_TESTS"], timeout=30)

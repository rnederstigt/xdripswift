#!/usr/bin/env python3
"""Exercise production background-task handling with an observable WCSession double."""
from pathlib import Path
import subprocess
import tempfile

addon = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="libre-background-tasks-") as directory:
    work = Path(directory)
    source = work / "Libre2WatchConnectivityTasks.swift"
    source.write_text((addon / "Watch/Managers/Libre2WatchConnectivityTasks.swift").read_text()
                      .replace("import WatchConnectivity\n", ""))
    executable = work / "tests"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-D", "LIBRE2_BACKGROUND_TASK_TESTS",
                    "-module-cache-path", str(work / "modules"), str(source),
                    str(addon / "Tests/Libre2WatchConnectivityTaskTests.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)

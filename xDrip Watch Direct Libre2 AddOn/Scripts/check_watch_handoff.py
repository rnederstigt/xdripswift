#!/usr/bin/env python3
"""Run the Watch handoff coordinator with explicit transport/disconnect callbacks."""
from pathlib import Path
import subprocess
import tempfile

addon = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="libre-handoff-") as directory:
    work = Path(directory)
    source = work / "Libre2WatchHandoff.swift"
    source.write_text((addon / "Watch/Managers/Libre2WatchHandoff.swift").read_text()
                      .replace("import WatchConnectivity\n", ""))
    executable = work / "tests"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-D", "LIBRE2_HANDOFF_TESTS",
                    "-module-cache-path", str(work / "modules"),
                    *map(str, sorted((addon / "Shared").rglob("*.swift"))), str(source),
                    str(addon / "Tests/Libre2WatchHandoffTests.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)

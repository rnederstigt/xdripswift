#!/usr/bin/env python3
"""Run the production Watch history coordinator with explicit WatchConnectivity events.

Only platform imports are removed. The real journal/response models are used with
an injected in-memory writer; no application data or repository files are changed.
"""
from pathlib import Path
import subprocess
import tempfile

addon = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="direct-libre-history-") as directory:
    work = Path(directory)
    source = work / "Libre2WatchHistorySync.swift"
    source.write_text((addon / "Watch/Managers/Libre2WatchHistorySync.swift").read_text()
                      .replace("import WatchConnectivity\n", "").replace("import WatchKit\n", ""))
    executable = work / "history-tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-D", "LIBRE2_HISTORY_TESTS",
        "-module-cache-path", str(work / "module-cache"),
        *[str(addon / path) for path in [
            "Shared/Constants/ConstantsLibre2.swift", "Shared/Protocol/Libre2BLEData.swift",
            "Shared/Protocol/Libre2Calibration.swift", "Shared/DataModels/Libre2WatchSession.swift",
            "Shared/DataModels/Libre2History.swift", "Shared/Managers/Libre2HistoryQueue.swift",
            "Tests/Libre2WatchHistoryDeliveryTests.swift"]], str(source), "-o", str(executable)
    ], check=True)
    subprocess.run([str(executable)], check=True)

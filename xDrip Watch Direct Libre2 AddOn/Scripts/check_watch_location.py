#!/usr/bin/env python3
"""Execute the production location helper with location/lifecycle doubles, not GPS.

Only framework imports are replaced. No app preferences or sensor journal is used.
Compile against the Watch SDK as well; these checks cannot prove background runtime.
"""
from pathlib import Path
import subprocess
import tempfile

addon = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="direct-libre-location-") as directory:
    work = Path(directory)
    helper = work / "Libre2WatchLocationSession.swift"
    helper.write_text((addon / "Watch/Managers/Libre2WatchLocationSession.swift").read_text()
                      .replace("import CoreLocation", "import Foundation").replace("import WatchKit", ""))
    owner = work / "Libre2Owner.swift"
    owner.write_text((addon / "Shared/DataModels/Libre2Ownership.swift").read_text()
                     .split("struct Libre2OwnershipRecord:")[0])
    executable = work / "location-tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-D", "LIBRE2_LOCATION_TESTS",
        "-module-cache-path", str(work / "module-cache"),
        str(helper), str(owner),
        str(addon / "Shared/Managers/Libre2WatchPreferences.swift"),
        str(addon / "Shared/DataModels/Libre2LocationRequest.swift"),
        str(addon / "Shared/Texts/Texts_DirectLibre.swift"),
        str(addon / "Tests/Libre2WatchLocationTests.swift"), "-o", str(executable)
    ], check=True)
    subprocess.run([str(executable)], check=True)

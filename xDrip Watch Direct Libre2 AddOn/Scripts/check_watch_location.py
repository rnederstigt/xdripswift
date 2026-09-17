#!/usr/bin/env python3
"""Execute the production location helper with location/lifecycle doubles, not GPS.

Only framework imports are replaced. No app preferences or sensor journal is used.
Compile against the Watch SDK as well; these checks cannot prove background runtime.
"""
from pathlib import Path
from swift_test_runner import run_swift, test_directory

addon = Path(__file__).resolve().parents[1]
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

#!/usr/bin/env python3
"""Exercise production one-shot scheduling with notification/WatchKit doubles, not alerts."""
from pathlib import Path
import subprocess
import tempfile

addon = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="direct-libre-notification-") as directory:
    work = Path(directory)
    helper = work / "Libre2WatchNotificationTest.swift"
    helper.write_text((addon / "Watch/Managers/Libre2WatchNotificationTest.swift").read_text()
                      .replace("import UserNotifications", "").replace("import WatchKit", ""))
    executable = work / "notification-tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-D", "LIBRE2_NOTIFICATION_TESTS",
        "-module-cache-path", str(work / "module-cache"), str(helper),
        str(addon / "Shared/DataModels/Libre2NotificationTest.swift"),
        str(addon / "Shared/DataModels/Libre2LocationRequest.swift"),
        str(addon / "Shared/Texts/Texts_DirectLibre.swift"),
        str(addon / "Tests/Libre2WatchNotificationTests.swift"), "-o", str(executable)
    ], check=True)
    subprocess.run([str(executable)], check=True)

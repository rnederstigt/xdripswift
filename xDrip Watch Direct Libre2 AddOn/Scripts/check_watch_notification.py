#!/usr/bin/env python3
"""Exercise production one-shot scheduling with notification/WatchKit doubles, not alerts."""
from pathlib import Path
from swift_test_runner import run_swift, test_directory

addon = Path(__file__).resolve().parents[1]
with test_directory("direct-libre-notification-") as work:
    helper = work / "Libre2WatchNotificationTest.swift"
    helper.write_text((addon / "Watch/Managers/Libre2WatchNotificationTest.swift").read_text()
                      .replace("import UserNotifications", "").replace("import WatchKit", ""))
    executable = work / "notification-tests"
    run_swift(executable, [
        helper,
        addon / "Shared/DataModels/Libre2NotificationTest.swift",
        addon / "Shared/DataModels/Libre2LocationRequest.swift",
        addon / "Shared/Texts/Texts_DirectLibre.swift",
        addon / "Tests/Libre2WatchNotificationTests.swift",
    ], flags=["-swift-version", "5", "-D", "LIBRE2_NOTIFICATION_TESTS"])

# Watch units and restart diagnosis

The Watch previously initialized `isMgDl` to true on every launch. Direct collection also rejected phone status messages, so a restart away from the phone could leave the display in mg/dL. The ownership journal could still restore collection independently; reconnecting does not explain why the process stopped.

`Shared/Readings/Libre2WatchPreferences.swift` now saves explicit units from fresh phone status messages in Watch UserDefaults. The Watch adapter restores them before starting the collector and uses the existing complication cache as a fallback when upgrading. This preference is independent of sensor sessions and survives returning, switching or replacing a sensor. It is not guaranteed to survive uninstalling the app.

Fresh unit updates are accepted even during direct collection. Other phone sensor status and readings remain excluded. A change converts the direct delta immediately and follows the existing payload dispatcher's complication refresh. Glucose history stays in mg/dL internally. Missing/malformed units or status older than the existing one-hour window cannot reset the preference. There is no extra timer, polling, or message request.

After installing, open the phone and Watch apps together and verify the desired units once. If the old build already overwrote its complication cache with the wrong units, only a fresh phone status can establish the intended choice. To test persistence, close/relaunch the Watch app while the phone is unreachable, then check the value, unit label, delta, graph and complication when readings resume. Test both mmol/L and mg/dL. This tests recovery, not the cause of an earlier crash.

## Collect the system report

An apparent crash can be an application exception, a watchdog termination, or a memory-pressure termination. Do not infer the cause from an automatic BLE reconnect or a units reset.

1. Record the approximate time and timezone, Watch model/watchOS version, installed app version/build and source commit. Note whether the screen was active, whether a workout was running, and whether the phone was reachable.
2. Connect the paired iPhone to the Mac. In Xcode, open **Window > Devices and Simulators**, select the device and **View Device Logs**. Locate the Watch app's report near that time; export the complete report. Also look for a corresponding `JetsamEvent` memory report.
3. Preserve the matching build/archive and dSYM files. Xcode needs matching symbols to translate crash addresses into function names and source lines. A new build's symbols cannot substitute for the crashed build's symbols.
4. Inspect the exception/termination reason and crashed thread. For a JetsamEvent, confirm the Watch app was the terminated process and inspect its memory information; these reports do not provide an application thread backtrace.
5. Correlate the report with the add-on's connection activity and, for a reproducible issue, capture device console logs and profile memory/CPU with Xcode Instruments. The bounded local activity journal is connection history, not a crash reporter; the phone's journal is not a copy of all Watch events.

No crash cause has been established from the reported walk. This units fix does not prevent watchOS from terminating the app and adds no continuous-background guarantee or crash-report upload service.

Validation: all 75 host tests passed, including four preference tests covering both unit choices, recreation, migration and invalid/stale messages. The upstream reading-relay comparison and Xcode source membership checks passed. The three changed/new Watch Swift files passed typechecking with the target's other source declarations available; the compiler emitted sandbox warnings during this check. A complete signed build and the on-device restart check remain outstanding.

Apple references: [crash reports and device logs](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs), [view device logs and matching symbols](https://help.apple.com/xcode/mac/current/en.lproj/dev85c64ec79.html), [JetsamEvent reports](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports).

# Testing and validation

This guide separates executable checks from device acceptance. See the [user guide](../README.md) for operation and [architecture](ARCHITECTURE.md) for the behaviour being tested. Source checks and simulated callbacks do not establish radio reliability, watchOS scheduling or remote upload receipt.

## Run the automated checks

Use a Mac with Xcode and its command-line tools selected. Run from the repository root; the recorded baseline commits must be available for comparison scripts.

```sh
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_integration.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_phone_import_routing.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_watch_location.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_watch_preferences.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_upstream_scanning.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_upstream_relay.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_watch_reconnect.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_phone_alignment.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_history_delivery.py"
```

Run the shared Swift package separately, keeping generated products outside the repository. This subshell removes only its own temporary directory on exit and preserves the test result:

```sh
(
    test_build=$(mktemp -d "${TMPDIR:-/tmp}/direct-libre-tests.XXXXXX") || exit 1
    trap 'rm -rf "$test_build"' EXIT
    swift test --package-path "xDrip Watch Direct Libre2 AddOn" --scratch-path "$test_build"
)
```

| Check | Evidence provided |
| --- | --- |
| Shared Swift package | Session/counter transitions, persistence failures, stale messages, cancellation, restart/reset recovery, protocol fixtures, history queues, cleanup confirmations and saved preferences. |
| `check_integration.py` | Xcode membership and platform separation. |
| `check_upstream_scanning.py` | NFC reader, callbacks and notices compared with master after removing documented hooks; also checks add-on UI restrictions. See the known failure below. |
| `check_upstream_relay.py` | Extracted original/current relay handlers retain ordinary behaviour. |
| `check_watch_reconnect.py` | Production collector with Bluetooth/timer doubles: subscription before unlock, counter ordering, reconnect, manual retry, failures and ownership barriers. |
| `check_phone_alignment.py` | Phone/Watch trend, arrow, time-gap and unit-rounding parity. |
| `check_history_delivery.py` | Production Watch coordinator with delivery/storage doubles: acknowledgements, mixed rejections, retries, stale responses and cleanup. |
| `check_phone_import_routing.py` | Ordinary downstream call parity, current/history routing and delayed-sharing preparation. No real upload or app-group delivery. |
| `check_watch_location.py` | Production location helper with lifecycle doubles: opt-in, permission, foreground start, ownership stop, temporary errors and live accuracy changes. |
| `check_watch_preferences.py` | Production display adapter: unit/limit persistence, migration, stale settings, relay assignments and complication refresh. |

**Known check failure:** the scanning script's broad ban on `.alert(` rejects the explicit unresolved-readings deletion confirmation. Rechecking during this documentation cleanup passed the preceding NFC source-comparison assertions before failing on that UI restriction; the complete script is not green. This does not identify a scan-path change; the UI assertion needs to distinguish sensor dialogs from the approved deletion confirmation. Do not silently ignore a different failure.

## Build and hosted tests

Build the existing iPhone and Watch targets in Xcode using your own signing settings and the default external DerivedData location. Do not commit personal team identifiers or generated products. Install both targets for protocol/settings compatibility.

`Libre2PhoneHistorySyncTests` require the hosted `xdripTests` target on an appropriate iOS destination. They exercise Core Data saves, sensor matching, deduplication, slope repairs, metadata and acknowledgement ordering; they are not executed by the macOS package. SDK compilation of this file is not execution of its tests.

### Recorded evidence

The latest feature revision is [`0a6b202`](https://github.com/rnederstigt/xdripswift/commit/0a6b202). Its accuracy-control validation recorded **96 host tests, 11 location-session checks and four preference-adapter checks passing**, plus membership and iPhone/Watch SDK source checks. This is recorded evidence, not a claim that every check was rerun for a documentation edit.

Earlier retained validation includes 21 collector checks, 476 trend comparisons, six history-delivery checks, 96 ordinary downstream parity cases, four import-routing cases and four delayed-sharing checks. These counts describe their respective runs, not one combined current test run.

Full unsigned builds were blocked by the local simulator-runtime service during existing widget/complication asset compilation. Hosted iPhone database tests were compiled but not executed. Complete signed builds, device timing, background reliability, battery comparisons and end-to-end integrations require validation on the installed revision. No automated result proves those outcomes. Git history retains the earlier dated reports.

## Device acceptance checklist

Record app revision, iPhone/Watch model and OS, sensor type, settings, reachability and timestamps. Compare ordinary behaviour against the named upstream baseline where applicable.

| Area | Verify |
| --- | --- |
| Ordinary operation | Without Direct Libre state, NFC success/cancel/failure, original notices/retries and relayed readings work without an experimental scan dialog. |
| Forward switch | Checklist requires a recent authenticated phone reading. Watch connects only after phone disconnection; antenna turns green before the first reading, including on “Waiting”. Confirm units, graph and complication. |
| Return and interruption | Interrupt each direction, restart either app and retry from the phone. Neither old owner may resume authentication prematurely. Returning during a manual reconnect must also stop Watch retries. |
| Reconnect | Leave/re-enter range. Test idle, pending, fresh and three-minute-stale double taps on both view types. Confirm one appropriate reconnect and advancing counters, without repeated unlocks after an invalid sample. Measure actual recovery times. |
| NFC recovery | Delete the phone sensor during an unresolved session. With Watch unreachable, cancel and retry ordinary NFC using a replacement sensor. Verify fresh phone readings; later delivery of old revocations must not stop a newer session. |
| History | Collect offline, reconnect and repeat delivery. Import once into the correct sensor, including across return/sensor change. Deleted/unknown sensor readings must remain unresolved without blocking valid batches. Storage failures retain pending data. |
| Explicit cleanup | Inspect unresolved count, cancel, then delete. Pending uploads/phone history remain. New unresolved data or a Watch restart invalidates an old confirmation; a lost reply must not schedule a background deletion. |
| Phone downstream effects | Fresh imports refresh missed-reading scheduling and configured live effects. Old/future/duplicate/superseded/ended-sensor values must not act as current readings. Test optional smoothing/cadence and verify actual Nightscout, HealthKit, Dexcom Share and OS-AID receipt, including nonzero sharing delay and existing cursor limits. |
| Preferences | Send all four limits and units, change limits alone, then restart offline before the first direct reading. Verify graph/complication and both units in direct and relay modes. Test an existing installation's cached preferences. |
| Background location | Off means no prompt. Enable while Watch owns the sensor; test foreground start, wrist-down and watch-face operation, stationarity, movement, poor fixes and range loss. Disable/return/reset stops location when delivered. Permission errors leave BLE untouched; a new background launch waits for foreground. |
| Accuracy | Confirm each 100 m / 1 km / 3 km selection after acknowledgement and restart, both while off and during collection. Unreachable/older companions must not display an unconfirmed change. |
| Water | Open xDrip, enable Water Lock manually and test wrist lowering/submersion, including beyond 30 minutes. Record execution and reception separately; neither automatic lock nor underwater connectivity is promised. |
| Upgrade | Check completed handoffs and saved queues without unnecessary rescanning. Legacy unfinished reclaim state should direct the user to ordinary NFC recovery. |

For battery/background trials, use matched 90–120 minute or longer runs without a debugger, repeated at each accuracy and with the option off. Keep screen use, movement, phone reachability and other location users comparable. Record percentage points per hour, distinct measurement timestamps, gaps and reconnects. An option-off run that becomes suspended is not an equal-work estimate of GPS cost. Measure data continuity alongside energy use.

## Diagnose an unexpected Watch closure

Record the time/timezone, model/watchOS, app revision, foreground/background state and phone reachability. Export the complete Watch crash/termination report and relevant JetsamEvent from paired-device/Xcode logs; retain the matching archive and dSYM. Confirm the process was terminated before attributing a memory-pressure report to it. Automatic reconnection does not establish the cause.

The bounded activity journal is connection diagnostics, not a crash reporter; the phone log does not contain every Watch event. Correlate reports with console and measurement timestamps. See [Apple's crash-diagnosis guide](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs).

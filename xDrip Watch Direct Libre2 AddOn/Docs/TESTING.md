# Validation

Run checks from the repository root on a Mac with Xcode command-line tools selected. The comparison scripts require the recorded baseline commits. Generated sources, executables and compiler caches stay in temporary directories.

## Automated checks

```sh
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_integration.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_upstream_scanning.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_upstream_relay.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_phone_handoff.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_watch_handoff.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_watch_reconnect.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_phone_alignment.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_history_delivery.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_phone_import_routing.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_watch_preferences.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_watch_background_tasks.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_watch_location.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_watch_notification.py"
```

Run shared unit tests with build products outside the repository:

```sh
(
    test_build=$(mktemp -d "${TMPDIR:-/tmp}/direct-libre-tests.XXXXXX") || exit 1
    trap 'rm -rf "$test_build"' EXIT
    swift test --package-path "xDrip Watch Direct Libre2 AddOn" --scratch-path "$test_build"
)
```

The shared package tests state transitions, counter ordering, protocol fixtures, journals, basic activity, unresolved readings and preferences. Platform harnesses execute production code with Bluetooth, WatchConnectivity, storage or location doubles. They verify callback ordering and policy, not real radios or OS scheduling. `swift_test_runner.py` shares compilation and cleanup only; each script selects its own sources and flags.

The scanning comparison checks original NFC commands, callbacks and scan UI outside explicit reset hooks. Experimental-page help and user-requested deletion confirmations are allowed; sensor/transport code may not introduce dialogs. Preference checks compare the reviewed host baseline after removing only the retired diagnostic hooks. Integration checks validate target membership and platform separation.

`Libre2PhoneHistorySyncTests` additionally needs the hosted iOS test target to execute real Core Data integration. It is not executed by the macOS package or storage-spy harness.

## Current evidence — 2026-09-17

- **113 shared unit tests passed.** Tests exclusive to removed tracing features were deleted; counter, persistence, recovery and basic activity coverage remains.
- **11 Watch handoff, 26 reconnect, 27 Watch delivery, eight phone scheduling, five background-task, five notification, 11 location and four preference checks passed.** Phone availability/retirement, downstream routing and ordinary relay checks passed, as did 476 phone/Watch trend comparisons.
- A one-off differential check compared the new native-only parser with the pre-reduction parser and collector validation on **1,000 deterministic frames**. Glucose, timestamps and cached parser state matched, including invalid and repeated frames.
- Affected iPhone and Watch sources passed SDK typechecking. The queued user-info handler is also compiled directly in the handoff harness, covering retirement routing, history acknowledgements and ordinary relay. The Watch host model was subsequently typechecked as a primary file with temporary declarations for its two asset-generated Color names; the earlier add-on-only source checks did not check this method body. Membership and whitespace checks passed. The phone app delegate, Watch notification controller and complication provider match audited upstream master exactly.
- No linked/signed build or physical-device test was completed for this reduction. Earlier full builds were blocked by local asset/simulator tooling. SDK typechecks are not installation or runtime evidence.

## Device acceptance

Install both current companion apps and test without a debugger where background execution matters. Record versions, time, sensor and relevant settings.

| Area | Verify |
| --- | --- |
| Ordinary phone operation | NFC success/cancel/failure and ordinary relay retain original notices and behaviour when Direct Libre is unused. |
| Switching | Phone → Watch and return; interrupt each phase, restart and retry. No authentication before activation or confirmed release. |
| NFC recovery | Reset an unresolved/deleted sensor with Watch unreachable, then restore communication. Old commands cannot reactivate the retired handoff; a new switch works. |
| Reconnection | Range loss, Bluetooth unavailable, double tap while idle/scanning/pending/connected, rapid taps and return during restart. Check antenna progress, retained history and advancing counters. |
| Native data/display | Compare phone/Watch glucose, age, trend, graph and complication; invalid frames do not disconnect or alter saved history. Test units and limits after offline restart. |
| Delivery | Collect offline and reconnect; latest data arrives independently of history. Duplicate/failed saves retain data without repeating live effects. Verify actual configured uploads/sharing and missed-reading scheduling. |
| Unresolved data | Unknown/deleted sensor readings do not block valid batches. Cancel/delete with confirmation; pending and phone history remain. |
| Activity | Basic log and manual Watch loading/export work without a tracing setting. No complication-value or process/timing diagnostics are produced. |
| Background support | Location off/on, three accuracy settings, permission changes, restart, wrist-down, stationarity and poor reception. Return/disable stops location when the command arrives. |
| Notification workaround | With both apps backgrounded, trigger the manual test and leave it untouched. Compare subsequent measurement timestamps without opening apps. No automatic notification or glucose alarm is introduced. |
| Water | Enable Water Lock manually; verify frontmost behaviour separately from glucose reception. Underwater BLE and continuous execution are not guaranteed. |

For battery comparisons use repeated, matched 90–120 minute runs at each accuracy and with location off, controlling screen use, movement and reachability. Measure fresh readings and gaps alongside percentage points per hour; a suspended run is not equivalent work.

For crashes retain the complete device crash/termination report and matching build/dSYM. The basic activity log cannot diagnose process scheduling or prove a crash cause; detailed lifecycle and complication tracing have been removed.

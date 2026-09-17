# Validation

Run from the repository root on a Mac with Xcode command-line tools selected. Source comparisons need the recorded baseline commits in local Git history; they never fetch or update master.

## Automated checks

One command runs the shared unit tests and all four groups of platform checks:

```sh
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/run_tests.py"
```

| Group | Coverage |
| --- | --- |
| `core` | Shared protocol, counters, ownership, journals, reading queues and settings. |
| `switching` | Phone availability/NFC retirement delivery, Watch handoff, reconnects and double tap. |
| `sync` | Latest/history delivery, phone import scheduling and downstream consumer routing. |
| `watch-support` | Persisted display preferences, background tasks, optional location and notification testing. |
| `integration` | Xcode membership, original NFC/relay behaviour and phone/Watch calculation alignment. |

To run selected groups, append their names, for example `switching sync`. The runner prints each result, continues after a failed check and returns a nonzero exit status if any check fails. Each Swift harness keeps its own platform doubles and executable. `Scripts/test_support.py` shares source extraction, compilation and temporary-directory cleanup.

Larger doubles and scenarios live in `Tests/Fixtures/*.swift`. Their `@source` markers are replaced with **current production code** by the group modules; they are not frozen copies of app methods. SwiftPM excludes this directory because these fixtures need separate executables or source substitution. Platform checks simulate callbacks and storage; they do not prove radio delivery, OS scheduling or real Core Data behaviour.

Generated sources, executables and compiler caches are removed from temporary directories after each check. In an already sandboxed runner that rejects SwiftPM's nested sandbox, use `--disable-package-sandbox`; ordinary local runs do not need it.

## Xcode builds and hosted tests

Add `--build` to run actual unsigned iPhone and Watch builds after the selected checks:

```sh
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/run_tests.py" integration --build
```

These use the repository's `xdrip` and `xDrip Watch App` schemes, real SDKs, assets and linked targets. No preview removal or asset-symbol stand-ins are used. Build products stay outside the repository and are removed afterwards; full build logs remain in the printed temporary directory. Set `--output /absolute/path/outside/repository` to choose that log directory. Unsigned builds cannot establish signing, installation or device behaviour.

`Libre2PhoneHistorySyncTests` needs the hosted iOS test target for real Core Data integration. Choose an installed simulator from Xcode's destinations and pass it explicitly:

```sh
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/run_tests.py" sync \
  --ios-destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-UUID'
```

Hosted tests and full builds are reported separately; neither is implied by passing the macOS tests.

## Current evidence — 2026-09-17

- **113 shared unit tests and all 13 platform/source checks passed**, including handoff, reconnect, delivery, preferences, downstream routing and 476 phone/Watch trend comparisons. The four integration checks were rerun successfully after restoring `Libre2PhoneSensorAdapter.swift` from the committed version to resolve an editor version conflict.
- During consolidation, all **13 generated Swift compiler inputs and their flags matched the previous launchers exactly**. No production source or behavioural test was removed.
- Both full unsigned Xcode builds were attempted with Xcode 26.3. Asset compilation failed because local CoreSimulator services/runtimes were unavailable. These are failed builds, not successful SDK validation.
- Hosted Core Data tests and physical-device acceptance were not run for this test-only consolidation.

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

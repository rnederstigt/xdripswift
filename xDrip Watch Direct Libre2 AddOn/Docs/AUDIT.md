# Audit against master

Scope: all committed changes from master baseline `53b3d6bf1b550c99b19c3d5d2c2f80dd226465d8`, including the subsequent refactor. The pre-refactor prototype at `226374a` contained 64 changed files, 6,999 additions and 27 deletions. This is a comparison to that precise baseline, not to an unverified newer master.

The refactor reduces add-on production Swift from 4,506 to 3,968 lines. The resulting proposed diff against the same master baseline contains 64 changed files, 6,241 additions and 28 deletions (personal signing changes excluded). File count alone does not measure scope: the role-based split adds small model files while removing obsolete controllers and documents.

## Findings addressed

| Finding | Resolution |
| --- | --- |
| Removed Reclaim via NFC button still had a second reader, coordinator, verification timer, retries and model transitions. | Deleted that workflow. Ordinary Add/Connect NFC is the single recovery route. Saved credentials remain compatible; unfinished legacy reclaim phases require a scan. |
| A reset/coordination failure could call the original transmitter's global error delegate during sensor addition. | Removed the experimental global-alert call. Errors remain in Advanced Settings and its journal. No extra confirmation or modal UI was added. |
| Explicit authentication diagnostics bypassed the dormant log guard during ordinary scanning/logins. | Removed forced logging and ordinary NFC counter telemetry. The original app's own diagnostic logging remains unchanged. |
| Watch contained unused NFC/FRAM decryption helpers and an unused reading-source/status facade. | Removed unused helpers and source enum/computed status. Renamed the retained crypto port to Libre2Crypto and the Watch entry point to Libre2WatchManager. |
| Text definitions retained removed controls, confirmation messages and unsupported states. | Removed 29 unused entries. Checklist results are Boolean; the unused three-state UI was removed. |
| Repeated identical transactions rewrote the ownership journal. | Skip unchanged records. Counter reservation, changed phases and failure handling still persist before side effects. |
| UI checklist layout and transaction execution shared a long coordinator file; diagnostics mixed unrelated models. | Separate settings presentation into an extension and place models, managers, transport, constants, texts and views in matching role folders. |
| Documentation described successive abandoned implementations and repeated out-of-date test counts. | Replace overlapping documents with a current user guide, integration map, audit and test guide. |

The reported forgotten popup cannot be identified with certainty. Master already shows Libre connection notices (including the instruction about Libre app Bluetooth permissions) and scan success/failure UI. Those notices are preserved. The source comparison checks the original reader, sensor callbacks and notices rather than removing unfamiliar UI indiscriminately.

## Every change outside the add-on

Paths are relative to the repository root. These are the nine existing Swift integration points and all other original-file differences from the baseline.

| Original file | Retained purpose / ordinary behaviour |
| --- | --- |
| `xDrip/BluetoothTransmitter/Generic/BluetoothTransmitter.swift` | Default-true Bluetooth policy and confirmed-disconnect callback. The policy guards queued writes, subscriptions, discovery, scans, reconnect and restoration. Other transmitters retain the default. The caller only receives completion after disconnect, not after requesting it. |
| `xDrip/BluetoothTransmitter/CGM/Libre/Libre2/CGMLibre2Transmitter.swift` | One adapter, observations of actual BLE login/readings and connection state, counter reservation, and NFC reset hooks. Original glucose parser/algorithm and NFC callbacks remain. Buffer reset and altered NFC retry are confined to experimental use/reset. |
| `xDrip/BluetoothTransmitter/CGM/Libre/Utilities/LibreNFC.swift` | Only an optional unlock-code argument, defaulting to the original 42. Reader commands, sensor checks and notices otherwise match master. No experimental type or expected-sensor restriction remains. |
| `xDrip/Managers/Watch/WatchManager.swift` | Routes explicitly keyed handoff/history messages, supplies existing database/session and forwards companion-state events. Original relay/request behaviour remains. |
| `xDrip/Managers/Application/RootApplicationCoordinator.swift` | One observer and handler refresh existing displays after durable Watch imports. It does not trigger new-reading alarms. |
| `xDrip/SwiftUIViews/Settings/Models/SettingsViewDevelopmentSettingsViewModel.swift` | One Advanced Settings entry. No version/header entry, scan-time sheet or global experiment dialog. |
| `xDrip Watch App/DataModels/WatchStateModel.swift` | One Watch manager, message/restore forwarding, direct-mode relay guards, and unit restoration. Exposes the existing complication refresh to the adapter. Ordinary reading relay and display timer remain. |
| `xDrip Watch App/Views/BigNumberView/BigNumberView.swift` | Replaces the age marker with a view that returns the original marker outside direct mode. |
| `xDrip Watch App/Views/MainView/SubViews/MainViewInfoView.swift` | Same age-marker integration for chart/AGP pages. |
| `xDrip-Watch-App-Info.plist` | Bluetooth usage/background declaration and the explicitly retained underwater frontmost declaration. No Motion usage key. |
| `xdrip.xcodeproj/project.pbxproj` | Add-on file groups and target memberships; previous build-path corrections. Tests do not ship in app targets. Personal signing configuration is kept local. |
| `xdrip.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` | Uses default DerivedData/build locations. |
| `xdrip.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` | Same workspace-level build-location correction. |
| `.gitignore` | Excludes local build/cache products and personal signing overrides. |
| `README.md` | Short experiment introduction linking to the add-on. |
| `xdrip-Bridging-Header-swift_2K9IH5TUSZLKY-clang_1I9XNFA44R9PL.pch` | Removes a previously tracked machine-specific build artifact. |

No Watch app entry-point or entitlement change remains. No Loop code, original sensor-deletion UI, database schema, ordinary iPhone crypto/parser, original alarms or original Watch timer was changed by this refactor.

## Intentional differences that remain

- **Ownership guards:** while switching/direct/unresolved, phone Libre BLE is disabled. Removing guards would allow simultaneous authentication. Other transmitters use the default-true policy.
- **NFC after experimental use:** ordinary Add/Connect is a hard reset of saved Direct Libre credentials. This intentionally differs from a never-used add-on: it persists fresh credentials and waits for disconnection. Cancellation cannot safely imply successful recovery. Ordinary scans without experimental state keep the upstream code, counter reset and retry behaviour, without journal writes.
- **Unlock exhaustion:** 65,535 cannot be incremented. The retained safeguard also affects ordinary Libre login at that limit; it prevents overflow and is not a general reconnect change.
- **Units:** the last explicit phone unit preference is restored after Watch restart, also in ordinary relay mode. Fresh unit-only updates may be accepted during direct mode. This was explicitly requested.
- **Underwater declaration:** changes the Watch's frontmost preparation behaviour app-wide, even in relay mode. It was explicitly retained in the minimal underwater version. It adds no submersion manager, runtime object, Motion permission, workout or automatic Water Lock.
- **History:** a durable Watch sample is eventually imported into its registered phone sensor even after return. This requires the root display-refresh hook and retained outbox/registry; it never grants sensor authority.

These exceptions prevent claiming absolute upstream equivalence. The agreed goal is minimal, explained integration, not removal of working switching, history or necessary recovery guarantees.

## Safeguards retained after review

Counter persistence-before-write, monotonically advancing counters, sensor/session identity checks, phase checks on delayed replies, retired IDs, saved peripheral identity, confirmed disconnect barriers, native calibration validation, history acknowledgement after durable save, and database sensor matching each protect a concrete failure mode. They are not removed to reduce line count. Watch reconnect/return retries remain; checklist and history synchronization introduce no periodic polling timer.

See [TESTING.md](TESTING.md) for automated evidence and remaining device/build limits, and [INTEGRATION.md](INTEGRATION.md) for the porting order and compatibility formats.

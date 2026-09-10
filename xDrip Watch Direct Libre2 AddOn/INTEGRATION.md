# Integration with xDrip4iOS

This directory contains the Direct Libre 2 Watch experiment, including platform adapters, protocol helpers, UI, tests and documentation. The app still compiles it into the existing iPhone and Watch targets. Moving the directory alone does not install or uninstall the feature: the integration points below and the target memberships are required.

The refactor is based on the published prototype at `4913bb9`. The upstream comparison base remains `53b3d6bf` (7.0.0 build 4231). The original prototype required 369 added lines across eight existing Swift files. The current add-on uses 181 added lines across those same files, including the connection and Watch session callbacks needed for event-driven refresh; the implementation has moved behind the hooks rather than being removed.

## Responsibilities and boundaries

- **Shared/Session** owns persisted credentials, counters and ownership transitions. Neither platform adapter may bypass these transitions.
- **iPhone/Libre2PhoneHandoff** coordinates switching and recovery through `Libre2PhoneSensor`. It does not refer to `CGMLibre2Transmitter` directly.
- **iPhone/Adapters/Libre2PhoneSensorAdapter** is the bridge to the original transmitter and its preferences/calibration types. It observes login/reading events, prepares the session on the Bluetooth queue and restores experimental credentials.
- **iPhone/Libre2PhoneReclaim** adapts the existing NFC reader to a persisted reclaim attempt. Sensor updates and connection operations go through `Libre2PhoneSensor`.
- **Watch/Libre2WatchHandoff** owns the transaction and lazily creates the Watch collector.
- **Watch/Libre2WatchAddOn** accepts relayed and direct readings through one validation/display path. It uses `Libre2WatchDisplay` rather than a concrete Watch model.
- **Shared/Readings** contains history merging, freshness/order validation and trend calculation, independently tested on the host.
- **Watch/Adapters/WatchStateModel+DirectLibre** maps accepted readings into existing xDrip fields and invokes the existing complication update method.

The original iPhone crypto/parser and ordinary NFC reader remain in place. Shared session/calibration/diagnostic types are compiled into both apps. The Watch protocol port and reading pipeline are compiled into the Watch and host tests; compiling the port's `PreLibre2` into the iPhone would conflict with the original class.

## Remaining changes outside the add-on

Paths are relative to the repository root. This is the complete integration/build/documentation footprint against the upstream base.

| Existing file | Purpose of the change |
| --- | --- |
| `xDrip/BluetoothTransmitter/Generic/BluetoothTransmitter.swift` | Generic `allowsBluetoothActivity()` policy, Bluetooth-queue execution and `disconnect(completion:)`. Scan/connect/write/discovery/restoration paths consult the policy. Confirmed disconnect callbacks return before automatic reconnect. Default policy remains true for other transmitters. No Direct Libre types or ownership logic live here. |
| `xDrip/BluetoothTransmitter/CGM/Libre/Libre2/CGMLibre2Transmitter.swift` | Owns one sensor adapter and forwards construction, connection, unlock-write, real-reading and ordinary-NFC events. Asks the adapter to reserve an unlock counter before the existing payload/write code. Keeps the existing parser and test-data replay distinction. Connection, disconnection, failed connection and Bluetooth state callbacks keep the checklist live without polling. Added lines reduced from 126 to 45. |
| `xDrip/BluetoothTransmitter/CGM/Libre/Utilities/LibreNFC.swift` | Optional recovery unlock code and expected sensor UID. Rejects a different UID before provisioning. Default callers retain the original arguments. Unchanged by this refactor. |
| `xDrip/Managers/Watch/WatchManager.swift` | Routes the experimental message to the add-on and forwards reachability, activation, pairing/installation and deactivation changes alongside the original update behavior. |
| `xDrip/SwiftUIViews/Settings/Models/SettingsViewDevelopmentSettingsViewModel.swift` | One Advanced Settings entry that opens the add-on's page. |
| `xDrip Watch App/DataModels/WatchStateModel.swift` | Owns one Watch add-on controller, forwards restore/messages/reachability and relayed readings, and guards relayed status during direct collection. Makes the existing complication update method available to the adapter. Added lines reduced from 127 to 12. |
| `xDrip Watch App/Views/BigNumberView/BigNumberView.swift` | Uses the add-on reading-age marker in the original dot position. |
| `xDrip Watch App/Views/MainView/SubViews/MainViewInfoView.swift` | Uses the same reading-age marker for chart/AGP pages. |
| `xDrip-Watch-App-Info.plist` | Bluetooth usage explanation and background-mode declaration from the prototype; does not grant unlimited runtime. |
| `xdrip.xcodeproj/project.pbxproj` | A folder hierarchy for the add-on and explicit platform source memberships. Also retains the build-path cleanup from the prototype. |
| `xdrip.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` | Uses Xcode's default build/DerivedData location. |
| `xdrip.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` | The same default build-location setting for the workspace. |
| `.gitignore` | Excludes build products, precompiled-header caches and personal signing overrides, including the add-on's local SwiftPM build directory. |
| `README.md` | Short experimental overview linking into this directory. |
| `xdrip-Bridging-Header-swift_2K9IH5TUSZLKY-clang_1I9XNFA44R9PL.pch` | Previously tracked machine-specific build artifact removed by the original cleanup commit. |

The generic connection guards are essential. A separate collector cannot stop the original transmitter from reconnecting unless its connection paths consult the policy. The disconnect completion must also remain tied to the actual Core Bluetooth callback, not a timer or an immediate acknowledgement.

## Checks and upgrades

Run from the repository root:

```sh
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_integration.py"
swift test --package-path "xDrip Watch Direct Libre2 AddOn" --scratch-path ../work/direct-libre-tests
```

The integration check verifies source paths, duplicate membership, platform separation and exclusion of host tests from app targets. The Swift package tests the Foundation-only components. App source checks/builds are still necessary because the host package does not compile the platform adapters.

When updating to a new upstream version, review the eight existing Swift integration points first, then run the integration check, host tests and both Xcode targets. Recheck the device acceptance sequence in README.md, especially ordinary NFC scanning, return after an interrupted switch and explicit NFC reclaim.

## Behavior deliberately preserved

The refactor does not change the persisted journal/message keys, session schema, counter reservation order, disconnect barriers, reclaim semantics, glucose conversion formulas. The subsequent refresh optimization removes the add-on's periodic UI timers as described below. It adds no workout session, background execution mechanism, alarm system or upload/backfill path. Existing installations do not need NFC solely because files moved; install matching phone/Watch builds and validate normal switching before relying on the new build.

## Event-driven display refresh

The phone page listens for connection/Watch session callbacks, relevant preference changes, ownership/NFC changes and new readings. Unrelated preference writes do not redraw the checklist. The reading timestamp is absolute, so its only scheduled refresh is the next freshness boundary. SwiftUI cancels that task when a new reading supersedes it, the page disappears or its scene becomes inactive. Showing the page or reactivating the scene reads current state immediately. The activity log posts changes only for actual additions or clearing.

The Watch marker listens to existing model updates and subscribes to `WatchStateModel.timer`; it creates no independent clock. A shared-clock tick changes the marker's local state only when receiving/freshness changes. The original Watch display timer and its existing data-request behavior are unchanged.

Session-store notifications are emitted after the in-memory state reflects the persistence result, including a failed journal write. UI subscribers deliver on the main run loop. Notifications do not alter transport, persistence ordering, ownership or counters.

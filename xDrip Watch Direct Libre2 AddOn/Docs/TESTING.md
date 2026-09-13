# Validation and device testing

Run from the repository root:

```sh
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_integration.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_upstream_scanning.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_upstream_relay.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_watch_reconnect.py"
swift test --package-path "xDrip Watch Direct Libre2 AddOn" --scratch-path ../work/direct-libre-tests
```

The host tests cover session encoding, N→N+1 ordering, persistence failure, stale messages, cancellation, full round trips, interrupted returns, reset/deletion/restart, legacy recovery records, protocol fixtures, readings, queued history, checklist freshness, bounded diagnostics and unit persistence. iOS-only `Libre2PhoneHistorySyncTests` require the hosted `xdripTests` target and test the actual database/acknowledgement path.

The scanning comparison strips only the documented add-on hooks, then compares the NFC reader and original sensor callbacks/notices against the recorded master. The relay comparison executes extracted original/current reading handlers. Neither substitutes for hardware testing.

The reconnect probe compiles the production Watch collector and shared journal/crypto/parser with Bluetooth and timer doubles. It covers discovery timeouts, pending known-peripheral connections, immediate reconnect, scan fallback, manual stale/first-reading recovery, repeated taps, counter persistence, ownership/return guards, Bluetooth resets, and ordinary gesture routing. It cannot measure radio latency or validate watchOS callback scheduling.

## Reconnect update validation — September 13

- **71 host tests and 16 deterministic Watch reconnect checks passed.** The probe executes the collector's real counter reservations, crypto, frame parsing and timer callbacks with test Bluetooth events.
- **iPhone SDK typecheck passed:** 30 primary sources. **Watch SDK typecheck passed:** 27 primary sources, including both gesture views. Compiler sandbox warnings were emitted.
- Membership, ordinary NFC comparison, ordinary reading-relay comparison and whitespace checks passed. Comparing the two gesture views to their previous revision confirms that only the manual refresh call changed; their timers/appearance handlers are identical.
- Full unsigned iPhone and Watch scheme builds failed during existing resource compilation because the environment could not access the `iphonesimulator`/`watchsimulator` runtimes. No physical-device reconnect timing improvement has yet been measured.
- Build products were kept outside the repository and removed afterward. Logs remain in the workspace's `validation/watch-reconnect` directory. Local signing settings were preserved.

## Earlier refactor validation results

- **71 host tests passed, zero failures.** Four tests for the deleted standalone reclaim workflow were removed; retained recovery tests now exercise ordinary NFC and old persisted reclaim records.
- Xcode source membership/platform checks, ordinary NFC source comparison, ordinary Watch reading-relay comparison and whitespace checks passed.
- **iPhone SDK typecheck passed:** 30 changed/add-on/hosted-test primary source files, with the rest of the target declarations available.
- **Watch SDK typecheck passed:** 26 primary source files, with the other 36 declarations (including generated asset symbols) available. Compiler sandbox warnings were emitted.
- An unsigned generic-iOS Xcode build, including the Watch dependencies, failed during existing resource compilation because the environment could not access simulator runtimes (`No available simulator runtimes for platform iphonesimulator`). A complete signed build and execution of iOS-hosted database tests remain outstanding.
- Refactored switching/NFC recovery has not been tested on physical devices. No new hardware reliability claim follows from source checks.
- Validation products were placed outside the repository and cleaned afterward; logs remain in the workspace.

## Device acceptance

1. Without using Direct Libre, add/connect a sensor, test NFC success/cancel/failure, normal relay, original notices and ordinary retry. There must be no new experimental dialog.
2. Open Advanced Settings, verify checklist/reachability and phone login; switch to Watch. Confirm the antenna turns green at Bluetooth connection, including on “Waiting…” before the first reading and with the phone unreachable. It remains green if readings grow stale while Bluetooth stays connected, and turns grey after disconnection. Confirm units, current value, graph and complication.
3. Separate Watch and phone, collect readings, then reconnect. Check phone chart imports once into the original sensor, including after returning or changing sensors. No new-reading alarm should fire for historical imports.
4. Disconnect/reopen the Watch app; verify reconnect, counter continuity and retained units without the phone. Test both mmol/L and mg/dL, including delta/complication.
5. Interrupt a forward switch and a return. Retry from the phone. Confirm the old owner never resumes authentication prematurely.
6. Delete the sensor during an unresolved handoff, then use ordinary NFC with another sensor and the Watch unreachable. Cancel once, retry, and verify fresh phone BLE glucose. Reopen Watch and confirm queued revocation cannot stop a newer session.
7. Test an old completed return and queued-history installation without scanning solely because of the refactor. An old unfinished standalone reclaim requires an ordinary scan.
8. Enable Water Lock manually, open xDrip, test wrist lowering/submersion and behaviour beyond 30 minutes. The minimal declaration does not promise indefinite frontmost operation, automatic lock or underwater radio reception. [Apple submersion guide](https://developer.apple.com/documentation/coremotion/accessing-submersion-data).
9. With Watch ownership, leave and re-enter sensor range. Confirm an immediate reconnect request and eventual fresh glucose. Double tap while connecting and while fresh: neither should restart the connection. For a connected session with no fresh reading for three minutes (including no first reading), double tap and confirm one disconnect/reconnect and a higher unlock counter. Repeat on the large-number and chart/AGP pages. Return from the phone during recovery and confirm the Watch cannot reconnect afterward. Compare reconnect times before/after on the same hardware; no improvement has yet been measured on-device.

## If the Watch app closes

Record time/timezone, model/watchOS, app build/commit, foreground/workout state and phone reachability. Export the full Watch crash/termination report and related JetsamEvent from Xcode/paired-device logs. Keep the matching archive/dSYM. Confirm the Watch app was actually terminated before attributing memory-pressure reports to it. Correlate the termination reason with device console/connection history; automatic reconnect does not establish the cause.

The local journal is connection diagnostics, not a crash reporter, and the phone's log does not contain all Watch events. No crash upload service or continuous runtime was added. [Apple crash diagnosis](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs).

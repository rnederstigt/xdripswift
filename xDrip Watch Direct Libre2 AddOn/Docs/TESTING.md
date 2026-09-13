# Validation and device testing

Run from the repository root:

```sh
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_integration.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_upstream_scanning.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_upstream_relay.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_watch_reconnect.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_phone_alignment.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_history_delivery.py"
test_build=$(mktemp -d "${TMPDIR:-/tmp}/direct-libre-tests.XXXXXX")
swift test --package-path "xDrip Watch Direct Libre2 AddOn" --scratch-path "$test_build"
rm -rf "$test_build"
```

The host tests cover session encoding, N→N+1 ordering, persistence failure, stale messages, cancellation, full round trips, interrupted returns, reset/deletion/restart, legacy recovery records, protocol fixtures, readings, queued history, checklist freshness, bounded diagnostics and unit persistence. iOS-only `Libre2PhoneHistorySyncTests` require the hosted `xdripTests` target and test the actual database/acknowledgement path.

The scanning comparison strips only the documented add-on hooks, then compares the NFC reader and original sensor callbacks/notices against the recorded master. The relay comparison executes extracted original/current reading handlers. Neither substitutes for hardware testing.

The reconnect probe compiles the production Watch collector and shared journal/crypto/parser with Bluetooth and timer doubles. It covers discovery timeouts, pending known-peripheral connections, immediate reconnect, scan fallback, manual stale/first-reading recovery, repeated taps, counter persistence, ownership/return guards, Bluetooth resets, and ordinary gesture routing. It cannot measure radio latency or validate watchOS callback scheduling.

The phone-alignment probe executes the phone's current slope, unit conversion and Watch-payload methods against the Watch trend calculation. It covers arrow boundaries, subminute/equal timestamps, the 21-minute gap boundary, missing history, rounding and repeated unit changes. The collector probe also checks notification-before-unlock ordering, subscription/write failures, return during subscription, and a valid frame following an invalid decoded measurement without disconnecting.

The history-delivery probe runs the production Watch coordinator with explicit WatchConnectivity replies and an injected journal writer. It checks mixed-batch rejection, queued/interactive duplicate replies, background delivery, transient errors and failed persistence. Host tests cover unresolved-data retention, legacy journal migration, restart, response-ID validation and late acknowledgements. Hosted iPhone tests cover deleted/unknown sensors in mixed batches and durable import of the remaining readings.

## History recovery and verification removal — September 13

- **80 host tests and six Watch history-delivery checks passed.** Coverage includes existing blocked journals, mixed batches, retention across restart, stale/duplicate replies and persistence failure. Transient transport/database errors continue to retry their original batch.
- **Device SDK source checks passed:** 30 iPhone primary sources (including the hosted database tests) and 24 Watch primary sources. Compiler sandbox warnings were emitted. The iPhone database tests were compiled, not executed.
- Membership, ordinary NFC comparison, ordinary Watch relay comparison and whitespace checks passed. All source edits are within the add-on, with no new host hooks or project changes. Existing local signing overrides were preserved.
- Full unsigned iPhone/Watch builds remain blocked by unavailable simulator runtimes during existing widget/complication asset compilation. On-device queue recovery and the streamlined checklist still need verification.
- Temporary compiler products were removed after retaining logs in the workspace's `validation/history-recovery` directory. The earlier phone/Watch alignment changes remain in this working copy.

## Phone alignment validation — September 13

- **74 host tests, 21 collector checks and 476 phone/Watch trend comparisons passed.** Repeated unit changes also preserve the expected delta, and the ordinary relay guard remains intact.
- **Watch device SDK typecheck passed:** 24 primary sources with 38 supporting declarations, including all changed production files. Compiler sandbox warnings were emitted.
- Membership, ordinary NFC comparison, ordinary reading-relay comparison and whitespace checks passed. All source changes are within the add-on; the existing personal signing overrides are unchanged.
- Full unsigned iPhone and Watch scheme builds failed during existing widget/complication asset compilation because the environment could not access the `iphonesimulator`/`watchsimulator` runtimes. A complete device build and hardware validation of the new startup sequence remain outstanding.
- Temporary compiler/test products were kept outside the repository and removed afterward. Logs remain in the workspace's `validation/watch-phone-alignment` directory.

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
10. Verify initial handoff and reconnect with the new subscription-before-unlock sequence. Compare trend/delta for identical readings in relayed and direct modes, including repeated unit changes. In a controlled test with an invalid decoded measurement, confirm there is no new unlock attempt and the next valid measurement resumes on the same connection.
11. With unsynchronised Watch readings, delete the original phone sensor, connect a replacement through ordinary NFC and collect new Direct Watch readings. Update both apps, restore phone reachability and confirm the unmatched-data log entry, successful import into the replacement sensor, and persistence of unresolved readings on Watch after restart. Repeat with queued delivery. Database-save errors must retain their original batch for retry.
12. Confirm the experimental page has no Verify phone connection button. Its login/reading checklist must still prevent a handoff from an unverified stream. Stop Scanning/Disconnect, Connect and an ordinary NFC scan followed by fresh BLE glucose must make the checklist ready again.
13. With unresolved Watch readings and pending uploads, open both apps and tap **Delete unresolved readings** on the experimental phone page. Confirm the count, cancel once, then delete. The count must become zero, Recent activity must show the deletion, and pending uploads and phone history must remain intact after Watch restart. Check that the action is disabled when Watch is unreachable, reports zero without a deletion prompt for an empty collection, and requests a new confirmation if more readings become unresolved or Watch restarts while the prompt is open. A lost reply must never schedule a background deletion.

Cleanup host tests cover request encoding, stale confirmations, restart, durable deletion, failed writes and preservation of pending batches and duplicate detection. The Watch coordinator probe checks read-only inspection, persistence-before-reply, errors, malformed requests and duplicate commands arriving after new unresolved readings.

## If the Watch app closes

Record time/timezone, model/watchOS, app build/commit, foreground/workout state and phone reachability. Export the full Watch crash/termination report and related JetsamEvent from Xcode/paired-device logs. Keep the matching archive/dSYM. Confirm the Watch app was actually terminated before attributing memory-pressure reports to it. Correlate the termination reason with device console/connection history; automatic reconnect does not establish the cause.

The local journal is connection diagnostics, not a crash reporter, and the phone's log does not contain all Watch events. No crash upload service or continuous runtime was added. [Apple crash diagnosis](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs).

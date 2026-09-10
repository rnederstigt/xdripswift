# Phone-controlled Direct Libre Watch proof of concept

This checkout adds an opt-in, foreground Libre 2 connection experiment. All switching and recovery controls are on iPhone. The Watch has a direct-connection indicator and accepts commands from its paired phone.

Base: xDrip4iOS `53b3d6bf1b550c99b19c3d5d2c2f80dd226465d8` (7.0.0 build 4231). Branch: `experimental/libre2watch`. The experiment is contained in this add-on directory with the original-app hooks documented in INTEGRATION.md; it does not require Loop changes.

## Experimental workflow

1. Build and install **both** the iPhone and companion Watch app from this checkout. Open `xdrip.xcworkspace`; use the existing signing configuration appropriate to your devices. This experiment has a separate WatchConnectivity message key and journal from the previous experiment; do not mix companion versions.
2. Make xDrip the valid Libre owner using your manually verified procedure. Confirm ordinary iPhone NFC scanning and BLE glucose work first. The proof of concept requires master mode, the Libre **Native Algorithm**, valid sensor conversion parameters, and **Suppress Unlock Payload off**. The sensor must be past warm-up.
3. Keep both apps open. On iPhone, open **Settings → Advanced Settings → Direct Libre (Experimental)**. This entry remains visible even when connection prerequisites fail, so recovery remains accessible. Check companion installation, communication activation, Watch reachability, phone BLE connection and a glucose reading less than three minutes old.
If **Recent Libre reading** is checked but **Phone login and reading verified** is not, use **Verify phone connection** within the iPhone checklist group and wait for a new BLE reading. This reconnects with the existing credentials without an NFC scan; it also makes a restored stream’s phone login observable. The reading row shows the time of the latest actual BLE update.

4. Tap **Switch to Watch**. The phone saves its current session, obtains Watch READY, disables its Libre reconnect path and waits for confirmed disconnect before activating Watch. The phone’s **Watch selected** state means activation was acknowledged; it is not a report that Watch has received glucose.
5. On any Watch glucose page, look for the antenna icon **before** the reading age ("… mins ago"), replacing the usual dot in Direct Watch mode. **Green** requires a live local BLE connection and a direct reading less than three minutes old. **Grey** means the direct connection is waiting, disconnected or stale. Outside Direct Watch mode, the original dot returns. The same marker is used on the large-value, chart and AGP pages. For an additional observation, inspect the Watch’s Bluetooth settings while connected; accessory listing visibility is controlled by watchOS. The local collector and direct readings remain the application’s evidence of the connection.
6. To return, use the same primary button, now labelled **Switch to iPhone**. This also cancels a pending outbound switch. During an interrupted return, the button reads **Retry return to iPhone**. Keep both apps open: Watch freezes and sends its latest attempted counter, waits for phone persistence, disconnects, then commits the return. Phone can reconnect only afterward. Verify a new phone glucose reading. Watch automatically retries an interrupted return acknowledgement while the app can run.
7. If normal return cannot finish, tap **Reclaim via NFC** on iPhone and confirm the in-app prompt. This action is available without a reachable Watch, including after a journal failure. Scan the **same sensor**. Recovery provisions a new unlock code and resets the sensor counter through the existing NFC command. A different sensor is rejected before sending that command.
8. NFC completion alone is **not** success. The phone closes any previous BLE connection, authenticates using the new code and waits for fresh glucose. Only then does the page say **Phone reclaim verified**. After 45 seconds without verification, it shows **Reclaim not verified**. Keep Bluetooth on and the phone near the sensor; use the primary **Retry iPhone connection** button after confirmed NFC, or repeat **Reclaim via NFC**. Cancelling or failing NFC leaves recovery available and phone BLE blocked.
9. The phone page initially shows five recent activity entries. **Show more** reveals five older entries at a time, up to the 80-entry persisted limit; **Show less** collapses the list again. Log browsing never changes sensor counters or ownership.

There are no experiment controls in the Settings header/version area or on a separate Watch page. The ordinary sensor scan entry remains usable when phone is selected. During an unresolved/direct Watch session it explicitly points to the Advanced Settings recovery page.

## What is implemented

| Milestone | Implementation |
| --- | --- |
| Contained protocol reuse | Foundation-only Watch crypto, frame assembly, conversion and parsing under `Shared/Protocol/`. Phone retains its existing crypto and parser implementation unchanged. |
| Phone control and persistence | Persisted session identity, credentials, calibration, counter and transaction phases. New phone BLE attempts are blocked outside phone/explicit reclaim verification phases. |
| Forward switch | PREPARE → READY → confirmed phone disconnect → ACTIVATE. Watch creates its collector only after activation, or to close a previously saved connection. |
| Watch collection | FDE3 service; persist counter increment before F001 write; subscribe F002 after the successful write callback, following the inspected DiaBLE ordering. Assemble 46-byte frames, authenticate/decrypt and convert using existing sensor parameters. |
| Normal return/cancel | Phone requests return; Watch sends M; phone persists M; Watch disconnects; COMMIT enables phone. Next phone attempt is M+1. Lost acknowledgement retries cannot restore an older counter. |
| Explicit NFC reclaim | Phone-local persisted recovery attempt; new code; same-UID scan restriction; best-effort old-session revocation on Watch; fresh phone BLE evidence required. Reclaim never waits for a Watch reply to open NFC. |
| Display and diagnostics | Shared reading-acceptance path in WatchStateModel, existing complication updates, direct/stale indicator, phone checklist/reachability/log. |
| Project integration | Target memberships, Watch Bluetooth usage/background declaration, default DerivedData settings, no signing/entitlement changes. |

The intended recovery property is **phone-controlled provisioning**, not guaranteed instantaneous remote disconnection. An unreachable Watch cannot be commanded to stop through WatchConnectivity. Whether the sensor immediately displaces an already authenticated Watch connection and refuses its previous code after reprovisioning must be established on physical hardware.

## State and ordering rules

- Phone stays connected during PREPARE, but new authentication attempts are frozen. Both devices save state before acknowledging a phase that could let the other device authenticate.
- Phone owns the control plane; explicit persisted connection state still prevents competing BLE reconnects. Removing that state would not make switching safer.
- Watch counters are reserved and synchronously persisted before payload generation/write. A failed write or disconnect never rolls a reservation back. Exhaustion fails instead of wrapping.
- Returned and reclaimed phone counters are also saved in the experimental journal before writes. Ordinary phone use without an experimental session does not depend on experimental journal writes.
- Reclaim uses a random new unlock code with enough numeric headroom for every UInt16 counter. It retires the old handoff ID before NFC. A stale READY, ACTIVATE, return or revoke cannot supersede the new attempt.
- A confirmed NFC command is persisted before defaults are updated. This permits recovery after termination between those operations. Phone BLE remains blocked until the disconnect barrier completes; only a fresh authenticated phone reading completes reclaim.
- The journal is stored in app Application Support at `PhoneControlledLibre/ownership.json`; logs use `phoneControlledLibreActivityLog`. Credentials are not included in this diagnostic log. Existing upstream developer traces are unchanged.

## Add-on layout and review order

All experimental sources, host tests and this documentation are inside this directory. Xcode presents the same folder hierarchy. This is a source add-on compiled into the existing application targets; it is not a runtime plug-in or a separate distributable framework.

1. `Shared/Session/`: session format, ownership, recovery state, persistence and message types. These preserve the original prototype's on-disk keys and transaction ordering.
2. `iPhone/Libre2PhoneHandoff.swift` and `Watch/Libre2WatchHandoff.swift`: forward/return/recovery coordination over the existing WatchConnectivity session.
3. `iPhone/Libre2PhoneSensor.swift` and `iPhone/Adapters/Libre2PhoneSensorAdapter.swift`: the sensor interface and the mapping to the existing iPhone transmitter. The adapter owns freshness, login observation, credential restoration and session preparation. `iPhone/Libre2PhoneReclaim.swift` adapts the existing NFC reader.
4. `Watch/Libre2WatchCollector.swift` and `Shared/Protocol/`: Watch BLE collection and the existing protocol algorithms. The iPhone retains its original crypto/parser implementation.
5. `Watch/Libre2WatchAddOn.swift`, `Watch/Adapters/WatchStateModel+DirectLibre.swift` and `Shared/Readings/Libre2ReadingPipeline.swift`: source selection, history merging, trend calculation, reading validation and the bridge to existing Watch display/complication updates.
6. `iPhone/UI/`, `Watch/UI/` and `Shared/Diagnostics/`: Advanced Settings entry, checklist, controls, log, indicator and text.
7. `Tests/` and `Package.swift`: the host-test harness. `Scripts/check_integration.py` checks Xcode source paths and platform membership without building.

See [INTEGRATION.md](INTEGRATION.md) for the complete list of changes outside this directory and why each is necessary.

## Validation and remaining work

- **50 focused host tests passed**, zero failures: session serialization, counter progression/persistence-before-write, exhaustion, protocol fixture/parsing, exclusive ownership, cancellation, delayed IDs, interrupted returns, bounded logs, normal-NFC isolation and reclaim recovery. Checklist regressions cover received-but-unverified BLE data, freshness bounds, reconnect reset and older observations. Switch-button regressions cover pending returns and confirmed NFC recovery. Four reading-pipeline regressions cover overlap replacement, malformed/out-of-order data, timestamp bounds and trend calculation after extraction into the add-on. Seven refresh regressions cover freshness deadlines, replacement/reset, clock rollback, ownership notification ordering and failed persistence, NFC activity and log change notifications.
- **Native SDK Swift checks passed after the refactor:** 21 changed/add-on iPhone source files checked against the complete target declarations, and all 59 Watch Swift inputs (including generated asset symbols). These validate Swift compilation/types, not asset processing, linking, signing or installation. The Xcode membership check also passes for both targets.
- **Full iPhone and Watch Xcode builds:** both stopped at asset compilation because this environment could not access simulator runtimes (`No available simulator runtimes`). Signing was disabled for these validation attempts only. A full build, signing and installation have not been verified here.
- **No sensor/phone/Watch hardware tests were performed.** NFC regression checks, direct readings, reconnection and active-Watch displacement remain required.
- This is a foreground proof of concept. There is no HKWorkoutSession mode, continuous-background guarantee, direct-reading upload/backfill to the phone, new Watch alarm system or production reliability claim. The existing Watch complication update path is called, but its device behavior still needs testing.
- `bluetooth-central` is declared for Watch, but it does not grant unlimited execution. Apple documents Bluetooth work within permitted background tasks; this iteration adds no runtime-extension or restricted Bluetooth entitlement. [Apple: Using background tasks](https://developer.apple.com/documentation/watchkit/using-background-tasks).

### Device acceptance sequence

1. With Direct Libre unused, scan the working sensor normally; cancel and retry a scan; verify new phone BLE data. Confirm ordinary app behavior and signing for its embedded extensions.
2. Switch to Watch; verify actual direct glucose and fresh timestamps. Observe phone remaining disconnected. Drop/reconnect Watch BLE and verify a higher counter is used.
3. Return using the phone; verify fresh phone BLE data. Cancel during PREPARE and again after Watch activation. Test both apps being relaunched during each transfer phase.
4. Interrupt communication around RETURN_COMMIT; verify automatic Watch acknowledgement retry does not overwrite a newer phone counter.
5. Reclaim with Watch reachable; then repeat with Watch actively connected but unreachable from the phone. Verify fresh phone authentication and glucose, and whether old-code Watch attempts are rejected. Record the sensor version and both OS versions.
6. Cancel NFC reclaim, scan a different sensor, interrupt Bluetooth during verification, and terminate/reopen the phone after NFC completion. Verify recovery stays accessible and no old callback restores an earlier session.
7. Keep the experimental page visible while Watch reachability and phone Bluetooth change; confirm the checklist follows without navigating away. Stop incoming readings and confirm the fresh/verified rows and switch button expire three minutes after the last BLE reading. Resume readings, then leave/reopen the page and background/foreground the phone; confirm current state returns immediately. Check new activity entries appear without periodic refresh.
8. On each Watch glucose page, verify green for fresh direct readings, grey after disconnection or three minutes without a reading, and the normal dot after returning to phone. No additional indicator clock should appear in a timer profile.
9. Only after these pass, consider a separate background/exercise milestone.

### Reproducing host tests and keeping products outside the checkout

From this checkout:

```sh
swift test --package-path "xDrip Watch Direct Libre2 AddOn" --scratch-path ../work/phone-poc-tests
```

Use Xcode's default DerivedData location. The project no longer specifies empty SYMROOT/OBJROOT/SHARED_PRECOMPS_DIR values, which could resolve products against `/` or the source folder. For command-line builds, explicitly set a DerivedData directory outside this checkout. The machine-specific precompiled bridging-header artifact inherited from the base was removed from this checkout only. Generated validation caches can be discarded without touching source. Local development logs are not included in this branch.

## Build configuration and attribution

Use your own Apple development team through the existing ignored `xDripConfigOverride.xcconfig` file at the repository root (set `XDRIP_DEVELOPMENT_TEAM` to your team ID). Keep personal signing overrides and credentials out of commits. Source sharing does not require setting up the inherited GitHub signing workflows or uploading signing secrets.

The Watch protocol helpers are adapted from the Libre 2 implementation already present in [xDrip4iOS](https://github.com/JohanDegraeve/xdripswift); existing source notices, including the DiaBox notice in `PreLibre2.swift`, are retained. Inspection of [DiaBLE](https://github.com/gui-dos/DiaBLE) informed the F001/F002 ordering and explicit NFC reprovisioning approach. This branch retains the repository's original [licence](../LICENSE).

## Refactor compatibility

The refactor keeps sensor credentials, counter rules, ownership phases, WatchConnectivity message keys and persistence paths unchanged. It does not require a new NFC provisioning step just because source files moved. Build both companion apps from the same branch. The add-on no longer creates two-second UI refresh schedules. Connection, settings, ownership, readings and log events update the phone page. While the page is active, a single cancellable deadline updates freshness when needed. The Watch indicator reuses the upstream display clock and changes its local state only when receiving/freshness changes. The upstream Watch timer and radio-request behavior are unchanged; battery savings have not been measured.

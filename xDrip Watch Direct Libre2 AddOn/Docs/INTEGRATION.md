# Integration map

The comparison base is upstream master commit `53b3d6bf1b550c99b19c3d5d2c2f80dd226465d8` (7.0.0, build 4231). This identifies the audited code precisely; it does not imply that a later master has been fetched or audited.

## Entry points

| Start here | Responsibility |
| --- | --- |
| `iPhone/Managers/Libre2PhoneHandoff.swift` | Phone actions and PREPARE/ACTIVATE/RETURN transactions. |
| `iPhone/SwiftUIViews/Libre2PhoneHandoff+Settings.swift` | Checklist and switch-button presentation, separated from transaction execution. |
| `iPhone/BluetoothTransmitter/Libre2PhoneSensorAdapter.swift` | Bridges the original Libre transmitter to the handoff. Tracks observed BLE login/reading and coordinates ordinary NFC reset. |
| `iPhone/BluetoothTransmitter/Libre2PhoneSensor.swift` | Small transport interface used by the phone coordinator. |
| `Watch/Managers/Libre2WatchManager.swift` | Watch model entry point: handoff, direct display and history synchronization. |
| `Watch/Managers/Libre2WatchHandoff.swift` | Watch message handling, restore, return and revocation. |
| `Watch/Managers/Libre2WatchLocationSession.swift` | Optional foreground-started background location, independent of sensor transport. |
| `iPhone/SwiftUIViews/Libre2LocationSettingsView.swift`, `Shared/DataModels/Libre2LocationRequest.swift` | Interactive read/change of the Watch’s saved location preference through the existing message handler. |
| `Watch/BluetoothTransmitter/Libre2WatchCollector.swift` | CoreBluetooth lifecycle, reconnect, authentication and frame processing. |
| `Watch/DataModels/WatchStateModel+DirectLibre.swift` | Applies direct readings and units to the original display/complication fields. |
| `Shared/Managers/Libre2SessionStore.swift` | Locked journal and explicit ownership/counter transitions. |
| `Shared/DataModels/Libre2Ownership.swift`, `Libre2WatchSession.swift`, `Libre2HandoffMessage.swift` | Persisted state and wire format. |
| `Shared/Protocol/Libre2Core.swift`, `Libre2Crypto.swift` | Watch BLE protocol port. The original iPhone NFC, crypto and parser remain in place. Source attribution is retained. |
| `Shared/Managers/Libre2ReadingPipeline.swift` | Direct display history merge, trend and validation. |
| `Shared/Managers/Libre2WatchPreferences.swift` | Last explicit units and glucose limits, complication-cache migration and background-location opt-in. |
| `iPhone/Managers/Libre2PhoneHistorySync.swift`, `Libre2PhoneReadingProcessing.swift` | Durable imports, stored slopes and the adapter to the host’s shared downstream workflow. |
| `Shared/Managers/Libre2ActivityLog.swift` | Bounded diagnostics, dormant outside experiment/page use. |

Use `Constants`, `Texts`, `DataModels`, `Managers`, `BluetoothTransmitter` and platform view folders as in the host. Dependencies flow from views to managers, then to shared models/persistence and platform transport. The two adapters retain host-specific types; no dependency-injection framework or new app lifecycle delegate is involved.

## Switching protocol

Each switch has an immutable session ID, sensor identity, conversion coefficients and streaming credentials. The counter may only advance. The saved owner controls every connection/authentication entry point.

| Step | iPhone | Watch |
| --- | --- | --- |
| PREPARE(N) | Persists `preparingWatch`; current BLE connection stays open but new authentication is frozen. Registers the database sensor before sending. | Validates/persists credentials, replies READY. Cannot connect. |
| ACTIVATE | Persists `releasingPhone`; waits for CoreBluetooth disconnection before sending ACTIVATE. | Persists `watch`, then creates/starts the collector. |
| Collection | Cannot scan, reconnect, discover, subscribe or write to Libre. | Persists counter N+1 before attempting F001. Never reuses an attempted counter. |
| REQUEST_RETURN | Persists `returnRequested`; forward replies can no longer activate Watch. | Freezes authentication, sends RETURN_PREPARE(M). |
| RETURN_PREPARE | Persists M and `returningToPhone`, replies READY. | Persists `releasingWatch`, disconnects; retrieves saved peripheral after a restart if necessary. |
| RETURN_COMMIT | Restores phone ownership only after Watch confirms disconnect. Next login advances M to M+1. | Retires the ID after acknowledgement; retries an interrupted return. |

Keep the disconnect barriers, counter persistence, stale-ID checks and phase checks together when porting. A cancellation request is not a confirmed disconnect. Repeated messages are expected; they must not overwrite newer credentials or counters. Unchanged journal transitions no longer rewrite the file.

## Watch reconnection and manual refresh

The Direct Watch antenna reflects only the collector's Bluetooth connection. Connection/disconnection callbacks refresh the existing Watch model, including before any glucose arrives and during return to the phone. Reading age remains separate; the antenna no longer stores its own freshness state or subscribes to the display timer. Ordinary relay mode keeps its original marker.

`Libre2WatchCollector` follows the phone Libre transport's ordinary reconnect policy: retrieve the saved peripheral before scanning, request reconnection immediately after range loss, and let a known peripheral's request remain pending while out of range. Only a scan-discovered connection gets the phone's five-second limit (`BluetoothTransmitter.maxTimeToWaitForPeripheralResponse`); `didConnect` cancels it. Scanning and waiting for glucose have no automatic deadline. A timed-out scan-discovered attempt falls back to scanning after confirmed cancellation. Explicit protocol failures retain the existing five-second backoff to avoid rapid unlock/failure loops.

The two original double-tap handlers call `WatchStateModel.refreshAfterDoubleTap()` in the add-on extension. It routes ordinary relay mode to the original phone refresh, and direct mode through the Watch manager/handoff to the collector. Only persisted `.watch` ownership permits a retry. The original display timer and automatic phone requests never invoke the retry method.

A manual retry starts an idle collector immediately, bypassing any pending failure backoff. For an already connected sensor, it requires a reading at least three minutes old; if no reading has ever arrived on this connection, it uses the connection timestamp. It waits for confirmed disconnect before reconnecting and does not clear parser history or reset credentials/counters. Scanning, connecting, disconnecting and fresh connections are left alone. No polling timer, Watch ownership control, runtime session or NFC change is involved.

## Phone behaviour reused by the Watch

The collector follows `CGMLibre2Transmitter`'s streaming startup: discover F001/F002, enable F002 notifications, wait for subscription confirmation, then reserve/persist the next counter and write F001. Duplicate subscription callbacks do not send another unlock. A failed subscription consumes no counter; a failed write still consumes its reserved counter. Ownership and confirmed-disconnect barriers remain in place.

Invalid decoded glucose is discarded without disconnecting, as in the phone parser. The next valid frame can resume readings on the same connection. Native calibration validation remains mandatory; invalid/raw fallback values are not displayed or uploaded. Bluetooth setup and unlock failures still use the existing recovery path.

`Libre2ReadingPipeline.trend` follows `Calibrator.findSlope`, `BgReading.slopeOrdinal` and `WatchManager.currentBgReadings`: the same arrow thresholds, elapsed-time calculation, hidden slope with insufficient history/equal timestamps/gaps over 21 minutes, and mmol/L rounding before subtraction. A unit change recalculates delta from the stored mg/dL readings. `Scripts/check_phone_alignment.py` executes the actual phone methods against the Watch implementation with identical inputs. This comparison does not import the phone's separate calibration, smoothing or database pipeline into the Watch.

## Ordinary NFC recovery

With no experimental state, the NFC reader uses its original code (42), commands, callbacks, notices and retry behaviour. The add-on only marks the in-progress scan so a simultaneous handoff cannot begin. No experimental journal write is required.

After Direct Libre use, an ordinary scan retires the old session, persists a new streaming code, and queues a session-bound Watch revocation. NFC must confirm provisioning and the old phone BLE connection must close before phone reconnection is allowed. A failed/cancelled/interrupted reset remains recoverable through another ordinary scan, including for a different/new sensor. Only reset scans clear the original NFC-reader reference to permit a retry on the same transmitter instance.

`LibreNFC` has one optional unlock-code argument. It has no Direct Libre types, expected-sensor restriction or second recovery reader. Experimental reset errors appear in Advanced Settings and its log, not in a global sensor alert.

## History synchronization

`Watch/Managers/Libre2WatchHistorySync` saves the newest real sample from each frame before display. `Libre2HistoryQueue` keeps an immutable outgoing batch until the phone acknowledges its IDs. It sends immediately when reachable or uses WatchConnectivity's queued delivery; events drive retry, without a periodic synchronization timer. Batches contain at most 120 readings and no unlock credentials. Display-interpolated points are not uploaded.

`iPhone/Managers/Libre2PhoneHistorySync` maps each handoff to its original Core Data sensor via `Libre2HistoryRegistry`. It rejects unknown/deleted sensors rather than guessing the active sensor. Deterministic reading IDs and switch-boundary overlap checks prevent duplicates. `Libre2PhoneReadingProcessing.updateSlopes` uses the host's `BgReading.calculateSlope` on chronological, visible readings from the same sensor. It includes a preceding context window and repairs following slopes after a late insert. Saving slopes and readings through the child, main and persistent-store contexts precedes acknowledgement.

The root coordinator's `processStoredGlucoseData` contains the original downstream block, shared by ordinary phone acquisition and the existing import observer. Its defaults preserve the phone call order, calibration branch and arguments. Imported changes to the active sensor run the existing optional post-processing and noise managers. Ended-sensor imports do not reprocess an unrelated active sensor; duplicate batches without changed rows do not need another processing pass. No second calibration/conversion of factory-converted Watch values is performed.

After a durable save, `Libre2PhoneHistoryUpdate` permits a current-reading notification only when the batch contains the newest stored reading for the active sensor, within the host alert age limit (240 seconds), with no future timestamp or repeat in the same importer lifetime. The adapter rechecks the visible newest reading after post-processing: a value suppressed by cadence or superseded during processing cannot trigger live effects. Historical, superseded, ended-sensor and duplicate batches cannot act as new current readings. Neither kind of import establishes a phone BLE login.

All successful imports refresh history/displays and invoke the existing Nightscout, HealthKit and Dexcom Share managers, subject to their normal settings and cursors. Current imports additionally invoke the original alert/badge routine, speech, Bluetooth displays, calendar, contact image and OS-AID sharing. Missed-reading scheduling still uses the measurement timestamp. The existing Watch/widget refresh hooks remain in use; no new observer or timer is added.

When OS-AID sharing uses a delay, `prepareDelayedSharing` rebuilds the host manager's bounded buffer from the active sensor's visible stored readings after post-processing. It uses the existing `loopShareValue`, slope methods, 60-reading limit, cursor lookback and recent-calibration exclusion. The host's `LoopManager.share` still owns permission checks, delay and app-group writes. Immediate sharing continues to fetch from the database normally. No code in Loop or Trio is modified.

New imports use the phone’s existing 30-second backfill-delay threshold. A value can be backfilled yet still recent enough for the normal alert window. Exporters retain their settings, schedules, cadence and timestamp cursors. This adapter does not rewind cursors to recover arbitrary old imports; the host's existing post-processing may still rewrite its normal recent tail. Data older than an already-advanced exporter cursor retains the host's backfill limitation. No second uploader or network timer is introduced.

Unmatched sensor readings receive a separate `Libre2HistoryRejection`, bound to the immutable batch ID and the affected reading IDs. No rows from a mixed batch are imported until all its mappings resolve. The Watch persists rejected readings in the journal's `unresolved` collection, removes only those readings from `pending`, then retries the valid remainder under a new batch ID. Duplicate or late responses cannot resolve a newer batch. Interactive and queued responses use the existing WatchConnectivity route.

Unresolved readings survive restart and NFC recovery; they are retained locally and not automatically retried or reassigned. Transport, registry-file and database-save errors do not classify readings as unresolved: the original batch remains available for retry. Existing journals decode with an empty unresolved collection, preserving any previously blocked batch. Both phone and Watch need this update for the new rejection response; an older Watch receives an ordinary error and keeps its data.

The durable outbox is retained until acknowledged. Large unacknowledged histories still require whole-file writes; this is a known profiling/optimization candidate, not a reason to discard measurements during this refactor.

`Libre2HistoryCleanupRequest` uses the existing interactive Watch message route, entirely inside the add-on. The experimental page requests a count only when **Delete unresolved readings** is tapped, then asks for confirmation. `Libre2HistoryQueue` binds that count to an in-memory revision; new unresolved readings, deletion or a Watch restart invalidate it. A confirmed deletion clears only `unresolved` and saves before replying. It does not reset the pending batch, collection-minute deduplication, ownership or counters. Cleanup is never sent through queued background transfers or retried automatically; after a lost reply, another tap reads the remaining count. No additional polling, host delegate hook or journal migration is needed.

## Phone connection checklist

There is no manual verification/reconnect action on the experimental page. The automatic handoff prerequisite remains: an acknowledged phone unlock write followed by a recent native BLE reading with the current credentials. If a restored stream cannot satisfy it, the checklist directs the user to Stop Scanning/Disconnect on the ordinary sensor page, then Connect and an NFC scan. No new scan path, dialog or ownership transition is introduced.

## Compatibility and upstream integration

File moves and Swift type renames do not change journal locations, preference keys, session fields, message keys or reading IDs. Existing completed handoffs and queued uploads remain readable. The `reclaim` field and `Libre2ReclaimState` are retained solely as compatible NFC credential storage. Legacy `reclaimingPhone`/`verifyingPhone` records now direct the user to ordinary NFC recovery; they cannot silently resume the removed recovery workflow.

To integrate into master, port the shared models/store and Watch collector first, then attach the existing transport policy and confirmed disconnect callback, then the two WatchConnectivity adapters. Add history import and the Advanced Settings view last. The [audit](AUDIT.md) lists every original-file hook. Keep the original crypto fixture and switching/restart tests while replacing the duplicated Watch protocol port with shared upstream utilities if desired. Do not globally remove the iPhone's CoreNFC guards as part of this add-on refactor.

## Optional background location

The preference defaults to off and is saved on the Watch, independently of sensor credentials. The phone reads it on experimental-page entry, foreground return and Watch reachability changes while the page is visible. Changes use interactive messages with acknowledgement; there is no queued location command, periodic refresh or optimistic claim that an unreachable Watch has stopped. An unconfirmed reply requires reopening the page with both apps available.

The Watch manager owns one location helper and passes it settings messages before the existing handoff/history routes. The helper observes existing ownership notifications and WatchKit’s did-become-active notification. It creates `CLLocationManager` only when enabled, ownership is `.watch`, and the app is active. Permission prompts are therefore confined to explicit use of this experiment. An existing session continues after backgrounding and through BLE range loss. Disable, return initiation, reset/revocation or other loss of `.watch` ownership stops location; the preference itself remains saved for the next handoff. A background launch waits until the app becomes active to start a new session.

The starting configuration is standard updates, 100-metre desired accuracy, no distance filter, `.other` activity and `allowsBackgroundLocationUpdates`. Desired accuracy is not an update interval or an energy guarantee. No route, coordinates or audio are stored. Bounded diagnostics record status changes rather than every location callback, and the phone labels its response as the status at the last check. The helper cannot modify ownership, counters or the collector. Permission failure affects only location support.

Outside the add-on, only the Watch’s `location` background mode/When In Use usage description and Xcode source membership are required. No new host lifecycle hook, NFC edit, HealthKit session, entitlement or display timer was added. To remove this experiment, remove the helper/property/message dispatch, location settings view/row, request type/preference/strings and those plist/membership entries.

This implementation has no fixed one-hour timer. It also makes no guarantee of sustained execution, GPS availability, glucose delivery or crash relaunch. Location services can consume additional battery. Device testing must establish stationary/background delivery and reconnect behavior before treating it as continuous monitoring. [Apple background-location guidance](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background).


## Watch display settings after restart

The existing Watch initialization and status hooks call `restoreDirectLibrePreferences` and `receiveDirectLibrePreferences`. The add-on persists all four explicit phone glucose limits in mg/dL alongside the existing unit preference. A valid saved set takes precedence over the complication cache; existing installations can migrate cached settings. Restore occurs before collector startup, so a first direct reading cannot overwrite the complication with startup defaults.

Fresh, complete phone limits can update during direct collection without importing phone sensor status or glucose. A limits-only change returns through the host's existing complication refresh path. Duplicate settings do not request an extra refresh; malformed/partial or expired payloads do not overwrite saved limits. Ordinary relay retains its original status assignments. No new message, timer, background-session hook or Watch alarm is added.


## Location accuracy selection

The existing experimental location settings view uses a three-segment control for `Libre2LocationRequest.Accuracy` (100, 1000 or 3000 metres). It sends one interactive `setAccuracy` request per selection and highlights only the acknowledged setting. Existing replies gain an `accuracy` field; older Watch replies still support the toggle but show an update notice instead of an unsupported accuracy control. Failed replies leave the controls unconfirmed/disabled until another inspection.

The Watch preference defaults to 100 metres and is independent of the background opt-in, sensor session, units and glucose limits. `Libre2WatchLocationSession.refresh` applies the saved `desiredAccuracy` to an existing location manager before the already-running check, so changes take effect without stopping location or BLE. Existing foreground-start and ownership guards still apply. No change to the distance filter, polling, capabilities or host hooks is needed.

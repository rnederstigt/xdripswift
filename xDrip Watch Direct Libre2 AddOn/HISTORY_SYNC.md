# Direct Watch readings → iPhone history

History synchronisation is automatic for newly collected Direct Libre measurements. Install
matching iPhone and Watch builds. Use the existing switch button under **Settings → Advanced
Settings → Direct Libre (Experimental)**. No additional switch or upload button is needed.

The Watch keeps its existing display and graph behavior. Once the phone can receive an upload,
the readings are saved in its normal glucose database and its chart, statistics, widgets and
Watch relay are refreshed through the existing app paths. **Recent activity** on the phone
records successful imports and errors. Uploads can finish while Watch is selected or after
returning to iPhone, including after an NFC reclaim.

For a predictable first test, open both apps when the phone is available again. WatchConnectivity
also provides queued delivery, but its timing is controlled by the OS. This change does not add
a Watch background execution mode or make glucose collection continuous. It does not add Watch
alarms or invoke the phone's new-reading alarm processing for a historical import.

## Data flow

1. Before sending PREPARE, the phone saves the active database sensor and records the handoff
   ID → database sensor ID mapping. The mapping contains no unlock credentials.
2. After an authenticated, valid BLE frame, the Watch copies its **newest actual measurement**
   into an atomic, synchronised file before passing readings to the existing display path.
   The saved value is native-converted mg/dL, before the Watch display's 600 mg/dL cap.
3. An outbox batch contains at most 120 readings. It is persisted with an immutable batch UUID
   before sending. Each reading carries the original handoff UUID, sensor UID, sensor minute,
   timestamp and converted glucose. No unlock code, counter or calibration credentials are sent
   in history messages.
4. A reachable phone gets an interactive message. Otherwise, or after an interactive delivery
   error, the Watch queues a WatchConnectivity user-info transfer. Retries reuse the saved batch.
5. The phone validates the message and resolves every reading to its original database sensor,
   even if that sensor has since ended. Unknown identities are rejected, with no acknowledgement.
   The importer never assigns an unknown upload to the currently active sensor.
6. The phone inserts missing readings, saves the child context, saves the main context, then
   waits for the private persistent-store context to save. **Only then** does it acknowledge
   the exact batch UUID and reading IDs. A transport-delivery callback is not an acknowledgement.
7. The Watch durably removes only those acknowledged readings and sends the next batch. A
   failed save, lost reply, duplicate transfer or stale acknowledgement leaves pending data intact.

## Identity and duplicate policy

- Reading IDs use `direct-libre-watch:<sensor UID hex>:<sensor minute>`. Reconnection or a second
  handoff does not create another copy of the same measurement.
- The Watch records the highest collected minute for each sensor, including after acknowledgement,
  so repeatedly receiving an old frame cannot recreate an already uploaded reading.
- Phone inserts also check deterministic IDs. At a switch boundary an existing, valid phone
  reading from the same database sensor within 30 seconds takes precedence. Distinct Watch
  minutes are not discarded merely because their arrival timestamps are close together.
- Imports preserve measurement times and converted values, mark `backfilledAt`, leave calibration
  unset, and hide an unknown slope. They do not apply a second calibration or rewrite existing rows.
- The separate registration journal survives return, reclaim and later sensor replacement.
  Upgrading an already active prototype session is supported only when its saved identity matches
  the phone's Libre UID and the active database sensor predates the handoff.
- Clock skew greater than five minutes into the future, invalid glucose, malformed batches and
  unknown session/sensor mappings are rejected. Readings stay pending for retry; errors appear in
  the activity journal. Keep both devices' clocks correct.

## Storage and retry behavior

Files are in each app's private Application Support `PhoneControlledLibre` directory:

| File | Device | Purpose |
| --- | --- | --- |
| `watch-history.json` | Watch | Unacknowledged measurements, immutable outgoing batch and per-sensor collected-minute markers. |
| `phone-history-sensors.json` | iPhone | Historical handoff → sensor mappings. |

Ownership remains in its original `ownership.json`, with its existing schema and counter rules.
History synchronization never enables Bluetooth, changes ownership or verifies a phone BLE login.
It does not affect ordinary NFC provisioning.

The outbox retains **all unacknowledged readings**; it has no age-based deletion policy. Storage
therefore grows while uploads remain blocked. Once acknowledged, readings are removed from the
outbox and remain in the phone's normal database. A malformed journal is reported and preserved,
not silently replaced. Deleting either app's data can still remove its local journals.

Transfers are triggered by new collected readings, WCSession activation/reachability events and
the Watch app becoming active. There is no new polling timer or hook into the two-second display
refresh. An outstanding queued transfer is not requeued. Repeated attempts for the same batch
are limited to once per minute during collection; reopening the Watch app permits a retry.
Opening the phone's experimental page does not itself request a history upload.

Queued transfers use the existing WCSession delegates. Background delivery and processing depend
on the apps being allowed to run; reopening both apps is the recovery path. This milestone adds
no background-task handler, extended-runtime session or restricted entitlement. See Apple's
[WCSession documentation](https://developer.apple.com/documentation/watchconnectivity/wcsession)
and [WatchConnectivity background-task documentation](https://developer.apple.com/documentation/watchkit/wkwatchconnectivityrefreshbackgroundtask).

## Scope and limitations

- Only measurements collected **after installing this version** are journalled. An existing
  in-memory Watch graph is not retrospectively imported.
- One newest valid measurement per sensor minute is stored. Sparse older points carried by a BLE
  frame, parser interpolation and relayed phone readings are not uploaded. A gap while the Watch
  was not collecting is not filled by this feature.
- No continuous Watch monitoring, workout mode or new alarm system is included.
- Normal app export behavior is retained. This is not a separate delayed-history backfill
  implementation for Nightscout, HealthKit or other downstream services.
- Replacing/deleting a database sensor or erasing registration data can prevent its old uploads
  from being matched. They remain pending instead of being silently attached to another sensor.
- Source/host checks cannot establish radio delivery, battery cost or hardware reliability.

## Device acceptance test

1. Install both companions and confirm ordinary phone NFC and BLE readings still work.
2. Switch to Watch and collect several readings with the phone available. Check the phone chart
   and **Recent activity** for saved Direct Watch readings.
3. Move the Watch out of phone range, continue collecting, and note the Watch times/values.
4. Reopen both apps in range. Confirm those minutes appear on the phone once each, at their
   original times. Keep both open until the backlog is imported.
5. Repeat, returning to phone before the upload completes. Check that the phone's new live data
   and the earlier Watch history coexist without duplicate points around the switch.
6. Repeat with Watch app termination/relaunch before uploading, and with interrupted connectivity
   during an upload. Pending readings must survive and repeated delivery must not duplicate rows.
7. Repeat the return test using explicit NFC reclaim. Uploads must not reconnect Watch Bluetooth
   or make the phone checklist's BLE verification pass without a real phone reading.
8. Confirm that a delayed upload from an ended sensor stays associated with that sensor when a
   replacement sensor exists. Unknown mappings should log an error and retain Watch data.

`Tests/Libre2HistoryTests.swift` runs in the host Swift package. Hosted iPhone tests in
`Tests/Libre2PhoneHistorySyncTests.swift` use the actual Core Data model to cover duplicate imports,
durable-save acknowledgement, save failure/retry, ended sensors and phone/Watch overlap. The
hosted tests belong to `xdripTests` and require an available iPhone simulator or device.

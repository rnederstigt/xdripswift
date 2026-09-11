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
| `Watch/BluetoothTransmitter/Libre2WatchCollector.swift` | CoreBluetooth lifecycle, reconnect, authentication and frame processing. |
| `Watch/DataModels/WatchStateModel+DirectLibre.swift` | Applies direct readings and units to the original display/complication fields. |
| `Shared/Managers/Libre2SessionStore.swift` | Locked journal and explicit ownership/counter transitions. |
| `Shared/DataModels/Libre2Ownership.swift`, `Libre2WatchSession.swift`, `Libre2HandoffMessage.swift` | Persisted state and wire format. |
| `Shared/Protocol/Libre2Core.swift`, `Libre2Crypto.swift` | Watch BLE protocol port. The original iPhone NFC, crypto and parser remain in place. Source attribution is retained. |
| `Shared/Managers/Libre2ReadingPipeline.swift` | Direct display history merge, trend and validation. |
| `Shared/Managers/Libre2WatchPreferences.swift` | Last explicit unit preference and complication-cache migration. |
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

## Ordinary NFC recovery

With no experimental state, the NFC reader uses its original code (42), commands, callbacks, notices and retry behaviour. The add-on only marks the in-progress scan so a simultaneous handoff cannot begin. No experimental journal write is required.

After Direct Libre use, an ordinary scan retires the old session, persists a new streaming code, and queues a session-bound Watch revocation. NFC must confirm provisioning and the old phone BLE connection must close before phone reconnection is allowed. A failed/cancelled/interrupted reset remains recoverable through another ordinary scan, including for a different/new sensor. Only reset scans clear the original NFC-reader reference to permit a retry on the same transmitter instance.

`LibreNFC` has one optional unlock-code argument. It has no Direct Libre types, expected-sensor restriction or second recovery reader. Experimental reset errors appear in Advanced Settings and its log, not in a global sensor alert.

## History synchronization

`Watch/Managers/Libre2WatchHistorySync` saves the newest real sample from each frame before display. `Libre2HistoryQueue` keeps an immutable outgoing batch until the phone acknowledges its IDs. It sends immediately when reachable or uses WatchConnectivity's queued delivery; events drive retry, without a periodic synchronization timer. Batches contain at most 120 readings and no unlock credentials. Display-interpolated points are not uploaded.

`iPhone/Managers/Libre2PhoneHistorySync` maps each handoff to its original Core Data sensor via `Libre2HistoryRegistry`. It rejects unknown/deleted sensors rather than guessing the active sensor. Deterministic reading IDs and switch-boundary overlap checks prevent duplicates. Saving the child, main and persistent-store contexts precedes acknowledgement. Imports refresh charts/widgets through one root-coordinator hook without invoking new-reading alarms or treating imported readings as evidence of a phone BLE login.

The durable outbox is retained until acknowledged. Large unacknowledged histories still require whole-file writes; this is a known profiling/optimization candidate, not a reason to discard measurements during this refactor.

## Compatibility and upstream integration

File moves and Swift type renames do not change journal locations, preference keys, session fields, message keys or reading IDs. Existing completed handoffs and queued uploads remain readable. The `reclaim` field and `Libre2ReclaimState` are retained solely as compatible NFC credential storage. Legacy `reclaimingPhone`/`verifyingPhone` records now direct the user to ordinary NFC recovery; they cannot silently resume the removed recovery workflow.

To integrate into master, port the shared models/store and Watch collector first, then attach the existing transport policy and confirmed disconnect callback, then the two WatchConnectivity adapters. Add history import and the Advanced Settings view last. The [audit](AUDIT.md) lists every original-file hook. Keep the original crypto fixture and switching/restart tests while replacing the duplicated Watch protocol port with shared upstream utilities if desired. Do not globally remove the iPhone's CoreNFC guards as part of this add-on refactor.

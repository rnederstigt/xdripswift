# Ordinary NFC reset after sensor deletion

The Direct Libre journal survives deletion of an ordinary xDrip sensor. Previously its saved Watch/unresolved owner blocked the ordinary NFC entry, leaving a replacement sensor unable to connect. An ordinary user-requested Libre scan now supersedes that experimental state.

## User workflow

1. Install matching updated iPhone and Watch builds. The phone's recovery scan does not require the Watch to be reachable.
2. Use the ordinary Libre sensor Add/Connect scan and scan the sensor you want to use. The deleted sensor is not required. Keep phone Bluetooth enabled.
3. NFC provisions the scanned sensor; the phone closes its previous BLE connection and starts connecting with the fresh credentials. Confirm a new phone BLE reading. NFC success alone does not establish that glucose is arriving.
4. If the NFC sheet is cancelled or fails, start the ordinary scan again. After an app interruption, reopen and scan again. No return acknowledgement from the old Watch session is required.
5. Use Advanced Settings to switch to Watch again only after the phone checklist verifies the new connection.

The separate **Reclaim via NFC** button has been removed. Ordinary Add/Connect scanning covers both the current sensor and a replacement. Saved recovery records from older builds remain supported.

## Reset ordering

- With no experimental state, ordinary NFC sends the upstream default unlock code and does not write the Direct Libre journal or overwrite the stored unlock-code preference. It also retains the original NFC reader lifetime and retry behavior; this add-on does not fix the previously observed ordinary-scan reconnect gap.
- With saved or unresolved experimental state, persist retirement of the old handoff ID, clear its credentials/reclaim attempt, and save a fresh streaming code before opening NFC. Phone BLE remains disabled while the reset is pending.
- The ordinary reader receives that code without an expected-UID restriction. Its existing provisioning command and parser are unchanged.
- After NFC confirms streaming, reset the phone counter to zero. Only the confirmed phone-disconnect callback may finish the reset and enable BLE. The next existing phone login reserves counter one. Buffered old-connection BLE frames are ignored during reset.
- Persist the newly scanned UID and credentials using the existing phone recovery record. Subsequent scans replace those credentials again; they must not fall back to a code held by a retired Watch session.
- Only a scan started as a Direct Libre reset clears its NFC reader reference on completion, allowing a retry on the same transmitter. The reset marker is captured before scan cleanup so cancelled reset scans remain retryable.
- Cancellation, restart or persistence failure does not grant BLE ownership with the old credentials. Another ordinary scan can replace a pending reset. A currently active NFC attempt still excludes simultaneous NFC/handoff operations.
- Queue an old-session revoke if WatchConnectivity is activated. The updated Watch handles queued revocation even if it overtakes PREPARE, and a delayed revoke cannot stop a newer session. Phone callbacks for retired handoffs cannot restore old credentials or ownership.

An unreachable Watch cannot be stopped immediately. Queued revocation depends on later WatchConnectivity delivery; whether NFC reprovisioning immediately displaces an already authenticated Watch connection requires physical-sensor validation. Scanning a replacement sensor does not physically disconnect the Watch from the old sensor.

## Focused validation

Seven new host regressions cover all saved owner states, missing old sensor state, fresh-code selection, NFC/disconnect ordering, cancellation and restart, stale completion rejection, persistence failure, and queued revocation overtaking a handoff. Existing tests also check late revocation against a newer Watch session and ordinary NFC independence from the experimental journal.

The counter-exhaustion safeguard remains enabled. Recent activity records the counter at NFC start, its reset on successful provisioning, and reasons for withheld unlocks. These targeted diagnostics run even when routine experimental logging is dormant; they do not include sensor UID or unlock-code values.

Device checks still required:

- Delete the phone sensor during Direct Watch mode; make Watch unreachable; add a replacement through ordinary NFC and verify fresh phone BLE data.
- Repeat with an unresolved outbound switch/return, and after restarting the phone app.
- Cancel or fail the reset scan, then retry on the same Add/Connect screen.
- Scan the same physical sensor while Watch is unreachable; verify actual BLE takeover separately from NFC confirmation.
- Reopen Watch in range and verify the retired session stops. Start a new handoff, then deliver/retry an old revoke and verify the new session remains active.

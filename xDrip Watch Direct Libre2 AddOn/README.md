# Direct Libre 2 for Apple Watch

An experimental xDrip4iOS add-on that lets Apple Watch receive Libre 2 glucose readings directly over Bluetooth. The iPhone controls switching between devices; the Watch displays readings and saves them for synchronisation back to the phone.

The add-on reuses the existing Watch graph and complications. Imported readings use the phone's existing processing and configured uploads; newly current readings also trigger its normal alerts and sharing. Most implementation lives in this directory, with documented hooks into the original app.

## Getting started

1. Build and install matching iPhone and Watch apps using the repository's [installation instructions](https://xdrip4ios.readthedocs.io/en/latest/install/install/). Open both apps once to synchronise units and glucose limits. Sensor provisioning remains on iPhone.
2. Establish a working native Libre 2 BLE connection in xDrip on iPhone. Any transfer from another app to xDrip happens beforehand, outside this feature.
3. Open **Settings → Advanced Settings → Direct Libre (Experimental)** on iPhone. The summary shows the selected collector and one switching button. Expand **Connection checklist** to inspect companion availability, sensor settings and the recent authenticated phone reading; missing requirements open it automatically.
4. Tap **Connect to Watch**, keeping both apps open until the connection completes. The antenna beside the reading age turns green when Bluetooth connects; the first glucose value may arrive later.
5. Use the same phone button to return to iPhone or cancel an unfinished switch. The Watch has no separate ownership controls.

## Reading and connection status

The phone summary distinguishes companion reachability from the Watch’s sensor connection, which is shown on the Watch itself. **Latest on iPhone** is an absolute measurement timestamp: in Watch mode it uses the existing phone widget snapshot, which can lag behind the Watch. It does not request data or claim the Watch is currently connected.

**Green antenna means connected; grey means disconnected.** Reading age separately indicates freshness. A green antenna does not prove that readings are current or background collection is working.

The Watch requests reconnection after connection loss. Double tap the large value or chart-page header to retry an idle collector, or reconnect a connected session with no fresh reading for three minutes. Before the first reading, this interval starts at connection. An active scan, pending connection or fresh connection is left alone. Outside direct mode, double tapping retains its original phone-refresh action.

Each new Watch reading updates a background context independently of historical synchronisation; newer values replace pending older context. When reachable, the Watch also sends the newest reading immediately. The phone can therefore import the current value while older graph gaps are still filling, although Apple schedules background context delivery and provides no fixed delivery time. All real readings remain queued on the Watch until historical delivery confirms storage in the original sensor record; repeated deliveries are deduplicated. Identical copies arriving during a phone import share its save, while each history batch receives its own acknowledgement. A submitted background history batch is not sent again for five minutes, including after a Watch restart. If acknowledgement is still missing, the next collection or activation/reachability event may retry it once no transfer is outstanding. This reduces duplicate transfers; it does not guarantee faster system delivery.

Historical imports update history and configured uploads without triggering current-reading effects. Exporters retain their existing schedules and backfill limits. The phone must receive fresh readings to refresh missed-reading alarms; an unreachable Watch cannot suppress them. Delivery timing still depends on background execution and WatchConnectivity. Units and the last received glucose limits survive Watch restarts.

## Optional background collection

With both apps open, enable **Use location for background collection** in the **Background collection** section. Once the Watch owns the sensor, open xDrip there and grant location permission. The option defaults to off and saves no coordinates.

While enabled, choose **100 m / 1 km / 3 km** requested location accuracy; 100 m is the default. The acknowledged selection persists and can change during collection without restarting Bluetooth. Coarser accuracy may reduce battery use but does not specify an update interval or guarantee savings.

Location support continues through temporary BLE loss and stops when disabled or ownership leaves the Watch. After a new app launch, starting location requires opening xDrip. Information buttons explain background limitations, accuracy and the notification test. The phone shows the last reported location status; reopen the page to refresh it. Verify background collection from advancing measurement timestamps, rather than the antenna or a single location callback.

### If Watch readings update but the phone lags

Background **collection** and **delivery to the phone** are separate. The Watch can keep receiving glucose and updating its complication while live WatchConnectivity messaging remains unavailable. In that state, phone updates depend on system-scheduled background delivery and may be several minutes behind.

**Test Watch notification** is a manual way to try to restore immediate phone updates without waiting for a missed-readings alarm. In the recorded device test, presentation of this notification on the Watch was followed almost immediately by restored live reachability. The next six readings reached the phone in roughly 0.1–0.4 seconds each while both apps remained backgrounded. Delivery continued after the notification closed; tapping or dismissing it was not needed to initiate delivery. A notification appearing only on the phone did not reproduce the same sustained recovery in earlier tests.

To try it after switching collection to the Watch:

1. Open both apps. On the phone's experimental page, tap **Background collection → Test Watch notification** and allow Watch notification alerts if asked.
2. Wait for scheduling confirmation, then return to the watch face and lock the phone within 30 seconds.
3. Let the test notification appear on the Watch without opening either app. Compare subsequent measurement timestamps on the Watch complication and phone Live Activity for at least five minutes after it closes. If needed, inspect the phone's stored readings afterwards; opening an app during the test can itself restore communication.

The button schedules one Watch-local notification, not a glucose alarm. Repeated presses replace the pending test. **Detailed diagnostics** is optional for using it; enable it beforehand under **Diagnostics & recovery** if you want to export evidence afterwards.

This is an observed workaround, not a guaranteed background connection. The notification does not explicitly send readings or grant extra background permissions: when live reachability returns, the existing delivery path sends the latest available reading and subsequent readings. The underlying system behaviour and duration of the effect remain unconfirmed. Nothing schedules this notification automatically on handoff or repeats it in the background. Focus and notification settings can affect presentation, and scheduling confirmation alone does not prove improved delivery.

## Recovery

| Situation | Action |
| --- | --- |
| Checklist does not recognise an authenticated phone stream | Use **Stop Scanning/Disconnect**, then **Connect** and an ordinary NFC scan; wait for fresh BLE glucose. |
| Switching or returning is interrupted | Open both apps and retry/cancel from the phone page. |
| Return cannot complete or the old sensor was deleted | Use ordinary Libre **Add/Connect NFC** on iPhone. After Direct Libre use, this resets the phone session and provisions fresh credentials. Watch ownership clears after the retirement reaches it and Bluetooth disconnects; open both updated apps with Bluetooth enabled. Retired handoffs are resent on restored reachability and before another handoff. A failed/cancelled scan needs another attempt. |
| Readings belong to an unknown/deleted phone sensor | They remain unresolved on Watch. **Diagnostics & recovery → Delete unresolved readings** checks their count and asks for confirmation; pending uploads and phone history remain intact. |
| Watch units or limits are wrong after an update | Open both apps to receive current phone settings. Previously overwritten settings cannot be recovered offline. |

The main page shows three recent phone events, with **Show more**. **Diagnostics & recovery** contains the full activity log, Watch log loading/export, detailed logging, unresolved-reading cleanup and NFC recovery guidance. The full journal retains up to 240 entries per device and initially shows five. Normal logging records connection changes, saves and errors. **Detailed diagnostics** defaults to off; enable it there with the Watch reachable before reproducing a problem. The Watch confirms the setting before the phone applies it, and both devices remember it across restarts. Turn it off after testing to reduce logging.

For a delivery delay, reproduce it with both apps backgrounded, then open xDrip on the Watch. Tap **Load Watch activity**, then **Share** in **Diagnostics & recovery**. Loading is manual and does not enable tracing. Detailed delivery entries include reachability, transfer and import timing; complication traces also include glucose values. The Watch export keeps the newest records that fit its 60 KB limit, so export promptly. Reachability is required to change tracing or load the Watch log.

For delivery which begins with the missed-readings alert, enable **Detailed diagnostics** before the handoff, leave both apps backgrounded and leave the alert untouched. Note when it appears and when phone readings resume, then export promptly. `Lifecycle` entries identify app/process changes, the custom Watch notification callback, phone notification actions and WatchConnectivity background-task start/completion. They observe these events without requesting a connection or extra runtime.

For the manual notification test above, enable **Detailed diagnostics** before reproducing the delay and export afterwards. Compare the Watch notification event (`notificationTest=true`), restored reachability, latest-reading sends and phone imports. See [recorded evidence and device checks](Docs/TESTING.md) for the observed result and how to repeat it.

## Limits

This is a proof of concept: continuous background collection is not guaranteed. Watch alarms, sensor backfill, automatic Water Lock and depth measurement are not implemented. The retained underwater declaration affects frontmost behaviour; enable/disable Water Lock manually. Execution support cannot guarantee radio reception through water.

An unreachable Watch cannot be instantly disconnected by a phone command. NFC recovery reprovisions sensor credentials and may disrupt another app's pairing. Location support uses additional battery; reliability and consumption require device testing.

## For contributors

- [Architecture](Docs/ARCHITECTURE.md): diagrams, implementation entry points, original-file hooks, safeguards and integration guidance.
- [Testing](Docs/TESTING.md): reproducible checks, recorded evidence and device acceptance criteria.

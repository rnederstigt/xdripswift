# Direct Libre 2 for Apple Watch

An experimental xDrip4iOS add-on that lets Apple Watch receive Libre 2 glucose readings directly over Bluetooth. The iPhone controls switching between devices; the Watch displays readings and saves them for synchronisation back to the phone.

The add-on reuses the existing Watch graph and complications. Imported readings use the phone's existing processing and configured uploads; newly current readings also trigger its normal alerts and sharing. Most implementation lives in this directory, with documented hooks into the original app.

## Getting started

1. Build and install matching iPhone and Watch apps using the repository's [installation instructions](https://xdrip4ios.readthedocs.io/en/latest/install/install/). Open both apps once to synchronise units and glucose limits. Sensor provisioning remains on iPhone.
2. Establish a working native Libre 2 BLE connection in xDrip on iPhone. Any transfer from another app to xDrip happens beforehand, outside this feature.
3. Open **Settings → Advanced Settings → Direct Libre (Experimental)** on iPhone. The checklist checks companion availability, sensor settings and a recent authenticated phone reading.
4. Tap **Connect to Watch**, keeping both apps open until the connection completes. The antenna beside the reading age turns green when Bluetooth connects; the first glucose value may arrive later.
5. Use the same phone button to return to iPhone or cancel an unfinished switch. The Watch has no separate ownership controls.

## Reading and connection status

**Green antenna means connected; grey means disconnected.** Reading age separately indicates freshness. A green antenna does not prove that readings are current or background collection is working.

The Watch requests reconnection after connection loss. Double tap the large value or chart-page header to retry an idle collector, or reconnect a connected session with no fresh reading for three minutes. Before the first reading, this interval starts at connection. An active scan, pending connection or fresh connection is left alone. Outside direct mode, double tapping retains its original phone-refresh action.

Real Watch readings remain queued until the phone acknowledges saving them to the original sensor record. Historical imports update history and configured uploads without triggering current-reading effects. Exporters retain their existing schedules and backfill limits. The phone must receive fresh readings to refresh missed-reading alarms; an unreachable Watch cannot suppress them. Units and the last received glucose limits survive Watch restarts.

## Optional background collection

With both apps open, enable **Background collection using location — Experimental** on the phone page. Once the Watch owns the sensor, open xDrip there and grant location permission. The option defaults to off and saves no coordinates.

Choose **100 m / 1 km / 3 km** requested location accuracy; 100 m is the default. The acknowledged selection persists and can change during collection without restarting Bluetooth. Coarser accuracy may reduce battery use but does not specify an update interval or guarantee savings.

Location support continues through temporary BLE loss and stops when disabled or ownership leaves the Watch. After a new app launch, starting location requires opening xDrip. The phone shows the last reported location status; reopen the page to refresh it. Verify background collection from advancing measurement timestamps, rather than the antenna or a single location callback.

## Recovery

| Situation | Action |
| --- | --- |
| Checklist does not recognise an authenticated phone stream | Use **Stop Scanning/Disconnect**, then **Connect** and an ordinary NFC scan; wait for fresh BLE glucose. |
| Switching or returning is interrupted | Open both apps and retry/cancel from the phone page. |
| Return cannot complete or the old sensor was deleted | Use ordinary Libre **Add/Connect NFC** on iPhone. After Direct Libre use, this resets the session and provisions fresh credentials. A failed/cancelled scan needs another attempt. |
| Readings belong to an unknown/deleted phone sensor | They remain unresolved on Watch. **Delete unresolved readings** checks their count and asks for confirmation; pending uploads and phone history remain intact. |
| Watch units or limits are wrong after an update | Open both apps to receive current phone settings. Previously overwritten settings cannot be recovered offline. |

Recent activity retains up to 80 entries, initially showing five with **Show more**. Watch reachability is required to confirm settings or delete unresolved readings.

## Limits

This is a proof of concept: continuous background collection is not guaranteed. Watch alarms, sensor backfill, automatic Water Lock and depth measurement are not implemented. The retained underwater declaration affects frontmost behaviour; enable/disable Water Lock manually. Execution support cannot guarantee radio reception through water.

An unreachable Watch cannot be instantly disconnected by a phone command. NFC recovery reprovisions sensor credentials and may disrupt another app's pairing. Location support uses additional battery; reliability and consumption require device testing.

## For contributors

- [Architecture](Docs/ARCHITECTURE.md): diagrams, implementation entry points, original-file hooks, safeguards and integration guidance.
- [Testing](Docs/TESTING.md): reproducible checks, recorded evidence and device acceptance criteria.

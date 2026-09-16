# Direct Libre 2 Watch add-on

A phone-controlled prototype for moving an already working Libre 2 Bluetooth connection between xDrip on iPhone and its Apple Watch companion. Start with xDrip receiving fresh native Libre BLE readings. Loop is outside this implementation.

## Use

1. Build and install matching iPhone and Watch apps. Open both apps once to synchronize glucose units and all four glucose limits.
2. On iPhone, open **Settings → Advanced Settings → Direct Libre (Experimental)**. The checklist shows companion availability, sensor settings and a recent authenticated phone reading.
3. If the phone-login checklist stays unchecked, use **Stop Scanning/Disconnect**, then **Connect** and an NFC scan on the ordinary sensor page. Wait for fresh glucose before switching.
4. Tap **Connect to Watch**. Keep both apps open until the Watch's antenna beside the reading age turns green. Green means the Watch's Bluetooth link to the sensor is connected, even before the first glucose reading; grey means it is not connected. The reading age (or “Waiting…”) separately shows whether glucose is available and how old it is.
5. Use the same phone button to return to iPhone or cancel an unfinished switch. An interrupted return can be retried with both apps open.
6. If return cannot finish, use the ordinary Libre Add/Connect NFC scan. After Direct Libre use, this resets the experimental session and provisions fresh credentials for the scanned sensor. The old sensor and a reachable Watch are not prerequisites. A cancelled/failed reset requires another scan before phone BLE resumes.

Ownership controls and error messages stay on the Advanced Settings page. Recent activity shows five entries initially, with **Show more**, up to 80 retained entries. The Watch adds the reading-age antenna and reuses its existing double tap for connection recovery; it has no experiment control page.

After a connection loss, the Watch immediately requests reconnection using the saved sensor reference, with scanning when that reference is unavailable. CoreBluetooth can keep a known sensor's connection request pending while it is out of range. A scan-discovered connection has the phone's five-second connection timeout, cancelled as soon as Bluetooth connects. There is no timer that disconnects a connected sensor simply because its first glucose reading has not arrived.

In Direct Watch mode, double tap the large glucose number or the chart page header to retry an idle connection or restart a connected session with no fresh reading for three minutes. Before the first reading, that grace period starts when Bluetooth connects. Repeated taps leave an active scan, connection attempt or fresh connection alone. Outside Direct Watch mode, double tapping still requests the original iPhone update. Water Lock must be off to use the screen gesture.

New direct measurements are saved on Watch and acknowledged by the phone only after import into the original sensor's database record. Readings remain queued while delivery fails. Imported values receive stored trends and use the phone's existing optional post-processing and downstream managers. Fresh values refresh phone alerts/missed-reading scheduling, speech, configured displays and sharing; historical batches do not trigger those current-reading effects. Nightscout, HealthKit and Dexcom Share retain their own settings, cadence and upload cursors, including existing limits on older backfill. The phone must receive fresh readings; an unreachable Watch does not suppress phone missed-reading alarms. Units and the phone’s last received glucose limits survive Watch restarts; stored glucose remains in mg/dL and display uses the phone's last explicit preference.

After updating, open both apps to receive your current phone limits, including during Direct Watch mode. Future Watch restarts restore them before publishing direct readings to the complication. A previously overwritten cache cannot recover your custom limits until the phone sends them again. These are display limits; this does not add Watch alarms.

Readings for deleted or unrecognised phone sensors are retained separately on Watch so they cannot block other uploads. They are not automatically reassigned or retried. Update both companion apps for this recovery behaviour. If the phone-login checklist stays unchecked, use Stop Scanning/Disconnect and Connect with NFC on the ordinary sensor page, then wait for fresh glucose; the experimental page has no separate verification button.

To remove these retained readings, open both apps and tap **Delete unresolved readings** on the experimental phone page. It checks the Watch's count on demand; confirm **Delete** or choose **Cancel**. Only unresolved readings are removed. Pending uploads, iPhone history and the sensor connection are preserved. The Watch must be reachable, and both apps need this update. If the readings change or the Watch restarts before deletion, check the count again. No automatic expiry or background deletion is added.

## Optional background location

On the experimental phone page, enable **Background collection using location — Experimental** with both apps open. The setting is saved on the Watch and defaults to off. Once the Watch owns the sensor, open xDrip there and grant location permission. If you enable it during an existing direct connection, permission can be requested immediately while Watch xDrip is active.

Use the three **100 m / 1 km / 3 km** buttons under **Requested location accuracy** to choose the Watch's requested precision. The default remains **100 m**. The selected button reflects the Watch's acknowledged setting, which survives restarts and sensor changes. Changes apply to an active location session without restarting it or the sensor connection; you can also configure the accuracy while background mode is off. Update both apps to use this control. If the Watch cannot be reached, controls are disabled until the setting can be confirmed.

Coarser accuracy may reduce battery use but does not specify a polling interval or guarantee savings, especially when another app already requests precise positioning. The distance filter remains unchanged. Compare background reading continuity and battery use before relying on a coarser setting.

Location updates then continue when leaving the app, subject to watchOS scheduling. Coordinates are not saved or shared. Temporary BLE disconnections do not stop location, so the existing collector can reconnect. Disabling the option or returning ownership stops location; the saved preference remains available for the next handoff. A new session after a background launch waits until xDrip is opened.

The phone reads the setting/status when this page opens or the Watch becomes reachable while the page is visible; it does not poll. To refresh the reported status after granting permission, reopen the page. “Background location started; waiting for a location update” means updates have been requested; “Location updates received” means at least one callback arrived during this session. These are last-reported states, not a continuous execution check. The green antenna indicates only the sensor’s Bluetooth connection. Check that new measurement timestamps keep arriving on the phone while Watch xDrip remains off-screen to verify background collection. Both apps must be reachable to change or confirm the setting. This uses extra battery, requires device testing and does not guarantee continuous glucose delivery. See [location tests](Docs/TESTING.md#background-location-device-acceptance).

## Scope

By default this is an on-demand/foreground prototype, with optional experimental background-location support. It adds no workout, continuous monitoring guarantee, Watch alarms, sensor backfill or automatic Water Lock. The Watch retains the agreed `underwater-depth` declaration for Apple's documented 30-minute frontmost preparation period. Enable/disable Water Lock manually; longer operation and reception through water require device testing.

Ordinary NFC reset after Direct Libre use reprovisions streaming credentials and may disrupt another app's sensor connection. Phone control does not mean instantaneous disconnection of an unreachable Watch. See the integration guide for the distinction between software ownership and sensor provisioning.

## Read the implementation

- [Visual overview](Docs/OVERVIEW.md): architecture, change footprint and original-code boundaries, with linked switching and reading diagrams.
- [Integration map and protocol](Docs/INTEGRATION.md): start here to understand or port the feature into master.
- [Audit against master](Docs/AUDIT.md): every original-file change, removals and intentional behavioural exceptions.
- [Validation and device tests](Docs/TESTING.md): automated checks, build limitations and a concise testing workflow.

The add-on remains compiled into the existing app targets; it is not a plugin framework. `Shared` contains host-testable models, persistence and the Watch protocol port. `iPhone` and `Watch` contain their managers, Bluetooth adapters and views. Xcode groups match the on-disk hierarchy.

# Direct Libre 2 Watch add-on

A phone-controlled prototype for moving an already working Libre 2 Bluetooth connection between xDrip on iPhone and its Apple Watch companion. Start with xDrip receiving fresh native Libre BLE readings. Loop is outside this implementation.

## Use

1. Build and install matching iPhone and Watch apps. Open both apps once to synchronize glucose units.
2. On iPhone, open **Settings → Advanced Settings → Direct Libre (Experimental)**. The checklist shows companion availability, sensor settings and a recent authenticated phone reading.
3. If the phone-login checklist stays unchecked, use **Stop Scanning/Disconnect**, then **Connect** and an NFC scan on the ordinary sensor page. Wait for fresh glucose before switching.
4. Tap **Connect to Watch**. Keep both apps open until the Watch's antenna beside the reading age turns green. Green means the Watch's Bluetooth link to the sensor is connected, even before the first glucose reading; grey means it is not connected. The reading age (or “Waiting…”) separately shows whether glucose is available and how old it is.
5. Use the same phone button to return to iPhone or cancel an unfinished switch. An interrupted return can be retried with both apps open.
6. If return cannot finish, use the ordinary Libre Add/Connect NFC scan. After Direct Libre use, this resets the experimental session and provisions fresh credentials for the scanned sensor. The old sensor and a reachable Watch are not prerequisites. A cancelled/failed reset requires another scan before phone BLE resumes.

Ownership controls and error messages stay on the Advanced Settings page. Recent activity shows five entries initially, with **Show more**, up to 80 retained entries. The Watch adds the reading-age antenna and reuses its existing double tap for connection recovery; it has no experiment control page.

After a connection loss, the Watch immediately requests reconnection using the saved sensor reference, with scanning when that reference is unavailable. CoreBluetooth can keep a known sensor's connection request pending while it is out of range. A scan-discovered connection has the phone's five-second connection timeout, cancelled as soon as Bluetooth connects. There is no timer that disconnects a connected sensor simply because its first glucose reading has not arrived.

In Direct Watch mode, double tap the large glucose number or the chart page header to retry an idle connection or restart a connected session with no fresh reading for three minutes. Before the first reading, that grace period starts when Bluetooth connects. Repeated taps leave an active scan, connection attempt or fresh connection alone. Outside Direct Watch mode, double tapping still requests the original iPhone update. Water Lock must be off to use the screen gesture.

New direct measurements are saved on Watch and acknowledged by the phone only after import into its original sensor's database record. Readings remain queued while delivery fails. Units survive Watch app restarts. Internal glucose values remain in mg/dL; display uses the phone's last explicit preference.

Readings for deleted or unrecognised phone sensors are retained separately on Watch so they cannot block other uploads. They are not automatically reassigned or retried. Update both companion apps for this recovery behaviour. If the phone-login checklist stays unchecked, use Stop Scanning/Disconnect and Connect with NFC on the ordinary sensor page, then wait for fresh glucose; the experimental page has no separate verification button.

To remove these retained readings, open both apps and tap **Delete unresolved readings** on the experimental phone page. It checks the Watch's count on demand; confirm **Delete** or choose **Cancel**. Only unresolved readings are removed. Pending uploads, iPhone history and the sensor connection are preserved. The Watch must be reachable, and both apps need this update. If the readings change or the Watch restarts before deletion, check the count again. No automatic expiry or background deletion is added.

## Scope

This is an on-demand/foreground prototype. It adds no workout, continuous monitoring guarantee, Watch alarms, sensor backfill or automatic Water Lock. The Watch retains the agreed `underwater-depth` declaration for Apple's documented 30-minute frontmost preparation period. Enable/disable Water Lock manually; longer operation and reception through water require device testing.

Ordinary NFC reset after Direct Libre use reprovisions streaming credentials and may disrupt another app's sensor connection. Phone control does not mean instantaneous disconnection of an unreachable Watch. See the integration guide for the distinction between software ownership and sensor provisioning.

## Read the implementation

- [Integration map and protocol](Docs/INTEGRATION.md): start here to understand or port the feature into master.
- [Audit against master](Docs/AUDIT.md): every original-file change, removals and intentional behavioural exceptions.
- [Validation and device tests](Docs/TESTING.md): automated checks, build limitations and a concise testing workflow.

The add-on remains compiled into the existing app targets; it is not a plugin framework. `Shared` contains host-testable models, persistence and the Watch protocol port. `iPhone` and `Watch` contain their managers, Bluetooth adapters and views. Xcode groups match the on-disk hierarchy.

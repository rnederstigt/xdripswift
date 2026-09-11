# Direct Libre 2 Watch add-on

A phone-controlled prototype for moving an already working Libre 2 Bluetooth connection between xDrip on iPhone and its Apple Watch companion. Start with xDrip receiving fresh native Libre BLE readings. Loop is outside this implementation.

## Use

1. Build and install matching iPhone and Watch apps. Open both apps once to synchronize glucose units.
2. On iPhone, open **Settings → Advanced Settings → Direct Libre (Experimental)**. The checklist shows companion availability, sensor settings and a recent authenticated phone reading.
3. If glucose is arriving but the phone login has not been observed, use **Verify phone connection** in the checklist. This reconnects with existing credentials; it does not scan NFC.
4. Tap **Connect to Watch**. Keep both apps open until the Watch's antenna beside the reading age turns green. Grey means connecting, disconnected or stale.
5. Use the same phone button to return to iPhone or cancel an unfinished switch. An interrupted return can be retried with both apps open.
6. If return cannot finish, use the ordinary Libre Add/Connect NFC scan. After Direct Libre use, this resets the experimental session and provisions fresh credentials for the scanned sensor. The old sensor and a reachable Watch are not prerequisites. A cancelled/failed reset requires another scan before phone BLE resumes.

All experiment controls and error messages stay on the Advanced Settings page. Recent activity shows five entries initially, with **Show more**, up to 80 retained entries. The Watch adds only the reading-age antenna; it has no experiment control page.

New direct measurements are saved on Watch and acknowledged by the phone only after import into its original sensor's database record. Readings remain queued while delivery fails. Units survive Watch app restarts. Internal glucose values remain in mg/dL; display uses the phone's last explicit preference.

## Scope

This is an on-demand/foreground prototype. It adds no workout, continuous monitoring guarantee, Watch alarms, sensor backfill or automatic Water Lock. The Watch retains the agreed `underwater-depth` declaration for Apple's documented 30-minute frontmost preparation period. Enable/disable Water Lock manually; longer operation and reception through water require device testing.

Ordinary NFC reset after Direct Libre use reprovisions streaming credentials and may disrupt another app's sensor connection. Phone control does not mean instantaneous disconnection of an unreachable Watch. See the integration guide for the distinction between software ownership and sensor provisioning.

## Read the implementation

- [Integration map and protocol](Docs/INTEGRATION.md): start here to understand or port the feature into master.
- [Audit against master](Docs/AUDIT.md): every original-file change, removals and intentional behavioural exceptions.
- [Validation and device tests](Docs/TESTING.md): automated checks, build limitations and a concise testing workflow.

The add-on remains compiled into the existing app targets; it is not a plugin framework. `Shared` contains host-testable models, persistence and the Watch protocol port. `iPhone` and `Watch` contain their managers, Bluetooth adapters and views. Xcode groups match the on-disk hierarchy.

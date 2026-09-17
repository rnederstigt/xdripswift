# Direct Libre 2 for Apple Watch — experimental

A phone-controlled proof of concept for collecting native FreeStyle Libre 2 BLE readings on Apple Watch, displaying them through the existing Watch app, and synchronising them to xDrip on iPhone. Sensor provisioning and switching controls remain on iPhone.

## Use it

1. Build and install both companion apps. Use the same developer team and App Group across the iPhone, Watch and extensions, following the [upstream installation guide](https://xdrip4ios.readthedocs.io/en/latest/install/install/). Open both apps once to synchronise units and glucose limits.
2. Establish a working native Libre 2 BLE connection in xDrip on iPhone.
3. Open **Settings → Advanced Settings → Direct Libre (Experimental)**. The checklist requires the companion app to be available, native calibration, unlock payloads enabled, and a recent authenticated phone BLE reading.
4. Tap **Connect to Watch**, keeping both apps open until the switch completes. Use the same phone button to return or cancel an unfinished switch.

Beside the Watch reading age, the antenna is **blinking orange** while scanning/restarting, **steady orange** while connecting/waiting to retry, **green** when Bluetooth connects and **grey** when inactive/unavailable. Green may appear before the first reading; reading age indicates freshness. Blinking pauses while the app is inactive, dimmed or Reduce Motion is enabled. VoiceOver describes the state.

While the Watch owns collection, double tap the large value or chart header to restart its connection. Repeated taps during cancellation share one restart; counters and readings are retained. Prepared or returning sessions cannot be activated by tapping. Outside direct mode the gesture keeps its original phone-refresh behaviour.

## Phone synchronisation

The newest reading is sent independently of historical batches: background application context retains the latest value, and live messaging also sends it when reachable. Every collected reading remains in the Watch outbox until the phone acknowledges a durable save. Background history retries are limited to avoid duplicate transfers; the newest reading does not wait for them.

The phone deduplicates imports and reuses its existing processing, configured uploads and sharing. Only newly current readings trigger live effects and refresh missed-reading scheduling. Watch collection alone cannot prevent phone missed-reading alerts when delivery is delayed. **Latest on iPhone** shows the phone's stored value time; companion reachability does not confirm Watch sensor connectivity.

## Optional background collection

In **Background collection**, enable **Use location for background collection**. While the Watch owns the sensor, open xDrip there and grant location permission. The option defaults to off and saves no coordinates. Choose **100 m / 1 km / 3 km** requested accuracy; 100 m is the default. Coarser accuracy may reduce battery consumption but does not specify an update interval or guarantee savings.

Location stops when disabled or ownership leaves the Watch. After restarting the Watch app, open it to start location support. Continuous collection and prompt phone delivery remain subject to watchOS scheduling. Verify advancing measurement timestamps, not just an icon.

### When the Watch updates but the phone lags

**Test Watch notification** in the background section may restore immediate phone updates. Testing found sustained prompt delivery after a notification reached the Watch while both apps were backgrounded. The cause and reliability of this effect remain unconfirmed.

With both apps reachable, tap the button, return to the Watch face, background/lock the phone and leave the notification untouched. It schedules one Watch-local notification after 30 seconds; repeated presses replace the pending test. Compare subsequent measurement times on both devices without opening either app, since opening an app can itself restore communication.

The test is manual, separate from glucose alarms, and does not grant extra execution time or explicitly send readings. Notification settings may suppress presentation. It is a workaround, not a delivery guarantee.

## Recovery and activity

| Situation | Action |
| --- | --- |
| No authenticated phone stream | Use the ordinary Stop Scanning/Disconnect and Connect/NFC sequence, then wait for fresh BLE glucose. |
| Interrupted switch or return | Open both apps and retry/cancel from the phone page. |
| Return fails or old sensor was deleted | Use ordinary Libre Add/Connect NFC on iPhone. After Direct Libre use this provisions new credentials and retires the old handoff. The Watch stops when retirement reaches it; open both apps with Bluetooth enabled. Failed/cancelled scans can be retried. |
| Unknown/deleted sensor's readings | **Activity & recovery → Delete unresolved readings** removes only those readings after confirmation. Pending uploads and phone history remain. |
| Wrong units or limits | Open both apps to receive the current phone settings. |

The main page shows three recent phone events, expandable with **Show more**. **Activity & recovery** provides the basic log, **Load Watch activity**, export and unresolved-reading cleanup. Each device retains up to 240 connection, save and error events. Watch loading is manual and requires reachability; exports keep the newest entries within 60 KB. There is no detailed-tracing mode or complication-value log.

Install both current companion builds. Obsolete ownership phases, full-session revoke messages and history journals without `unresolved` are unsupported. An unsupported history journal is left intact and reports a storage error; NFC recovery does not migrate it.

## Limits

Watch alarms, sensor backfill, automatic Water Lock and depth measurement are not implemented. The underwater declaration supports frontmost use; enable/disable Water Lock manually. It cannot guarantee BLE reception through water. Location support adds battery use and does not guarantee uninterrupted execution.

An unreachable Watch cannot be instantly disconnected by a phone command. NFC reprovisioning can invalidate another app's sensor pairing. Sensor switching and background operation require physical-device testing.

## Development

The Direct Libre 2 add-on was implemented using OpenAI Codex, with requirements, direction and real-device testing provided by rnederstigt. The most recent model used is `gpt-6-astra` (recorded September 2026); this identifies the latest development model, not every model used throughout the project. The original xDrip4iOS app and reused protocol code retain their existing contributor attribution.

- [Architecture](Docs/ARCHITECTURE.md): reading order, transaction rules and original-file hooks.
- [Testing](Docs/TESTING.md): automated checks, current evidence and device acceptance.

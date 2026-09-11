# Minimal underwater foreground experiment

The Watch Info.plist declares `WKBackgroundModes = underwater-depth`. Apple documents that this declaration keeps an app frontmost for a 30-minute preparation period after launch, before any extended runtime session starts. This is the only underwater implementation retained in this prototype.

Water Lock is controlled manually. There is no automatic submersion detection, Motion & Fitness permission request, depth entitlement, app delegate hook or custom extended runtime session. The earlier controller, runtime policy and their tests have been removed. Existing Libre collection, reconnect logic, ownership, phone relay and history synchronization are unchanged.

The declaration applies app-wide, including ordinary phone-relay use. It is an intentional change to upstream return-to-clock behaviour, not a guarantee of indefinite foreground display or continuous background collection. The existing Watch Bluetooth background declaration remains unchanged.

## User workflow and device checks

1. Install the updated Watch companion and open xDrip. Check the reading age and connection indicator.
2. Enable Water Lock manually in the Watch’s Control Center and return to xDrip before entering the water.
3. Verify xDrip stays frontmost during the intended use, including wrist lowering and submersion. Water Lock prevents touch input; it does not improve Bluetooth reception through water.
4. Disable Water Lock with the Digital Crown when ready. xDrip does not automatically lock again.
5. Check behaviour after the documented 30-minute preparation period and when switching between xDrip and a workout app. This implementation does not extend that period or manage system-delivered underwater sessions. Automatic underwater launch and longer/deeper submersion behaviour are not supported promises of this prototype.

If reception is lost, the existing collector handles reconnection when watchOS permits the app to run and the sensor becomes reachable. No additional reconnect procedure or ownership transition is introduced by this configuration.

## Validation

Source membership and configuration checks passed, as did all 75 host tests (zero failures). Test products were removed afterward; the test log remains outside the repository. The Watch app entry and entitlements are restored to their state before the underwater implementation. The pending Watch-unit persistence fix is retained.

The earlier physical-device test used the version with a controller and shallow-depth entitlement. The minimal declaration-only build still needs the device checks above; that earlier result does not establish its behaviour. No full signed build or new physical submersion test has been performed for this simplification.

Reference: [Apple’s submersion implementation guide](https://developer.apple.com/documentation/coremotion/accessing-submersion-data).

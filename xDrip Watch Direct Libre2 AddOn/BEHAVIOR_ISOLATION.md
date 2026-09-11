# Behavior outside Direct Libre

This cleanup addresses the audit against upstream commit `53b3d6bf1b550c99b19c3d5d2c2f80dd226465d8` (7.0.0 build 4231). It does not diagnose or fix the sporadic NFC/reconnection issue.

## Preserved paths

- **Ordinary Watch relay:** the original `processBgReadingsFromDictionary` implementation is restored, with only an entry guard that rejects phone relay while Direct Libre owns the display. Its default values and one-hour timestamp rule are unchanged. The host payload dispatcher performs its original single complication refresh. Direct samples retain their separate validation and one explicit complication refresh.
- **Ordinary phone Libre reconnect:** extra receive-buffer resets run only with saved/unresolved experimental state. Original buffer timeout/error/release handling remains intact.
- **Ordinary NFC without experimental state:** the NFC command keeps its default code, the callback resets the counter as upstream did, and the add-on does not overwrite the unlock-code preference or persist a session journal. Its NFC reader lifetime/retry behavior remains upstream. No extra forced-disconnect barrier is added to this path.
- **Direct Libre reset:** a scan replacing experimental state retains fresh credentials, the disconnect barrier, counter persistence and retry cleanup. Saved return/recovery credentials continue to count as experimental state even when phone is selected.

## Work while the page is closed

The phone still tracks the most recent BLE reading/login in memory so the checklist can be accurate when opened. Checklist change notifications are suppressed when its page is not active. Normal Watch relay creates no experimental marker timer/lifecycle subscriptions; the direct marker alone subscribes to the existing Watch display clock.

Routine activity logging requires either a visible experiment page or saved experimental state. Clean phone-relay startup no longer publishes an experimental status update. Pending handoffs, recovery and history synchronization remain active after leaving the page, as required to finish earlier Direct Libre work.

## Explicit exceptions and diagnostics

The minimal underwater foreground declaration is app-wide. It adds no controller, depth entitlement or collector calls, but the documented 30-minute frontmost preparation period may also affect ordinary phone-relay launches. Water Lock is manual. See [UNDERWATER.md](UNDERWATER.md). This is an intentional screen-behaviour difference from upstream.

The Watch now persists the phone's last explicit glucose-unit preference and restores it before direct collection starts. Existing complication data provides a migration fallback. A fresh status message can update units during direct collection without accepting the phone's sensor status or readings; a missing unit field keeps the current choice. This intentionally also preserves units after a restart in ordinary relay mode. No new polling or connectivity requests are added.

The counter-exhaustion safeguard remains: a stored counter of 65,535 prevents another increment/unlock rather than overflowing. This is an accepted defensive difference from upstream.

A short-lived NFC-in-progress guard still excludes overlapping scan/handoff transactions. That coordination hook remains necessary for the add-on. The Advanced Settings entry, Bluetooth policy hooks and Watch capabilities also remain integration differences; this is not a claim of byte-for-byte upstream identity.

To investigate the sporadic reconnect issue, Recent activity now records:

- Counter at NFC start and whether the scan is a Direct Libre reset.
- Counter before and after a successful NFC reset.
- Rejected experimental NFC bookkeeping, including the unchanged counter.
- Unlock withholding due to exhaustion, counter-persistence rejection, paused phone ownership or Suppress Unlock Payload.

These targeted events may be recorded even when routine logging is dormant. They are event-driven, contain no sensor UID or unlock-code values, and remain subject to the existing bounded log/deduplication. They do not prove the sensor accepted a BLE login, add retries or change connection timing. Normal NFC success still requires confirmation of actual BLE readings during device testing.

## Validation

Run from the repository root:

```sh
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_integration.py"
python3 "xDrip Watch Direct Libre2 AddOn/Scripts/check_upstream_relay.py"
swift test --package-path "xDrip Watch Direct Libre2 AddOn" --scratch-path ../work/direct-libre-tests
```

The relay comparison compiles the actual upstream/current reading handlers, the unchanged payload dispatcher, the direct validator and display adapter with lightweight display/complication stubs. It checks seven ordinary-relay scenarios, equal stored values/dates and complication-call counts, rejection of phone relay in Direct mode, and one refresh for valid direct data while malformed direct data is rejected. It requires macOS/Xcode and the baseline commit locally, performs no fetch, and removes its temporary build products automatically.

Host tests additionally cover idle log suppression, visible-page/explicit-diagnostic logging, and preservation of returned credentials as experimental state. Device validation of the page lifecycle, NFC/reset/return behavior and widget rendering remains necessary. No battery improvement has been measured.

# xDrip4iOS

## Experimental Direct Libre 2 connection to Apple Watch

This branch adds a **phone-controlled, foreground proof of concept** for switching a Libre 2 Bluetooth connection between xDrip on iPhone and its companion Apple Watch app.

- All controls are in **Settings → Advanced Settings → Direct Libre (Experimental)** on iPhone.
- One button switches to Watch or back to iPhone. The page includes a readiness checklist, connection verification, explicit NFC reclaim and recent activity.
- In Direct Watch mode, an antenna before the reading age is green when connected with fresh direct glucose, or grey when waiting, disconnected or stale.
- Start with xDrip already receiving valid Libre BLE readings. Build matching iPhone and Watch apps from this branch and keep them open during testing.

See the **[setup, switching workflow, architecture and device test checklist](<xDrip Watch Direct Libre2 Connection AddOn/README.md>)** before trying the experiment. This is a foreground prototype: continuous background collection, Watch alarms and direct-reading upload/backfill to the phone are not implemented. NFC reclaim reprovisions sensor credentials and may disrupt other apps' connections or alarms.

Validation performed during development: **50 host tests passed**, plus iPhone and Watch SDK source checks. Full signed builds and the device acceptance sequence are not covered by those automated checks.

The upstream xDrip4iOS introduction follows below.

---

**[Online documentation: compatibility, installation, setup and troubleshooting](https://xdrip4ios.readthedocs.io/en/latest/)**

xDrip4iOS (`xdripswift`) is a community-developed, open-source iOS app for displaying and managing real-time continuous glucose monitor (CGM) data. It can connect directly to a compatible CGM in **Master** mode or retrieve remote readings from an online service in **Follower** mode.

xDrip4iOS is not related to the xDrip+ project for Android.

> [!IMPORTANT]
> xDrip4iOS is experimental software. It is not a regulated medical device and is not approved for making treatment decisions. Never rely on it as the only source of glucose information; use it at your own risk and confirm readings with approved equipment when necessary.

## Current capabilities

### Glucose data sources

Master mode currently includes:

- Dexcom G6, Anubis and ONE
- Dexcom G7, ONE+ and Stelo
- Libre 2 and Libre 2 Plus EU sensors over direct Bluetooth
- Compatible Libre sensors through MiaoMiao or Nano/Bubble/Bubble Mini transmitters

Follower mode supports:

- Nightscout, including Loop and OpenAPS/AAPS status data
- Dexcom Share
- Shared Calendar
- CareLink
- LibreLinkUp and LibreLinkUp Russia
- Medtrum EasyView

Sensor support depends on the exact model, region, transmitter firmware and whether an official CGM app must run alongside xDrip4iOS. Check the [compatibility guide](https://xdrip4ios.readthedocs.io/en/latest/#compatible-sensors) before choosing hardware or changing your setup.

### App features

- Adaptive iPhone and iPad Home layouts, including Clock Mode and configurable glucose chart ranges
- Optional sensor-noise bands, reading history, treatments, statistics and time-in-range views
- Custom glucose, missed-reading, device and battery alerts, with spoken readings and trends
- Nightscout upload and synchronization, Dexcom Share upload and Apple Health integration
- Apple Watch app and complications
- Home Screen and Lock Screen widgets, StandBy support, Live Activities and Dynamic Island layouts
- Siri and Shortcuts access to the latest reading
- Optional calendar events and contact-image displays
- AID status displays and open-source data sharing with Loop/iAPS and Trio
- Contextual links to the online documentation and a filterable Activity Log for troubleshooting
- Bluetooth output to M5Stack and M5StickC companion displays

## Requirements

- An iPhone or iPad running iOS/iPadOS 16.2 or later
- Apple Watch Series 4 or newer running watchOS 10 or later for Watch features
- An internet connection for follower modes and cloud services
- A compatible CGM setup for Master mode

Some extensions and system features require newer hardware or iOS versions.

## Availability and development

xDrip4iOS is primarily a do-it-yourself app and does not have an open public TestFlight. The supported installation paths are building from source with Xcode on a Mac or creating a personal TestFlight build with GitHub Actions and Fastlane.

The current project is configured for Xcode 26, Swift 5, iOS 16.2 and watchOS 10. Stable releases are maintained on `master`, while ongoing development is merged through `develop`.

The maintained [installation documentation](https://xdrip4ios.readthedocs.io/en/latest/install/install/) describes the available options and requirements. The repository also contains the supporting [personal TestFlight documentation](fastlane/testflight.md).

## Documentation and support

- [User documentation](https://xdrip4ios.readthedocs.io/en/latest/)
- [Installation and setup](https://xdrip4ios.readthedocs.io/en/latest/install/install/)
- [Troubleshooting](https://xdrip4ios.readthedocs.io/en/latest/troubleshoot/)
- [GitHub issues](https://github.com/JohanDegraeve/xdripswift/issues) for verified, reproducible bugs

Please use the community support channels linked from the documentation for general setup help rather than opening a bug report or contacting maintainers privately.

## Contributing

Bug fixes, translations, documentation improvements and new features are welcome. Base development work on the `develop` branch and open a pull request with a clear description of the change and how it was tested.

## License

xDrip4iOS is released under the [GNU General Public License v3.0](LICENSE).

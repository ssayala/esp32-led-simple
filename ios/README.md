# LED Ticker iOS App

SwiftUI + CoreBluetooth app that mirrors `tools/led.py` — configure the
ESP32 LED Ticker over BLE from your iPhone or iPad.

<p align="center">
  <img src="screenshot.png" alt="LED Ticker iOS app screenshot" width="250">
</p>

## Requirements

- Xcode 15 or newer
- iOS 16+ device (the iOS simulator has no Bluetooth radio)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build

```bash
cd ios
xcodegen generate
open LEDTicker.xcodeproj
```

Then in Xcode:

1. Select the **LEDTicker** scheme.
2. Pick your physical iPhone/iPad as the run destination.
3. Build & run (⌘R). iOS will prompt for Bluetooth permission on first
   launch.

## Signing

The Xcode project is generated from `project.yml` and the pbxproj is
gitignored, so **do not edit signing in Xcode's Signing & Capabilities
pane** — UI edits get wiped the next time `xcodegen generate` runs.

Signing is driven by two xcconfig files in this directory:

| File                    | Checked in? | Purpose                                    |
|-------------------------|-------------|--------------------------------------------|
| `Signing.xcconfig`      | Yes         | Safe defaults (style, identity). No team.  |
| `Signing.local.xcconfig`| **No**      | Your personal `DEVELOPMENT_TEAM` override. |

Simulator builds work out of the box with no local override.

For **device builds**, create `ios/Signing.local.xcconfig` with a single
line:

```
DEVELOPMENT_TEAM = YOURTEAMID
```

You can find your Team ID at
<https://developer.apple.com/account> → Membership. Then run
`xcodegen generate` and build to your device as usual. The `.local`
file is gitignored so your team ID never lands in the public repo.

## Run tests

```bash
cd ios
xcodegen generate
xcodebuild test \
    -project LEDTicker.xcodeproj \
    -scheme LEDTicker \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The test target exercises `Payloads.swift` (pure formatting logic) and
`KnownDevice.swift` (persistence and legacy-key migration). `BLEManager`
needs a real device and is not unit-tested.

## Layout

```
ios/
├── project.yml            XcodeGen config — regenerate the .xcodeproj from here
├── LEDTicker/
│   ├── LEDTickerApp.swift The @main entry point
│   ├── RootView.swift     5-tab TabView + tryAutoConnect on launch
│   ├── AppState.swift     Shared observable state
│   ├── BLEManager.swift   CoreBluetooth wrapper: known-devices list, active connection, queued I/O
│   ├── KnownDevice.swift  Persisted device entry (id, friendlyName, advertisedName, lastConnected)
│   ├── Payloads.swift     Pure payload formatters (mirrors tools/led.py)
│   ├── DeviceTab.swift    Known Devices + WiFi + API key + Reset
│   ├── DisplayTab.swift   Mode status + multi-category toggles
│   ├── StocksTab.swift    Tickers
│   ├── WeatherTab.swift   Locations
│   ├── MessagesTab.swift  Scrolling text
│   ├── Toast.swift        Toast overlay
│   └── Info.plist         Contains NSBluetoothAlwaysUsageDescription
└── LEDTickerTests/
    ├── PayloadsTests.swift
    └── KnownDeviceTests.swift
```

## Design notes

- **Five-tab layout**: Device (connection, WiFi, API key, reset),
  Display (current mode status + multi-category toggles, with prereq
  gating and an at-least-one invariant), Stocks (tickers), Weather
  (locations), Messages (scrolling text). Mode changes are made
  exclusively from the Display tab; the content tabs are read/write for
  their own data only.
- **WiFi SSID and Finnhub API key** are persisted to `UserDefaults` so
  the user doesn't have to retype them on every launch. Everything else
  (tickers, messages, locations, display mode) is fetched fresh from
  the device on each connect — shown as empty (or `—` for mode) while
  disconnected. The WiFi password is never persisted and never exposed
  over BLE; the user retypes it on each launch.
- **Writes and reads are both queued**: every operation uses
  `.withResponse` / `readValue(for:)` and the next is only issued after
  the corresponding delegate fires. This matters because the firmware
  has a 10 s cooldown on ticker/reload/reset writes.
- **Multi-device switcher**: the app remembers a list of LED-Tickers
  under `LEDTicker.knownDevices` in `UserDefaults` (JSON-encoded
  `[KnownDevice]`, MRU-sorted). The Device tab's "Known Devices"
  section shows each remembered device with an in-range / connecting /
  connected / not-in-range badge, plus any nearby-but-not-enrolled peripherals as
  rows with a "Tap to add" affordance. Swipe a row to Rename (alert) or Forget
  (confirmation dialog). One BLE connection is active at a time —
  tapping a different device disconnects the current one first.
- **Auto-connect on launch**: `ble.tryAutoConnect()` runs once from
  `RootView.onAppear` and connects to the most-recently-used device.
  If that device is out of range, the scan times out after 15 s and
  the row shows a failure state — the user then picks another device
  from the list. (Existing single-device users are
  migrated silently from the old `LEDTicker.peripheral.id` key into a
  one-element Known Devices list with a placeholder name that the
  next discovery will refine.)
- **No WiFi auto-fill**: iOS does not expose the phone's SSID or
  password to apps without the Access WiFi Information entitlement
  (paid developer account + extra permissions), and never the password.
  The user must type both in.

## Protocol reference

See `../README.md` and `../CLAUDE.md` for the authoritative description
of the BLE service and its characteristics. Payload formats:

| Char      | UUID suffix | Payload                                       |
|-----------|-------------|-----------------------------------------------|
| tickers   | `...A8`     | `AAPL,MSFT,...` (comma-separated)             |
| mode      | `...A9`     | `all` \| `<cat>` \| `<cat>,<cat>,...` (cat: stocks \| messages \| weather \| clock); read may also return `setup` |
| messages  | `...AA`     | `m1\|m2\|...` (≤ 511 bytes)                   |
| command   | `...AB`     | `reload` or `reset`                           |
| wifi      | `...AC`     | `SSID\|password` (split on first `\|`)        |
| apikey    | `...AD`     | plain string                                  |
| locations | `...AE`     | `ZIP\|City, State\|...` (≤ 5 entries, 204 B)  |

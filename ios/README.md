# LED Ticker iOS App

SwiftUI + CoreBluetooth app that mirrors `tools/led.py` — configure the
ESP32 LED Ticker over BLE from your iPhone or iPad.

> **First connect prompts for a PIN.** Since firmware v0.3.0 the device
> requires BLE bonding before accepting writes. iOS handles this natively:
> a system "Bluetooth Pairing Request" dialog asks for the 6-digit PIN
> shown on the matrix in setup mode (and printed to serial at boot).
> Later connects are silent. After reflashing over an existing install,
> factory-reset the device (10 s BOOT-button hold) to clear stale bonds
> and get a fresh PIN.

## Requirements

- Xcode 26 / iOS 26 SDK (the app uses `.navigationSubtitle` and
  `.glassEffect`, both iOS 26+)
- An iOS 26+ **device** — the simulator has no Bluetooth radio
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build

```bash
cd ios
xcodegen generate
open LEDTicker.xcodeproj
```

In Xcode: select the **LEDTicker** scheme, pick your iPhone/iPad as the
destination, and run (⌘R). iOS prompts for Bluetooth permission on first
launch.

## Signing

The `.xcodeproj` is generated from `project.yml` and gitignored, so **don't
edit signing in Xcode's Signing & Capabilities pane** — those edits are
wiped on the next `xcodegen generate`. Signing comes from two xcconfigs:

| File                     | Checked in? | Purpose                                   |
|--------------------------|-------------|-------------------------------------------|
| `Signing.xcconfig`       | Yes         | Safe defaults (style, identity). No team. |
| `Signing.local.xcconfig` | **No**      | Your personal `DEVELOPMENT_TEAM` override |

Simulator builds need no override. For **device builds**, create
`ios/Signing.local.xcconfig` with one line — `DEVELOPMENT_TEAM = YOURTEAMID`
(find the ID at <https://developer.apple.com/account> → Membership) — then
re-run `xcodegen generate`. The `.local` file is gitignored.

## Test

```bash
cd ios && xcodegen generate
xcodebuild test -project LEDTicker.xcodeproj -scheme LEDTicker \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Tests cover `Payloads.swift` (formatting) and `KnownDevice.swift`
(persistence + legacy-key migration). `BLEManager` needs real hardware and
isn't unit-tested.

## Layout

```
ios/
├── project.yml            XcodeGen config — regenerate the .xcodeproj from here
├── LEDTicker/
│   ├── LEDTickerApp.swift The @main entry point
│   ├── RootView.swift     5-tab TabView; gates non-Device tabs behind connection state
│   ├── DisconnectedView.swift  Empty-state panel for gated tabs while disconnected
│   ├── AppState.swift     Shared observable state + dirty-tracking baselines
│   ├── BLEManager.swift   CoreBluetooth wrapper: known-devices list, connection, queued I/O
│   ├── KnownDevice.swift  Persisted device entry (id, friendlyName, advertisedName, lastConnected)
│   ├── Payloads.swift     Pure payload formatters (mirrors tools/led.py)
│   ├── DeviceTab.swift    Shell — picker (disconnected) vs settings (connected)
│   ├── DevicePickerView.swift   Known/nearby device list with swipe actions
│   ├── DeviceSettingsView.swift Connection + Power + WiFi + API key + Reset
│   ├── DisplayTab.swift   Mode status + multi-category toggles
│   ├── StocksTab.swift    Tickers (unsaved-changes footer)
│   ├── WeatherTab.swift   Locations (unsaved-changes footer)
│   ├── StatusTab.swift    Active sign + iOS-local preset chips
│   ├── DeviceSubtitleNav.swift  `.navigationSubtitle` — active device name on gated tabs
│   ├── Toast.swift        Toast overlay
│   └── Info.plist         NSBluetoothAlwaysUsageDescription
└── LEDTickerTests/
    ├── PayloadsTests.swift
    └── KnownDeviceTests.swift
```

## Design notes

- **Five tabs.** Device (picker when disconnected; Connection / Power /
  WiFi / API key / Reset when connected), Display (mode status +
  multi-category toggles, with prereq gating and an at-least-one
  invariant), Stocks, Weather, Sign. Mode changes happen only on Display;
  content tabs are read/write for their own data.
- **Device tab mirrors iOS Settings → Bluetooth.** Disconnected → picker
  ("Devices"); connected → per-device settings (nav title = device name)
  with a Connection section up top. Single-device users don't see a device
  list as noise; multi-device users disconnect, then pick another.
- **One connection at a time.** NimBLE pauses advertising while a client
  is connected and accepts only one. To hand a device to another phone,
  tap **Disconnect** in the Connection section.
- **No auto-connect.** Launch shows the Known Devices list and waits for a
  tap — opening the app never silently re-attaches. (Legacy single-device
  users are migrated from `LEDTicker.peripheral.id` into a one-element
  list, name refined on next discovery.)
- **Multi-device switcher.** Devices persist under
  `LEDTicker.knownDevices` in `UserDefaults` (JSON, MRU-sorted). Each row
  shows an in-range / connecting / failed / not-in-range badge; nearby
  un-enrolled peripherals appear as "Tap to add". Swipe to Rename or
  Forget. Forget only clears the app's list — it can't delete the iOS
  system bond (no CoreBluetooth API); the dialog points users to Settings.
- **Power toggle.** Write-and-forget switch in Settings that blanks the
  matrix + onboard LED without changing the saved mode. Volatile on the
  device. Auto-hides when the firmware predates the Power characteristic
  (< v0.2.0).
- **Active sign.** A single status (text + optional expiry) preempts the
  ambient scroll; clearing resumes it. Preset chips are **iOS-local**
  (`UserDefaults` key `presetTexts.v1`), never synced.
- **Persistence split.** Only WiFi SSID + Finnhub key persist to
  `UserDefaults`; everything else (tickers, locations, sign, mode) is read
  fresh on each connect. The WiFi password is never persisted or exposed
  over BLE — the field shows "Enter password to change" with an
  explanatory footer so an always-empty field doesn't read as a bug.
- **No WiFi auto-fill.** iOS won't hand the SSID/password to apps without
  the Access WiFi Information entitlement (and never the password), so the
  user types both.
- **Queued I/O.** Every read/write uses `.withResponse` / `readValue` and
  waits for the delegate before the next — required by the firmware's 10 s
  cooldown on ticker/reload/reset writes.
- **Feedback & gating.** `RootView` fires `Haptics.success()` on connect,
  `.tap()` on disconnect (the device is across the room). The active
  device's name rides along as a `.navigationSubtitle` on gated tabs.
  While disconnected, only Device is usable; other tabs show
  `DisconnectedView` (copy adapts to BLE state) with an "Open Device tab"
  button. Stocks/Weather show an orange "N unsaved change(s)" footer when
  the local list diverges from the device baseline.

## Protocol reference

The BLE service UUIDs and payload formats are documented authoritatively
in [`../BLE_PROTOCOL.md`](../BLE_PROTOCOL.md). `Payloads.swift` is the
Swift implementation of those formats and mirrors `tools/led.py`.

# LED Matrix Ticker
Desk sign + ambient ticker built on an ESP32-S3 and a DIYables 4-in-1 MAX7219 LED matrix. Rotates stocks, weather, and a clock as ambient info, and flips to a steady sign ("BUSY", "FOCUS", "ON AIR") on demand — with an optional timer so it clears itself.

A simpler version of my other project, [esp32-led-matrix](https://github.com/ssayala/esp32-led-matrix). This version also inlcudes a custom PCB design for plugging in ESP32-S3 and LED Matrix into.



## Features

- **Sign mode** — set a one-tap status ("BUSY", "FOCUS", "ON AIR", custom text). Short text displays steady; longer text scrolls. Optional auto-clear after N minutes. Overrides the ambient rotation while active, then reverts. Preset chips for common statuses live in the iOS app.
- Live stock quotes from Finnhub API
- Live weather for multiple locations (Open-Meteo, zip or "City, State")
- 12-hour clock (HH:MM AM/PM) — steady when shown alone (no blink — the minute changing is the only motion), scrolling when mixed with other categories. Timezone is hardcoded to US Pacific in `initTime()`; change the POSIX TZ string there to ship in a different zone.
- No secrets at build time — WiFi credentials and API key configured via BLE and stored in NVS
- Bluetooth (BLE) control — update WiFi, API key, stock symbols, active status, and display mode wirelessly
- Companion [iOS app](ios/README.md) (SwiftUI + CoreBluetooth) — multi-device switcher with a Known Devices list, per-category Display toggles, and Setup-mode awareness. Auto-connects to the most-recently-used device on launch.
- Onboard RGB LED lights blue during network fetches
- All settings persist across reboots (NVS flash storage). The active status sign is intentionally *not* persisted — a power cycle clears it and the device resumes its ambient mode.
- Setup mode shows configuration hints (and the BLE device name) when WiFi/API key are missing, then auto-falls into the chosen ambient mode after 60s of no BLE activity
- Market-hours aware — skips API calls when NYSE is closed
- Auto-refreshes every 5 minutes

## Hardware

This firmware targets one specific dev board. The custom PCB is designed around the same module's pinout, so for a drop-in build use this exact part:

| Component | Part | Notes |
|-----------|------|-------|
| MCU board | [**Freenove ESP32-S3-WROOM (FNK0099)**](https://store.freenove.com/products/fnk0099) | Required as-is if you're using the included PCB. The firmware also assumes the onboard NeoPixel on GPIO 48 (status indicator) and native USB-CDC on boot — both are Freenove-specific. |
| Display | [DIYables 4-in-1 MAX7219 8x8 LED matrix](https://diyables.io/products/dot-matrix-display-fc16-4-in-1-32x4-led) | 32×8 pixel matrix, SPI-driven via the MD_Parola library. |

### Wiring (matches the PCB)

| Matrix Pin | ESP32-S3 GPIO |
|------------|---------------|
| VCC | 5V |
| GND | GND |
| DIN | 6 (MOSI) |
| CLK | 4 (SCK) |
| CS | 5 |

The onboard RGB LED (GPIO 48) lights blue during network fetches.

### Using a different ESP32-S3 board?

The firmware *will* run on any ESP32-S3 (the `platformio.ini` target is the generic `esp32-s3-devkitc-1`), but you'll need to edit the `#define`s near the top of `src/main.cpp`:

- `DIN_PIN`, `CLK_PIN`, `CS_PIN` — change to match your wiring. The MAX7219 needs hardware SPI; we call `SPI.begin(CLK, -1, DIN, CS)` explicitly because the ESP32-S3 default SPI pins don't match the Freenove layout.
- `RGB_LED_PIN` — change to your board's onboard NeoPixel pin, or set to a free GPIO (the fetch indicator just won't be visible). On boards without an onboard NeoPixel the `neopixelWrite()` calls become harmless writes to a floating pin.

The **PCB has no such flexibility** — it's laid out for the Freenove FNK0099 module specifically. Different module = different footprint = won't fit.

## Custom PCB

If you prefer, you can order a custom PCB that carries a [Freenove ESP32-S3-WROOM (FNK0099)](https://store.freenove.com/products/fnk0099) module and MAX7219 matrix header on a single board. The board outline, header positions, and module footprint are all sized for that specific Freenove part — substituting a different ESP32-S3 dev board won't work.

![PCB 3D render](pcb/pcb.png)

Customer PCB was designed in [EasyEDA](https://easyeda.com/). You can order this via JLCPCB or any other PCB manufacturer.  

| File | Purpose |
|------|---------|
| [`pcb/EasyEDA_PCB.json`](pcb/EasyEDA_PCB.json) | EasyEDA project source — open this to edit the schematic and layout |
| [`pcb/EasyEDA_PCB.dxf`](pcb/EasyEDA_PCB.dxf) | Board outline / mechanical drawing (DXF) |
| [`pcb/EasyEDA_PCB.obj`](pcb/EasyEDA_PCB.obj) | 3D model of the assembled board (Wavefront OBJ) |
| [`pcb/EasyEDA_PCB.mtl`](pcb/EasyEDA_PCB.mtl) | Material definitions for the OBJ model |
| [`pcb/pcb.png`](pcb/pcb.png) | 3D render shown above |

## Setup

1. Install [PlatformIO](https://platformio.org/)

2. Optionally edit `src/config.h` to set default stock symbols and weather locations:
   ```c
   const char *stockTickers[]     = {"AAPL", "GOOGL", "MSFT", "AMZN"};
   const char *defaultLocations[] = {"Redmond, WA", "Seattle, WA"};
   ```
   These seed NVS on first boot. After that, use the BLE tool to change them.

3. Build and upload:
   ```
   pio run -t upload
   ```

4. Monitor serial output:
   ```
   pio device monitor
   ```

5. On first boot, with no WiFi configured, the display enters setup mode — alternating between the BLE device name (e.g. `LED-Ticker-AB12`) and `Configure WiFi over BLE`. Connect over BLE and configure:
   ```
   uv run tools/led.py wifi My Network Name password123
   uv run tools/led.py apikey your-finnhub-key
   ```
   The last argument is always the password — everything before it is the SSID, so spaces in network names work naturally.

   If WiFi is configured but you skip the Finnhub key, after 60 seconds of no BLE activity the display falls into the chosen ambient mode — categories whose prereqs are still missing show a "Loading..." hint, the rest run normally. With *no* WiFi configured the device stays in setup mode indefinitely (nothing in the ambient rotation works without it, so "Configure WiFi over BLE" is the more useful screen). Each accepted BLE write resets the 60s timer. You can also set a status sign over BLE at any point — it takes over the display regardless of setup state, and works without WiFi (timed signs require NTP and silently become indefinite when written before the clock syncs).

   Get a free Finnhub API key at https://finnhub.io/register

## BLE Control

The device advertises as `LED-Ticker-XXXX`, where `XXXX` is the low 2 bytes of the chip MAC (so multiple boards on the same bench are distinguishable). The setup-mode display shows this full name. Use the included script to control it from any machine with Bluetooth:

```bash
# Install uv if needed: https://docs.astral.sh/uv/getting-started/installation/

# Set stock symbols (fetches new quotes immediately)
uv run tools/led.py tickers AAPL TSLA NVDA SPY

# Sign mode — set / clear the active status sign
uv run tools/led.py status "BUSY" 30          # show "BUSY" for 30 minutes, then auto-clear
uv run tools/led.py status "ON AIR"           # indefinite (until cleared)
uv run tools/led.py status clear              # clear the sign now

# Set weather locations (zip codes or "City, State" to disambiguate)
uv run tools/led.py locations "Seattle, WA" "Redmond, WA" 98052

# Switch ambient display mode — pick any subset of {stocks, weather, clock},
# or 'all' for every category. Selection is persisted across reboots.
# (Status sign, when active, overrides whatever ambient mode is selected.)
uv run tools/led.py mode stocks
uv run tools/led.py mode stocks weather       # combo: round-robins between two
uv run tools/led.py mode clock                # static digital clock, no blink
uv run tools/led.py mode all                  # every category

# Update WiFi credentials and reconnect (SSID may contain spaces)
uv run tools/led.py wifi My Network Name password123

# Set Finnhub API key
uv run tools/led.py apikey your-finnhub-key

# Force an immediate stock quote refresh
uv run tools/led.py reload

# Clear all NVS data and revert to config.h defaults
# Note: this also clears WiFi and API key — you will need to reconfigure them
uv run tools/led.py reset
```

### BLE Service UUIDs

For building a custom app (e.g. iOS with CoreBluetooth):

| | UUID | Access |
|---|---|---|
| Service | `4fafc201-1fb5-459e-8fcc-c5c9c331914b` | — |
| Tickers | `beb5483e-36e1-4688-b7f5-ea07361b26a8` | read/write |
| Mode | `beb5483e-36e1-4688-b7f5-ea07361b26a9` | read/write |
| Command | `beb5483e-36e1-4688-b7f5-ea07361b26ab` | write |
| WiFi | `beb5483e-36e1-4688-b7f5-ea07361b26ac` | read/write (read returns SSID only) |
| API Key | `beb5483e-36e1-4688-b7f5-ea07361b26ad` | read/write |
| Locations | `beb5483e-36e1-4688-b7f5-ea07361b26ae` | read/write |
| Status | `beb5483e-36e1-4688-b7f5-ea07361b26af` | read/write |

Payload formats:
- **Tickers:** comma-separated symbols — `AAPL,MSFT,GOOGL`
- **Mode:** a single category (`stocks`, `weather`, `clock`), the keyword `all`, or a comma-separated subset (e.g. `stocks,weather`). The chosen mask is persisted to NVS and survives reboots. The device round-robins through enabled categories, one full pass of each per cycle. When `clock` is the *only* category enabled the display switches to a steady "H:MM" (no blink) instead of scrolling; in any mix with other categories the clock scrolls as "H:MM AM/PM" alongside them. Requesting any subset whose prerequisites are missing (e.g. stocks without WiFi/API key, clock without WiFi for NTP) diverts the display to setup mode until the missing pieces are configured (or the 60s inactivity timer falls back into the chosen mode). The Status characteristic is orthogonal: an active sign overrides the ambient mode until it clears or expires.
- **Status:** `text|N` to set, empty payload to clear. `N` is an unsigned integer number of *seconds* until auto-clear; `N=0` means indefinite (until cleared). Text up to 96 bytes; short text (≤5 chars) displays steady (no blink — a sign is information, not an alarm), longer text scrolls. Reads return `text|M` where `M` is seconds remaining (`0` if indefinite), or an empty string when no status is active. Status state lives in RAM only — a power cycle clears any active sign, and the device boots into its ambient mode. If a timed status (`N>0`) is written before NTP has synced, it is silently coerced to indefinite to avoid bad-clock expiry. Preset chips for common statuses (e.g. "BUSY", "FOCUS") are managed entirely client-side — the device has no preset library of its own. (UUID `...26aa` was once a "Messages" characteristic; it is not registered in the current firmware.)
- **Locations:** pipe-separated zip codes or `City, State` strings — `Seattle, WA|98052|Redmond, WA`. The device geocodes each via Open-Meteo on first fetch and caches the result; when a query contains a trailing `, XX`, the `XX` is used as a state/region filter to disambiguate duplicate city names.
- **Command:** `reload` (force stock refresh) or `reset` (clear NVS, revert to `config.h` defaults, including clearing any active status)
- **WiFi:** `SSID|password` — updates credentials, saves to NVS, reconnects immediately
- **API Key:** plain string — Finnhub API key, saved to NVS, triggers immediate stock fetch

## iOS App

A SwiftUI + CoreBluetooth companion app lives in [`ios/`](ios/README.md).
It exposes the same controls as `tools/led.py` — WiFi, API key, tickers,
the active sign (with a local preset chip grid), weather locations,
display mode, reload, and reset — and reads current settings back from
the device on connect so the UI reflects actual state.

See [`ios/README.md`](ios/README.md) for build instructions, XcodeGen
setup, and signing configuration.

## Configuration

Tunables at the top of `src/main.cpp`:

| Define | Default | Description |
|--------|---------|-------------|
| `SCROLL_SPEED` | 50 | ms per frame (lower = faster) |
| `FETCH_INTERVAL_MS` | 5 min | Stock quote refresh interval |
| `MAX_DEVICES` | 4 | Number of 8x8 LED modules |
| `RGB_LED_PIN` | 48 | Onboard NeoPixel for fetch indicator |

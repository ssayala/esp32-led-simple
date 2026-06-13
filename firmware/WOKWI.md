# Wokwi simulation

A virtual ESP32-S3 + MAX7219 matrix + WS2812 for testing firmware without
hardware. Config lives in [`wokwi.toml`](wokwi.toml) (points at the PlatformIO
build artifacts) and [`diagram.json`](diagram.json) (the wiring, matching the
pins in [`src/config.h`](src/config.h)).

## Run it

1. Build first — the sim runs the compiled binary, not the source:
   ```bash
   pio run -d firmware
   ```
2. Install the **Wokwi for VS Code** extension, open this repo, and run
   **"Wokwi: Start Simulator"** with `firmware/diagram.json` focused. (Or use
   the [Wokwi CLI](https://docs.wokwi.com/wokwi-ci/getting-started).)
3. The serial monitor opens automatically over the board's USB — no TX/RX
   wiring needed. Watch boot logs, the PIN, and `[fetch]` lines there.

The serial monitor is the control plane in the sim (BLE isn't simulated): type
console commands at it — `help`, `info`, `wifi <ssid>`, `sign HELLO`, etc. See
[`FIRMWARE_GUIDE.md`](FIRMWARE_GUIDE.md) → "Serial console".

## Run it on wokwi.com (website)

The website can't compile the PlatformIO project, so upload a prebuilt image.
The real-device build uses OPI PSRAM + `qio_opi` flash, which the Wokwi ESP32-S3
model lacks — that image boot-loops there. Use the **`wokwi` env** instead (no
PSRAM, `qio_qspi` flash):

```bash
pio run -d firmware -e wokwi
# merge bootloader + partitions + app into one uploadable image:
B=firmware/.pio/build/wokwi
python ~/.platformio/packages/tool-esptoolpy/esptool.py --chip esp32s3 \
  merge_bin -o firmware/wokwi-merged.bin \
  0x0 $B/bootloader.bin 0x8000 $B/partitions.bin \
  0xe000 ~/.platformio/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin \
  0x10000 $B/firmware.bin
```

Then open the [ESP32 custom-app template](https://wokwi.com/projects/305457271083631168),
paste `firmware/diagram.json` into its `diagram.json`, and press **F1 → "Upload
Firmware and Start Simulation…"** → pick `firmware/wokwi-merged.bin`. The website
runs the public IoT gateway in your browser, so the live fetch path is reachable
there even when the local VS Code gateway isn't.

## What it can and can't test

| Subsystem | Works? | Notes |
|-----------|--------|-------|
| Boot, serial, NVS | ✅ | Emulated flash persists within a session |
| MAX7219 display + scrolling | ✅ | 4 chained modules via the `chain` attr; `"layout": "fc16"` matches the DIYables hardware (`HARDWARE_TYPE` = `FC16_HW`) — omit it and columns render scrambled |
| WS2812 status LED | ✅ | Lights blue during fetches |
| WiFi + HTTP (stocks/weather) | ✅ | Joins `Wokwi-GUEST` with a real internet gateway |
| **BLE / NimBLE control plane** | ❌ | **Not simulated** — no auth, sign mode, or config writes |

Because BLE provisioning is unavailable, a fresh sim boots with empty NVS →
`MODE_SETUP` (shows the device name + PIN), and never fetches.

## Exercising the weather/stock fetch path

The **serial console** (see [`FIRMWARE_GUIDE.md`](FIRMWARE_GUIDE.md) →
"Serial console") is the way to provision in the sim — BLE isn't available, but
serial is. In the Wokwi serial monitor type:

    wifi Wokwi-GUEST
    apikey <key>
    tickers AAPL,MSFT

`Wokwi-GUEST` is an open network, so `wifi Wokwi-GUEST` (no password) joins it.
Then watch the `[fetch]` lines run against live Finnhub/MET Norway. No
compile-time seed and no committed secrets needed.

To watch the new 30-minute weather throttle ([`WEATHER_INTERVAL_MS`](src/config.h))
without waiting half an hour, temporarily lower it (e.g. to `60 * 1000`) and
confirm weather fetches less often than the 5-minute stock cadence in the
`[fetch]` serial logs. The throttle's skip path is currently silent — add a
`Serial.printf` there if you want an explicit marker.

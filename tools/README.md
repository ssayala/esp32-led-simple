# `led_ticker` — Python library & CLI for the LED Ticker

`led_ticker` speaks the same BLE service as the iOS app, so you can drive the
device — or build your own tools — from any machine with Bluetooth. The device
advertises as `LED-Ticker-XXXX`.

## Install

```bash
pip install led-ticker      # or: uv add led-ticker
```

This installs the importable `led_ticker` package and the `led` command.
From a checkout you can also run the CLI with no install via uv:

```bash
uv run tools/led.py <cmd>   # uses ./src directly
```

## Library

```python
from led_ticker import LedTicker

# Reuse one connection for several operations:
with LedTicker(pin="482913") as d:
    d.set_tickers(["AAPL", "MSFT"])
    d.set_status("BUSY", minutes=30)
    print(d.get_version())          # -> "0.3.0"
    s = d.get_status()              # -> Status(text="BUSY", seconds=1800)

# Or a one-shot for a single call (opens and closes its own connection):
import led_ticker
led_ticker.set_mode(["stocks", "weather"])
```

`LedTicker(address=None, name_prefix="LED-Ticker", timeout=15.0, pin=None)`.
Pass `address=` to target a specific unit; otherwise the first `LED-Ticker-*`
in range is used. Methods raise `ValidationError`, `AuthError`,
`DeviceNotFoundError`, or `ProtocolError` (all subclasses of `LedTickerError`).

## CLI

```bash
# Sign mode
uv run tools/led.py status "BUSY" 30      # show for 30 min, then auto-clear
uv run tools/led.py status "ON AIR"       # indefinite
uv run tools/led.py status clear

# Timer mode (countdown sign — random animation at zero, then resumes ambient)
uv run tools/led.py timer 10              # 10-minute countdown
uv run tools/led.py timer cancel

# Ambient mode (subset of stocks/weather/clock, 'all', or 'none' for sign-only)
uv run tools/led.py mode stocks weather
uv run tools/led.py mode clock
uv run tools/led.py mode all
uv run tools/led.py mode none

# Power (volatile — power cycle returns to on)
uv run tools/led.py power on
uv run tools/led.py power off

# Display settings (persisted on the device)
uv run tools/led.py display                  # show current brightness + scroll speed
uv run tools/led.py display brightness 8     # brightness 0-15
uv run tools/led.py display speed 50         # scroll ms/step 20-500 (lower = faster)
uv run tools/led.py display 8 50             # both at once

# Timezone (persisted; POSIX TZ string — the iOS app has a friendly picker)
uv run tools/led.py timezone                              # show current
uv run tools/led.py timezone "EST5EDT,M3.2.0,M11.1.0"     # US Eastern

# Data
uv run tools/led.py tickers AAPL TSLA NVDA SPY
uv run tools/led.py locations "47.61,-122.33,Seattle"   # lat,lon,label (look up coords online)
uv run tools/led.py apikey your-finnhub-key
uv run tools/led.py wifi My Network Name password

# Inspect
uv run tools/led.py get version           # firmware version on the device
uv run tools/led.py get wifi|apikey|tickers|status|locations|mode|power|display|timezone|version  # read other settings

# Auth
uv run tools/led.py pin 482913            # save the device's PIN locally (~/.config/led-ticker/pin)
uv run tools/led.py pin clear             # forget the saved PIN
uv run tools/led.py pin-enforce on        # device: require PIN for writes (default after a fresh flash)
uv run tools/led.py pin-enforce off       # device: stop requiring PIN (escape hatch)

# Maintenance
uv run tools/led.py reload                # force stock refresh
uv run tools/led.py reset                 # wipe NVS, rotate PIN, revert to config.h defaults
```

Stale-PIN safety: every write probes the device after sending the PIN and exits with a clear error if the PIN was rotated by a factory reset — a write never fails silently because of an out-of-date local PIN.

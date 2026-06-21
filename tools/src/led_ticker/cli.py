"""Command-line front end. Parses argv, calls the led_ticker library, and
translates library exceptions into the historical messages and exit codes.
This module is the ONLY place that prints or sets exit status."""
from __future__ import annotations

import sys

from . import auth
from . import protocol as P
from .client import LedTicker
from .errors import AuthError, DeviceNotFoundError, ProtocolError, ValidationError

GET_KEYS = (
    "wifi", "apikey", "tickers", "status", "locations",
    "mode", "version", "power", "display", "timezone",
)


# -- display formatters (presentation only) --------------------------------
def _fmt_status(s) -> str:
    if s is None:
        return "(no active status)"
    if s.indefinite:
        return f"{s.text} (indefinite)"
    m, sec = divmod(s.seconds, 60)
    return f"{s.text} ({m}m {sec}s remaining)"


def _fmt_display(d) -> str:
    if d is None:
        return "(unknown — pre-Display firmware?)"
    return f"brightness {d.brightness}/15, scroll {d.scroll_ms} ms/step"


def _format_get(key: str, d: LedTicker) -> str:
    if key == "status":
        return _fmt_status(d.get_status())
    if key == "display":
        return _fmt_display(d.get_display())
    if key == "tickers":
        return ",".join(d.get_tickers()) or "(none)"
    if key == "locations":
        locs = d.get_locations()
        return "\n".join(f"  {i + 1}. {loc}" for i, loc in enumerate(locs)) or "(none)"
    if key == "wifi":
        return d.get_wifi() or "(not set)"
    if key == "apikey":
        return d.get_apikey() or "(not set)"
    if key == "mode":
        return d.get_mode() or "(unknown)"
    if key == "power":
        return d.get_power() or "(unknown)"
    if key == "version":
        return d.get_version() or "(unknown — pre-0.1.0 firmware?)"
    if key == "timezone":
        return d.get_timezone() or "(unknown — pre-Timezone firmware?)"
    raise AssertionError(key)  # guarded by caller


# -- subcommands -----------------------------------------------------------
# Each returns an int exit code (0 = success) and may print to stdout/stderr.
def cmd_tickers(args, pin):
    if not args:
        print("Usage: led.py tickers TICKER [TICKER ...]")
        return 1
    # validate before connecting
    payload = P.encode_tickers(args)
    with LedTicker(pin=pin) as d:
        d.set_tickers(args)
    print("Sent: " + payload.decode())
    return 0


def cmd_status(args, pin):
    if not args:
        with LedTicker(pin=pin) as d:
            print(_fmt_status(d.get_status()))
        return 0
    if args[0] == "clear":
        with LedTicker(pin=pin) as d:
            d.clear_status()
        print("Sent: (clear)")
        return 0
    text = args[0]
    minutes = 0
    if len(args) >= 2:
        try:
            minutes = int(args[1])
        except ValueError:
            print(f"ERROR: duration must be an integer number of minutes, got '{args[1]}'")
            return 1
    # validate before connecting
    payload = P.encode_status(text, minutes)
    with LedTicker(pin=pin) as d:
        d.set_status(text, minutes)
    print("Sent: " + payload.decode())
    return 0


def cmd_timer(args, pin):
    if not args:
        print("Usage: led.py timer <minutes 1-99 | cancel>")
        return 1
    arg = args[0].strip().lower()
    if arg == "cancel":
        with LedTicker(pin=pin) as d:
            d.cancel_timer()
        print("Sent: timer cancel")
        return 0
    try:
        mins = int(arg)
    except ValueError:
        print("ERROR: minutes must be an integer 1-99 (or 'cancel')")
        return 1
    # validate before connecting
    P.validate_timer_minutes(mins)
    with LedTicker(pin=pin) as d:
        d.set_timer(mins)
    print(f"Sent: timer {mins}")
    return 0


def cmd_locations(args, pin):
    if not args:
        print('Usage: led.py locations "LAT,LON,LABEL" ...')
        print('       e.g. led.py locations "47.61,-122.33,Seattle"')
        print("       (look up coordinates at e.g. latlong.net)")
        return 1
    # validate before connecting
    payload = P.encode_locations(args)
    with LedTicker(pin=pin) as d:
        d.set_locations(args)
    print("Sent: " + payload.decode())
    return 0


def cmd_mode(args, pin):
    if not args:
        print("Usage: led.py mode all | none | <category> [<category> ...]")
        print("  where <category> is one of: stocks, weather, clock")
        print("  'none' = sign-only (idle pixel between signs)")
        return 1
    # validate before connecting
    payload = P.encode_mode(args)
    with LedTicker(pin=pin) as d:
        d.set_mode(args)
    print("Sent: " + payload.decode())
    return 0


def cmd_power(args, pin):
    if not args or args[0] not in ("on", "off"):
        print("Usage: led.py power on | off")
        return 1
    with LedTicker(pin=pin) as d:
        d.set_power(args[0] == "on")
    print(f"Sent: {args[0]}")
    return 0


def cmd_display(args, pin):
    if not args:
        with LedTicker(pin=pin) as d:
            print(_fmt_display(d.get_display()))
        return 0
    try:
        if args[0] == "brightness" and len(args) == 2:
            b = int(args[1])
            # validate before connecting
            if b not in P.BRIGHTNESS_RANGE:
                raise ValidationError(f"brightness must be {P.BRIGHTNESS_RANGE.start}-{P.BRIGHTNESS_RANGE.stop - 1}, got {b}")
            with LedTicker(pin=pin) as d:
                d.set_brightness(b)
        elif args[0] == "speed" and len(args) == 2:
            s = int(args[1])
            # validate before connecting
            if s not in P.SCROLL_MS_RANGE:
                raise ValidationError(f"scroll speed must be {P.SCROLL_MS_RANGE.start}-{P.SCROLL_MS_RANGE.stop - 1}, got {s}")
            with LedTicker(pin=pin) as d:
                d.set_scroll_speed(s)
        elif len(args) == 2:
            b, s = int(args[0]), int(args[1])
            # validate before connecting
            P.encode_display(b, s)
            with LedTicker(pin=pin) as d:
                d.set_display(b, s)
        else:
            print("Usage: led.py display                     show current settings")
            print("       led.py display brightness <0-15>   set brightness")
            print("       led.py display speed <20-500>      set scroll ms/step (lower = faster)")
            print("       led.py display <0-15> <20-500>     set both")
            return 1
    except ValueError:
        print("ERROR: display values must be integers")
        return 1
    print("Sent.")
    return 0


def cmd_timezone(args, pin):
    if not args:
        with LedTicker(pin=pin) as d:
            print(d.get_timezone() or "(unknown — pre-Timezone firmware?)")
        return 0
    # validate before connecting
    P.validate_timezone(args[0])
    with LedTicker(pin=pin) as d:
        d.set_timezone(args[0])
    print(f"Sent: {args[0].strip()}")
    return 0


def cmd_apikey(args, pin):
    if not args:
        print("Usage: led.py apikey KEY")
        return 1
    with LedTicker(pin=pin) as d:
        d.set_apikey(args[0])
    print("Sent.")
    return 0


def cmd_wifi(args, pin):
    if len(args) < 2:
        print("Usage: led.py wifi SSID PASSWORD")
        return 1
    ssid = " ".join(args[:-1])
    password = args[-1]
    # validate before connecting
    P.encode_wifi(ssid, password)
    with LedTicker(pin=pin) as d:
        d.set_wifi(ssid, password)
    print("Sent.")
    return 0


def cmd_get(args, pin):
    if not args or args[0] not in GET_KEYS:
        print(f"Usage: led.py get {'|'.join(GET_KEYS)}")
        return 1
    with LedTicker(pin=pin) as d:
        print(_format_get(args[0], d))
    return 0


def cmd_reload(args, pin):
    with LedTicker(pin=pin) as d:
        d.reload()
    print("Sent: reload")
    return 0


def cmd_reset(args, pin):
    confirm = input("Reset all NVS data to config.h defaults (also rotates PIN)? [y/N] ")
    if confirm.strip().lower() != "y":
        print("Aborted.")
        return 0
    with LedTicker(pin=pin) as d:
        d.reset()
    print("Sent: reset")
    return 0


def cmd_pin(args, pin):
    # Local-only PIN cache management; never touches the device.
    if not args:
        saved = auth.saved_pin(path=auth.DEFAULT_PIN_PATH)
        if saved:
            print(f"Saved PIN: {saved}  (path: {auth.DEFAULT_PIN_PATH})")
        else:
            print(f"No PIN saved at {auth.DEFAULT_PIN_PATH}")
        return 0
    if args[0] == "clear":
        if auth.clear_pin(path=auth.DEFAULT_PIN_PATH):
            print(f"Cleared saved PIN ({auth.DEFAULT_PIN_PATH})")
        else:
            print("No PIN was saved.")
        return 0
    code = P.validate_pin(args[0])
    auth.save_pin(code, path=auth.DEFAULT_PIN_PATH)
    print(f"Saved PIN to {auth.DEFAULT_PIN_PATH} (future calls will include it automatically)")
    return 0


def cmd_pin_enforce(args, pin):
    if not args or args[0] not in ("on", "off"):
        print("Usage: led.py pin-enforce on | off")
        print("  on  — device requires PIN auth for every write")
        print("  off — device accepts writes from anyone (default)")
        return 1
    with LedTicker(pin=pin) as d:
        d.set_pin_enforce(args[0] == "on")
    print(f"Sent: pin-enforce {args[0]}")
    return 0


COMMANDS = {
    "tickers": cmd_tickers,
    "status": cmd_status,
    "timer": cmd_timer,
    "locations": cmd_locations,
    "mode": cmd_mode,
    "power": cmd_power,
    "display": cmd_display,
    "timezone": cmd_timezone,
    "apikey": cmd_apikey,
    "wifi": cmd_wifi,
    "get": cmd_get,
    "reload": cmd_reload,
    "reset": cmd_reset,
    "pin": cmd_pin,
    "pin-enforce": cmd_pin_enforce,
}


def _print_help():
    print("Usage: led.py [--pin XXXXXX] <command> [args...]")
    print()
    print("  tickers     AAPL MSFT GOOGL          set stock symbols and reload quotes")
    print("  status      [TEXT [MINUTES] | clear] set / clear the active sign (0 min = indefinite)")
    print("  timer       <minutes 1-99 | cancel>  start/cancel a countdown timer on the LED")
    print("  locations   'LAT,LON,LABEL' ...       set weather locations (look up lat/lon online)")
    print("  mode        all | <cat> [<cat> ...]  switch display mode (cat: stocks|weather|clock)")
    print("  power       on | off                 turn display on or off (volatile)")
    print("  display     [brightness 0-15 | speed 20-500 | B MS]  show / set brightness & scroll speed")
    print("  timezone    [POSIX_TZ]               show / set clock timezone")
    print("  apikey      KEY                      set Finnhub API key")
    print("  wifi        SSID PASSWORD            update WiFi credentials and reconnect")
    print(f"  get         {'|'.join(GET_KEYS)}  read a setting")
    print("  reload                               force immediate stock refresh")
    print("  reset                                clear NVS and revert to defaults (rotates PIN)")
    print("  pin         [DIGITS | clear]         save / show / clear local PIN cache")
    print("  pin-enforce on | off                 toggle device-side PIN enforcement")


def _print_auth_error(e: AuthError) -> None:
    if e.pin_present:
        print(
            f"ERROR: device rejected saved PIN ({auth.DEFAULT_PIN_PATH}). The PIN was likely\n"
            "       rotated by a factory reset. Read the new PIN off the LED in\n"
            "       setup mode (or from the serial monitor) and run:\n"
            "         led.py pin <new-6-digits>",
            file=sys.stderr,
        )
    else:
        print(
            "ERROR: device has PIN enforcement on and no PIN is configured\n"
            "       client-side. Run: led.py pin <6-digits>  (PIN scrolls on the\n"
            "       LED in setup mode, or appears on the serial monitor at boot).",
            file=sys.stderr,
        )


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    pin = None
    if argv and argv[0] == "--pin":
        if len(argv) < 2:
            print("ERROR: --pin requires a value")
            return 1
        pin = argv[1].strip()
        argv = argv[2:]
    if not argv or argv[0] not in COMMANDS:
        _print_help()
        return 1
    handler = COMMANDS[argv[0]]
    try:
        return handler(argv[1:], pin)
    except ValidationError as e:
        print(f"ERROR: {e}")
        return 1
    except AuthError as e:
        _print_auth_error(e)
        return 2
    except DeviceNotFoundError as e:
        print(f"ERROR: {e}. Is it powered on and in range?")
        return 1
    except ProtocolError as e:
        print(f"ERROR: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())

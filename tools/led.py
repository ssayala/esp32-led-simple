#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["bleak"]
# ///
"""Thin entry point for the LED-Ticker CLI.

All logic lives in the `led_ticker` package under ./src. This shim keeps the
historical `uv run tools/led.py <cmd>` invocation working without installing
the package; `pip install led-ticker` additionally provides a `led` command.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent / "src"))

from led_ticker.cli import main  # noqa: E402  (path set up above)

if __name__ == "__main__":
    sys.exit(main())

"""PIN resolution and the local PIN cache.

Resolution order: explicit override -> LED_TICKER_PIN env var -> cache file.
The cache path is injectable so tests never touch a real home directory.
"""
from __future__ import annotations

import os
import pathlib

DEFAULT_PIN_PATH = pathlib.Path.home() / ".config" / "led-ticker" / "pin"


def resolve_pin(override: str | None = None, *, path: pathlib.Path = DEFAULT_PIN_PATH) -> str | None:
    if override:
        return override.strip()
    env = os.environ.get("LED_TICKER_PIN")
    if env:
        return env.strip()
    if path.exists():
        return path.read_text().strip() or None
    return None


def saved_pin(*, path: pathlib.Path = DEFAULT_PIN_PATH) -> str | None:
    if path.exists():
        return path.read_text().strip() or None
    return None


def save_pin(pin: str, *, path: pathlib.Path = DEFAULT_PIN_PATH) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(pin + "\n")
    path.chmod(0o600)


def clear_pin(*, path: pathlib.Path = DEFAULT_PIN_PATH) -> bool:
    if path.exists():
        path.unlink()
        return True
    return False

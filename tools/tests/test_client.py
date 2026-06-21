from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

import led_ticker.client as client_mod
import led_ticker.protocol as P
from led_ticker import LedTicker
from led_ticker.errors import AuthError, DeviceNotFoundError


def _async_return(value):
    async def _f(*a, **k):
        return value
    return _f


@pytest.fixture
def ble(monkeypatch):
    reads = {P.AUTH_CHAR_UUID: b"ok"}
    writes = []

    class FakeClient:
        is_connected = True

        async def connect(self):
            pass

        async def disconnect(self):
            pass

        async def read_gatt_char(self, uuid):
            return reads.get(uuid, b"ok")

        async def write_gatt_char(self, uuid, data, response=True):
            writes.append((uuid, data))

    fake = FakeClient()
    monkeypatch.setattr(client_mod, "BleakClient", lambda device: fake)
    monkeypatch.setattr(
        client_mod.BleakScanner, "find_device_by_filter", _async_return(MagicMock())
    )
    # Make PIN resolution deterministic: only the explicit override is used.
    monkeypatch.setattr(client_mod, "resolve_pin", lambda override=None: override)
    return SimpleNamespace(client=fake, reads=reads, writes=writes)


def test_set_tickers_writes_encoded_payload(ble):
    with LedTicker() as d:
        d.set_tickers(["aapl", "msft"])
    assert (P.TICKER_CHAR_UUID, b"AAPL,MSFT") in ble.writes


def test_status_clear_and_get(ble):
    ble.reads[P.STATUS_CHAR_UUID] = b"BUSY|1800"
    with LedTicker() as d:
        d.clear_status()
        s = d.get_status()
    assert (P.STATUS_CHAR_UUID, b"") in ble.writes
    assert (s.text, s.seconds) == ("BUSY", 1800)


def test_reads_skip_auth_probe(ble):
    # No PIN set; a pure read must not write to the Auth characteristic.
    with LedTicker() as d:
        assert d.get_version() == "ok"  # default reads map returns b"ok"
    assert ble.writes == []


def test_rejected_pin_raises_auth_error(ble):
    ble.reads[P.AUTH_CHAR_UUID] = b"denied"
    with pytest.raises(AuthError) as exc:
        with LedTicker(pin="000000") as d:
            d.set_power(True)
    assert exc.value.pin_present is True


def test_device_not_found(monkeypatch, ble):
    monkeypatch.setattr(
        client_mod.BleakScanner, "find_device_by_filter", _async_return(None)
    )
    with pytest.raises(DeviceNotFoundError):
        with LedTicker():
            pass


def test_set_brightness_read_modify_write(ble):
    ble.reads[P.DISPLAY_CHAR_UUID] = b"8|50"
    with LedTicker() as d:
        d.set_brightness(3)
    assert (P.DISPLAY_CHAR_UUID, b"3|50") in ble.writes


def test_one_shot_set_mode(ble):
    client_mod.set_mode(["stocks", "weather"])
    assert (P.MODE_CHAR_UUID, b"stocks,weather") in ble.writes


def test_one_shots_exported_at_package_level(ble):
    import led_ticker
    led_ticker.set_mode(["stocks", "weather"])
    assert (P.MODE_CHAR_UUID, b"stocks,weather") in ble.writes
    assert callable(led_ticker.get_version)


def test_failed_connect_closes_loop(monkeypatch, ble):
    monkeypatch.setattr(
        client_mod.BleakScanner, "find_device_by_filter", _async_return(None)
    )
    d = LedTicker()
    with pytest.raises(DeviceNotFoundError):
        d.__enter__()
    assert d._loop is None

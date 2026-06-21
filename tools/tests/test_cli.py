import led_ticker.cli as cli
import led_ticker.protocol as P


class FakeDevice:
    def __init__(self, recorder):
        self.r = recorder

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def set_tickers(self, symbols):
        self.r["tickers"] = symbols

    def get_status(self):
        return P.Status(text="BUSY", seconds=1800)


def test_unknown_command_prints_help_and_returns_1(capsys):
    assert cli.main(["bogus"]) == 1
    assert "Usage:" in capsys.readouterr().out


def test_tickers_dispatch_calls_library(monkeypatch):
    rec = {}
    monkeypatch.setattr(cli, "LedTicker", lambda **kw: FakeDevice(rec))
    assert cli.main(["tickers", "aapl", "msft"]) == 0
    assert rec["tickers"] == ["aapl", "msft"]


def test_validation_error_maps_to_exit_1(monkeypatch, capsys):
    # Empty ticker list is rejected by protocol.encode_tickers inside the device.
    class BadDevice(FakeDevice):
        def set_tickers(self, symbols):
            P.encode_tickers([])  # raises ValidationError

    monkeypatch.setattr(cli, "LedTicker", lambda **kw: BadDevice({}))
    assert cli.main(["tickers", "x"]) == 1
    assert "ERROR:" in capsys.readouterr().out


def test_status_get_formats_remaining(monkeypatch, capsys):
    monkeypatch.setattr(cli, "LedTicker", lambda **kw: FakeDevice({}))
    assert cli.main(["get", "status"]) == 0
    assert "30m 0s remaining" in capsys.readouterr().out


def test_pin_save_is_local_only(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli.auth, "DEFAULT_PIN_PATH", tmp_path / "pin")
    assert cli.main(["pin", "482913"]) == 0
    assert (tmp_path / "pin").read_text().strip() == "482913"


def _boom(**kw):
    raise AssertionError("LedTicker must not be constructed on a validation error")


def test_validation_happens_before_connecting(monkeypatch, capsys):
    monkeypatch.setattr(cli, "LedTicker", _boom)
    assert cli.main(["status", "a|b"]) == 1
    assert "cannot contain '|'" in capsys.readouterr().out


def test_mode_bad_token_validates_before_connecting(monkeypatch, capsys):
    monkeypatch.setattr(cli, "LedTicker", _boom)
    assert cli.main(["mode", "badtoken"]) == 1
    assert "ERROR:" in capsys.readouterr().out


def test_timer_zero_validates_before_connecting(monkeypatch, capsys):
    monkeypatch.setattr(cli, "LedTicker", _boom)
    assert cli.main(["timer", "0"]) == 1
    assert "ERROR:" in capsys.readouterr().out


# -- Fix D: --pin prefix wiring and missing-value guard ----------------------
def test_pin_prefix_passes_to_ledticker(monkeypatch):
    captured = {}

    def fake_factory(**kw):
        captured.update(kw)
        return FakeDevice(captured)

    monkeypatch.setattr(cli, "LedTicker", fake_factory)
    assert cli.main(["--pin", "123456", "tickers", "AAPL"]) == 0
    assert captured.get("pin") == "123456"


def test_pin_flag_missing_value_returns_1(capsys):
    assert cli.main(["--pin"]) == 1
    assert "ERROR:" in capsys.readouterr().out

import led_ticker.auth as auth


def test_resolve_pin_prefers_override(tmp_path, monkeypatch):
    monkeypatch.delenv("LED_TICKER_PIN", raising=False)
    assert auth.resolve_pin(" 111111 ", path=tmp_path / "pin") == "111111"


def test_resolve_pin_falls_back_to_env_then_file(tmp_path, monkeypatch):
    p = tmp_path / "pin"
    monkeypatch.setenv("LED_TICKER_PIN", "222222")
    assert auth.resolve_pin(path=p) == "222222"
    monkeypatch.delenv("LED_TICKER_PIN", raising=False)
    p.write_text("333333\n")
    assert auth.resolve_pin(path=p) == "333333"
    # Regression: env var should win when both env and file are present
    monkeypatch.setenv("LED_TICKER_PIN", "444444")
    p.write_text("555555\n")
    assert auth.resolve_pin(path=p) == "444444"


def test_resolve_pin_none_when_nothing_set(tmp_path, monkeypatch):
    monkeypatch.delenv("LED_TICKER_PIN", raising=False)
    assert auth.resolve_pin(path=tmp_path / "missing") is None


def test_save_and_clear_roundtrip(tmp_path):
    p = tmp_path / "sub" / "pin"
    auth.save_pin("482913", path=p)
    assert auth.saved_pin(path=p) == "482913"
    assert (p.stat().st_mode & 0o777) == 0o600
    assert auth.clear_pin(path=p) is True
    assert auth.saved_pin(path=p) is None
    assert auth.clear_pin(path=p) is False

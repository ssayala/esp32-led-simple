# LED Ticker — Privacy Policy

_Last updated: 2026-05-16_

This app collects no personal data. Specifically:

- **No analytics, no telemetry, no crash reporting.** Nothing about
  your use of the app is sent anywhere.
- **No account, no sign-in.**
- **No third-party SDKs.** The app talks only to (a) your LED Ticker
  hardware over Bluetooth Low Energy, and (b) the public Open-Meteo
  geocoding/weather API and Finnhub stock-quotes API — and those
  calls are made by **your LED Ticker device**, not by this app. The
  app never makes outbound network requests on its own.
- **Bluetooth permission** is used solely to discover and connect to
  your LED Ticker device. The list of devices you've paired with is
  stored only on your phone (in `UserDefaults`) and is never
  transmitted off-device.
- **WiFi credentials and your Finnhub API key**, if you set them, are
  cached in your phone's `UserDefaults` and sent to your LED Ticker
  over Bluetooth so it can do its own fetches. The WiFi password is
  not persisted on the phone.
- **The "preset chips"** on the Sign tab are stored only on your
  phone in `UserDefaults`. They are not synced anywhere.

If you delete the app, all the above is removed from your device.

---

## Contact

If you have questions about this policy, open an issue at
<https://github.com/ssayala/esp32-led-simple/issues>.

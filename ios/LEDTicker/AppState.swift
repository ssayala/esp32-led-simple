import Foundation
import Combine

struct Toast: Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

/// Shared observable state for all tabs.
///
/// The device is the source of truth for tickers, the active sign, and
/// weather locations: these start empty on launch and are populated only
/// after a successful connect + read, so the UI never shows stale or
/// fabricated defaults when disconnected. WiFi SSID and API key are
/// persisted to `UserDefaults` so the user doesn't have to retype them
/// on every launch; the WiFi password is intentionally never persisted
/// and is never exposed over BLE. Preset chip labels are also kept in
/// `UserDefaults` — they're an iOS-local convenience, not device state.
final class AppState: ObservableObject {
    @Published var ssid: String {
        didSet { UserDefaults.standard.set(ssid, forKey: Keys.ssid) }
    }
    @Published var password: String = ""
    @Published var apikey: String {
        didSet { UserDefaults.standard.set(apikey, forKey: Keys.apikey) }
    }
    @Published var tickers: [String] = []
    @Published var locations: [String] = []

    /// Currently-active sign on the device, or nil when nothing is set.
    @Published var activeStatus: ActiveStatus?

    /// Preset chip labels shown on the Status tab. Local-only — never
    /// synced to the device. Persisted to UserDefaults so the user's
    /// custom chips survive launches.
    @Published var presetTexts: [String] {
        didSet { UserDefaults.standard.set(presetTexts, forKey: Keys.presets) }
    }

    /// Sane out-of-the-box chips for first launch.
    static let defaultPresets = ["BUSY", "FOCUS", "CALL", "BRB", "LUNCH", "DND"]

    /// What the device last reported for its Mode characteristic.
    /// Drives the Display tab's status row.
    @Published var deviceMode: DeviceMode = .unknown

    /// The Categories last known to be enabled on the device. Used by
    /// DisplayTab for dirty tracking. Stays `[]` when deviceMode is
    /// `.setup` or `.unknown` — the user must explicitly pick categories.
    @Published var baselineCategories: Categories = []

    @Published var toast: Toast?

    // Baselines for dirty tracking. Set from device reads and after
    // successful writes. DeviceTab uses these to decide whether to
    // enable its Save button.
    @Published var baselineSsid: String = ""
    @Published var baselinePassword: String = ""
    @Published var baselineApiKey: String = ""

    private enum Keys {
        static let ssid    = "state.ssid"
        static let apikey  = "state.apikey"
        static let presets = "presetTexts.v1"
    }

    init() {
        let d = UserDefaults.standard
        self.ssid   = d.string(forKey: Keys.ssid) ?? ""
        self.apikey = d.string(forKey: Keys.apikey) ?? ""
        // Treat a missing key (first launch) as "use defaults", but an
        // explicitly-empty saved list as the user's choice — don't
        // re-seed defaults when they've deleted every chip.
        if let saved = d.array(forKey: Keys.presets) as? [String] {
            self.presetTexts = saved
        } else {
            self.presetTexts = AppState.defaultPresets
        }
    }

    /// Wipe all fields that come from the device. Called when the BLE
    /// connection is dropped so stale data never lingers on screen.
    /// `presetTexts` is intentionally untouched — those are user-local.
    func clearDeviceState() {
        tickers = []
        locations = []
        activeStatus = nil
        deviceMode = .unknown
        baselineCategories = []
    }

    func show(_ text: String, isError: Bool = false) {
        toast = Toast(text: text, isError: isError)
    }

    /// Fire a write and update the toast with the outcome. Also fires
    /// a success/error haptic — the device is across the room so the
    /// phone is the user's only feedback channel until they look up.
    func send(via ble: BLEManager, kind: CharKind, data: Data, label: String) {
        show("Sending \(label)…")
        ble.write(kind, data) { [weak self] err in
            guard let self else { return }
            if let err {
                self.show("\(label) failed: \(err.localizedDescription)", isError: true)
                Haptics.error()
            } else {
                self.show("\(label) sent")
                Haptics.success()
            }
        }
    }

    /// Read current configuration from the device and overwrite local
    /// fields unconditionally — an empty result means the device has
    /// nothing configured, which the UI should reflect honestly rather
    /// than silently keeping the previous values. Baselines are reset
    /// so the Save button reflects divergence from the device.
    func refreshFromDevice(via ble: BLEManager) {
        ble.readAll([.wifi, .apikey, .tickers, .status, .locations, .mode]) { [weak self] results in
            guard let self else { return }
            let ssidStr   = results[.wifi].map(Payloads.parseString)   ?? ""
            let apiKeyStr = results[.apikey].map(Payloads.parseString) ?? ""
            self.ssid = ssidStr
            self.password = ""
            self.baselineSsid = ssidStr
            self.baselinePassword = ""
            self.apikey = apiKeyStr
            self.baselineApiKey = apiKeyStr
            self.tickers      = results[.tickers].map(Payloads.parseTickers)     ?? []
            self.activeStatus = results[.status].flatMap(Payloads.parseStatus)
            self.locations    = results[.locations].map(Payloads.parseLocations) ?? []

            let mode = results[.mode].map(Payloads.parseMode) ?? .unknown
            self.deviceMode = mode
            switch mode {
            case .content(let cats): self.baselineCategories = cats
            case .setup, .unknown:   self.baselineCategories = []
            }

            self.show("Loaded from device")
        }
    }
}

import Foundation

/// A LED-Ticker the user has previously connected to. Identity is the
/// CoreBluetooth peripheral UUID (stable per phone-device pair, NOT the
/// hardware MAC). Friendly name defaults to the BLE advertised name on
/// first connect and is freely editable.
struct KnownDevice: Codable, Identifiable, Equatable {
    let id: UUID                  // CBPeripheral.identifier
    var friendlyName: String      // editable
    var advertisedName: String    // refined once if migrated as a placeholder; otherwise stable
    var lastConnected: Date       // moves on every successful (re)connect

    /// Placeholder advertised name used when iOS doesn't surface p.name
    /// at connect time, or during migration of the legacy single-UUID key.
    static let placeholderName = "LED-Ticker"

    private static let storeKey = "LEDTicker.knownDevices"
    private static let legacyKey = "LEDTicker.peripheral.id"

    /// Decode the persisted list, sorted by `lastConnected` descending.
    /// On a fresh install with the legacy single-UUID key, migrates that
    /// key into a one-element list (with placeholder names) and deletes it.
    static func load(from defaults: UserDefaults = .standard) -> [KnownDevice] {
        if let data = defaults.data(forKey: storeKey),
           let arr = try? JSONDecoder().decode([KnownDevice].self, from: data) {
            return arr.sorted { $0.lastConnected > $1.lastConnected }
        }
        // Migration: legacy single-UUID key.
        if let idStr = defaults.string(forKey: legacyKey),
           let uuid = UUID(uuidString: idStr) {
            let migrated = KnownDevice(
                id: uuid,
                friendlyName: placeholderName,
                advertisedName: placeholderName,
                lastConnected: .distantPast
            )
            save([migrated], to: defaults)
            defaults.removeObject(forKey: legacyKey)
            return [migrated]
        }
        return []
    }

    /// Encode and persist a (possibly unsorted) list. Sorts MRU-first
    /// before writing so subsequent loads see a stable order.
    static func save(_ devices: [KnownDevice], to defaults: UserDefaults = .standard) {
        let sorted = devices.sorted { $0.lastConnected > $1.lastConnected }
        if let data = try? JSONEncoder().encode(sorted) {
            defaults.set(data, forKey: storeKey)
        }
    }
}

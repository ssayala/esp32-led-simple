import Foundation

/// Category bitmask — 1:1 with the firmware's BIT_STOCKS/WEATHER/CLOCK.
/// Encoded on the wire as "all", a single token, or a comma-joined subset.
/// Bit 1 (the old "messages" bit) is intentionally skipped so any persisted
/// UserDefaults values from an earlier app version still decode unchanged.
struct Categories: OptionSet, Hashable {
    let rawValue: UInt8
    init(rawValue: UInt8) { self.rawValue = rawValue }

    static let stocks  = Categories(rawValue: 1 << 0)
    static let weather = Categories(rawValue: 1 << 2)
    static let clock   = Categories(rawValue: 1 << 3)

    static let all: Categories = [.stocks, .weather, .clock]
}

/// What the device reports for the Mode characteristic.
/// - `.content(set)` while scrolling categories
/// - `.setup` while in MODE_SETUP (firmware shows a configuration hint)
/// - `.unknown` for empty / NUL / unparseable payloads
enum DeviceMode: Equatable {
    case content(Categories)
    case setup
    case unknown
}

enum PayloadError: Error, Equatable, CustomStringConvertible {
    case empty(field: String)
    case tooLong(field: String, limit: Int, actual: Int)
    case invalidSSID
    case invalidLocation(String)
    case invalidStatusText(String)

    var description: String {
        switch self {
        case .empty(let f):
            return "\(f) cannot be empty"
        case .tooLong(let f, let limit, let actual):
            return "\(f) too long: \(actual) > \(limit) bytes"
        case .invalidSSID:
            return "SSID is empty, too long, or contains '|'"
        case .invalidLocation(let l):
            return "Location '\(l)' is empty, too long, or contains '|'"
        case .invalidStatusText(let t):
            return "Status text '\(t)' cannot contain '|'"
        }
    }
}

/// Active sign state read back from the device. `nil` `secondsRemaining`
/// means the sign is set indefinitely (or the device coerced a pre-NTP
/// timed write to indefinite because it had no valid epoch yet).
struct ActiveStatus: Equatable {
    var text: String
    /// nil = indefinite, otherwise seconds remaining at the moment of read.
    var secondsRemaining: UInt32?
}

/// Pure payload-formatting layer that mirrors `tools/led.py`.
/// Kept free of CoreBluetooth so it can be unit tested on any platform.
enum Payloads {
    static let wifiSsidMaxBytes = 63
    static let apiKeyMaxBytes = 63
    static let tickerMaxCount = 10
    static let tickerMaxLen = 15
    // Locations: firmware enforces MAX_LOCATIONS=5, MAX_LOCATION_LEN=40
    // (including NUL), and the led.py guard rejects payloads ≥ 205 bytes
    // (5 * (40+1)). We mirror the same limits here.
    static let locationMaxCount = 5
    static let locationMaxLen = 39
    static let locationsMaxBytes = 204
    // Status: firmware STATUS_MAX_LEN is 96 (incl. NUL), so 95 bytes of text.
    static let statusTextMaxBytes = 95

    static func wifi(ssid: String, password: String) throws -> Data {
        let s = ssid.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.contains("|"), s.utf8.count <= wifiSsidMaxBytes else {
            throw PayloadError.invalidSSID
        }
        return Data("\(s)|\(password)".utf8)
    }

    static func apiKey(_ key: String) throws -> Data {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { throw PayloadError.empty(field: "API key") }
        guard k.utf8.count <= apiKeyMaxBytes else {
            throw PayloadError.tooLong(field: "API key", limit: apiKeyMaxBytes, actual: k.utf8.count)
        }
        return Data(k.utf8)
    }

    /// Parses a comma-separated ticker string, uppercases, trims, dedupes order-preserving.
    static func tickers(fromCSV csv: String) throws -> Data {
        let list = csv.split(separator: ",").map { String($0) }
        return try tickers(list)
    }

    static func tickers(_ list: [String]) throws -> Data {
        var seen = Set<String>()
        var cleaned: [String] = []
        for raw in list {
            let t = raw.trimmingCharacters(in: .whitespaces).uppercased()
            guard !t.isEmpty, t.utf8.count <= tickerMaxLen, seen.insert(t).inserted else { continue }
            cleaned.append(t)
            if cleaned.count == tickerMaxCount { break }
        }
        guard !cleaned.isEmpty else { throw PayloadError.empty(field: "Tickers") }
        return Data(cleaned.joined(separator: ",").utf8)
    }

    /// Pipe-separated weather locations — zip codes or "City, State"
    /// strings. Firmware resolves each to coordinates via Open-Meteo.
    static func locations(fromJoined joined: String) throws -> Data {
        let list = joined.split(separator: "|", omittingEmptySubsequences: false).map { String($0) }
        return try locations(list)
    }

    static func locations(_ list: [String]) throws -> Data {
        let cleaned = list
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw PayloadError.empty(field: "Locations") }
        for loc in cleaned {
            if loc.contains("|") || loc.utf8.count > locationMaxLen {
                throw PayloadError.invalidLocation(loc)
            }
        }
        let capped = Array(cleaned.prefix(locationMaxCount))
        let joined = capped.joined(separator: "|")
        let bytes = joined.utf8.count
        guard bytes <= locationsMaxBytes else {
            throw PayloadError.tooLong(field: "Locations", limit: locationsMaxBytes, actual: bytes)
        }
        return Data(joined.utf8)
    }

    static func parseLocations(_ data: Data) -> [String] {
        let raw = parseString(data)
        guard !raw.isEmpty else { return [] }
        return raw
            .split(separator: "|", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Encode a non-empty Categories set. Throws on empty (firmware ignores empty-mask writes anyway).
    /// Output is stable: matches the firmware's `formatModeName()` byte-for-byte.
    static func mode(_ c: Categories) throws -> Data {
        guard !c.isEmpty else { throw PayloadError.empty(field: "Mode") }
        if c == .all { return Data("all".utf8) }
        // Explicit canonical order — OptionSet itself is unordered.
        var tokens: [String] = []
        if c.contains(.stocks)  { tokens.append("stocks") }
        if c.contains(.weather) { tokens.append("weather") }
        if c.contains(.clock)   { tokens.append("clock") }
        return Data(tokens.joined(separator: ",").utf8)
    }

    static func command(_ cmd: String) -> Data {
        Data(cmd.utf8)
    }

    // MARK: - Parsers for values read back from the device

    /// Decode a characteristic value as UTF-8, trimming any trailing NULs
    /// the firmware may have left from its fixed-size buffers.
    static func parseString(_ data: Data) -> String {
        let trimmed = data.prefix { $0 != 0 }
        return String(data: Data(trimmed), encoding: .utf8) ?? ""
    }

    /// Parse a comma-separated ticker list as written by the firmware.
    static func parseTickers(_ data: Data) -> [String] {
        let raw = parseString(data)
        guard !raw.isEmpty else { return [] }
        return raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
    }

    /// Decode the Mode characteristic value. Mirrors the firmware's
    /// `parseModePayload()`: unknown tokens reject the whole payload.
    /// `"setup"` is read-only (firmware never accepts it as a write).
    static func parseMode(_ data: Data) -> DeviceMode {
        let raw = parseString(data)
        if raw.isEmpty { return .unknown }
        if raw == "all" { return .content(.all) }
        if raw == "setup" { return .setup }
        var c: Categories = []
        // omittingEmptySubsequences: true mirrors the firmware's `strtok`,
        // which skips consecutive/leading/trailing commas (e.g. "stocks,"
        // is accepted as [.stocks] rather than rejected as malformed).
        for piece in raw.split(separator: ",", omittingEmptySubsequences: true) {
            let tok = piece.trimmingCharacters(in: .whitespaces)
            switch tok {
            case "stocks":  c.insert(.stocks)
            case "weather": c.insert(.weather)
            case "clock":   c.insert(.clock)
            default: return .unknown
            }
        }
        return c.isEmpty ? .unknown : .content(c)
    }

    // MARK: - Status (active sign)

    /// Encode a write to the Status characteristic. Empty/whitespace text
    /// throws — use `statusClear()` to clear the sign instead.
    /// `durationSeconds == 0` means indefinite.
    static func status(text: String, durationSeconds: UInt32) throws -> Data {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { throw PayloadError.empty(field: "Status") }
        guard !t.contains("|") else { throw PayloadError.invalidStatusText(t) }
        guard t.utf8.count <= statusTextMaxBytes else {
            throw PayloadError.tooLong(field: "Status", limit: statusTextMaxBytes, actual: t.utf8.count)
        }
        return Data("\(t)|\(durationSeconds)".utf8)
    }

    /// Empty write clears any active status on the device.
    static func statusClear() -> Data { Data() }

    /// Parse the Status characteristic value. Returns nil when nothing is
    /// active. Mirrors the firmware's `text|seconds` format; defensively
    /// handles a missing separator (treated as indefinite).
    static func parseStatus(_ data: Data) -> ActiveStatus? {
        let s = parseString(data)
        guard !s.isEmpty else { return nil }
        guard let pipe = s.lastIndex(of: "|") else {
            return ActiveStatus(text: s, secondsRemaining: nil)
        }
        let text = String(s[..<pipe])
        let tail = s[s.index(after: pipe)...]
        let secs = UInt32(tail) ?? 0
        return ActiveStatus(text: text, secondsRemaining: secs == 0 ? nil : secs)
    }
}

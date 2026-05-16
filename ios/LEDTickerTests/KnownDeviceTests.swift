import XCTest
@testable import LEDTicker

final class KnownDeviceTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "KnownDeviceTests.suite"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeDevice(name: String, lastConnected: Date = Date()) -> KnownDevice {
        KnownDevice(
            id: UUID(),
            friendlyName: name,
            advertisedName: "LED-Ticker-XX",
            lastConnected: lastConnected
        )
    }

    // MARK: - Round trip

    func test_load_emptyDefaults_returnsEmpty() {
        XCTAssertEqual(KnownDevice.load(from: defaults), [])
    }

    func test_save_then_load_roundTrip() {
        let a = makeDevice(name: "Office",  lastConnected: Date(timeIntervalSinceNow: -10))
        let b = makeDevice(name: "Kitchen", lastConnected: Date())
        KnownDevice.save([a, b], to: defaults)
        let loaded = KnownDevice.load(from: defaults)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(Set(loaded.map(\.friendlyName)), ["Office", "Kitchen"])
        XCTAssertEqual(Set(loaded.map(\.id)), [a.id, b.id])
    }

    func test_load_sortsByLastConnectedDescending() {
        let older = makeDevice(name: "Older", lastConnected: Date(timeIntervalSinceNow: -3600))
        let newer = makeDevice(name: "Newer", lastConnected: Date())
        // Save out of order.
        KnownDevice.save([older, newer], to: defaults)
        let loaded = KnownDevice.load(from: defaults)
        XCTAssertEqual(loaded.map(\.friendlyName), ["Newer", "Older"])
    }

    // MARK: - Migration

    func test_migration_legacyKeyConvertedToList() {
        let uuid = UUID()
        defaults.set(uuid.uuidString, forKey: "LEDTicker.peripheral.id")
        let loaded = KnownDevice.load(from: defaults)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, uuid)
        XCTAssertEqual(loaded[0].friendlyName, KnownDevice.placeholderName)
        XCTAssertEqual(loaded[0].advertisedName, KnownDevice.placeholderName)
        XCTAssertEqual(loaded[0].lastConnected, .distantPast)
        // Legacy key removed after migration.
        XCTAssertNil(defaults.string(forKey: "LEDTicker.peripheral.id"))
    }

    func test_migration_newArrayWinsOverLegacyKey() {
        let oldUUID = UUID()
        defaults.set(oldUUID.uuidString, forKey: "LEDTicker.peripheral.id")
        let newDevice = makeDevice(name: "Real")
        KnownDevice.save([newDevice], to: defaults)

        let loaded = KnownDevice.load(from: defaults)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].friendlyName, "Real")
        XCTAssertNotEqual(loaded[0].id, oldUUID)
    }

    func test_migration_legacyKeyWithInvalidUUID_ignored() {
        defaults.set("not-a-uuid", forKey: "LEDTicker.peripheral.id")
        XCTAssertEqual(KnownDevice.load(from: defaults), [])
    }

    func test_save_persistsMRUOrder() {
        // save() must sort the array before writing, so a subsequent
        // load returns MRU-first regardless of input order.
        let older = makeDevice(name: "Older", lastConnected: Date(timeIntervalSinceNow: -3600))
        let newer = makeDevice(name: "Newer", lastConnected: Date())
        KnownDevice.save([older, newer], to: defaults)
        let loaded = KnownDevice.load(from: defaults)
        XCTAssertEqual(loaded.first?.friendlyName, "Newer")
    }
}

import Foundation
import CoreBluetooth

enum CharKind: String, CaseIterable {
    case tickers   = "BEB5483E-36E1-4688-B7F5-EA07361B26A8"
    case mode      = "BEB5483E-36E1-4688-B7F5-EA07361B26A9"
    case messages  = "BEB5483E-36E1-4688-B7F5-EA07361B26AA"
    case command   = "BEB5483E-36E1-4688-B7F5-EA07361B26AB"
    case wifi      = "BEB5483E-36E1-4688-B7F5-EA07361B26AC"
    case apikey    = "BEB5483E-36E1-4688-B7F5-EA07361B26AD"
    case locations = "BEB5483E-36E1-4688-B7F5-EA07361B26AE"

    var uuid: CBUUID { CBUUID(string: rawValue) }
}

enum ConnectionState: Equatable {
    case idle
    case poweredOff
    case unauthorized
    case scanning
    case connecting
    case discovering
    case ready
    case failed(String)
}

/// CoreBluetooth wrapper for the LED-Ticker switcher model.
///
/// One active connection at a time. Surfaces the list of remembered
/// devices (`knownDevices`), the currently active one (`activeDevice`),
/// and a set of peripheral UUIDs seen in the last ~10 seconds
/// (`inRange`). Identity is `CBPeripheral.identifier`; friendly names
/// live on `KnownDevice` and are iOS-local.
final class BLEManager: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "4FAFC201-1FB5-459E-8FCC-C5C9C331914B")

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var activeDevice: KnownDevice?
    @Published private(set) var knownDevices: [KnownDevice] = []
    @Published private(set) var inRange: Set<UUID> = []
    /// Last advertised name seen for each in-range peripheral. Lets the
    /// UI distinguish multiple un-enrolled "LED-Ticker-XXXX" devices in
    /// the Nearby section without needing to connect first. Pruned in
    /// lockstep with `inRange` when entries expire.
    @Published private(set) var advertisedNames: [UUID: String] = [:]

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [CharKind: CBCharacteristic] = [:]

    private var scanTimeoutWork: DispatchWorkItem?
    private static let scanTimeout: TimeInterval = 15
    private static let inRangeTTL: TimeInterval = 10
    private var inRangeExpiry: [UUID: DispatchWorkItem] = [:]

    /// One-shot "connect when discovered" target. Set by connect() when
    /// the target peripheral isn't currently known to CoreBluetooth.
    /// Cleared by didDiscover on match or by the timeout.
    private var pendingConnect: (id: UUID, work: DispatchWorkItem)?

    /// If the user taps a different known device while one is active,
    /// the disconnect is async. Stash the next target here and the
    /// `didDisconnect` callback will call connect() on it.
    private var pendingNextConnect: KnownDevice?

    private var didAutoConnect = false

    private struct PendingWrite {
        let kind: CharKind
        let data: Data
        let completion: (Error?) -> Void
    }
    private var writeQueue: [PendingWrite] = []
    private var writing = false

    private struct PendingRead {
        let kind: CharKind
        let completion: (Result<Data, Error>) -> Void
    }
    private var readQueue: [PendingRead] = []
    private var reading = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        knownDevices = KnownDevice.load()
    }

    // MARK: - Scan

    /// Start a service-UUID scan. Times out after 15s. Updates `inRange`
    /// from `didDiscover`; never auto-connects from a bare scan.
    func scan() {
        guard central.state == .poweredOn else { return }
        cancelScanTimeout()
        // Allow scanning from idle and from a prior failure (e.g. a
        // tryAutoConnect that timed out). Don't clobber an active or
        // in-flight connection state.
        switch state {
        case .idle, .failed: state = .scanning
        default: break
        }
        central.scanForPeripherals(withServices: [Self.serviceUUID])
        let work = DispatchWorkItem { [weak self] in self?.stopScan() }
        scanTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanTimeout, execute: work)
    }

    func stopScan() {
        cancelScanTimeout()
        central.stopScan()
        if case .scanning = state { state = .idle }
    }

    private func cancelScanTimeout() {
        scanTimeoutWork?.cancel()
        scanTimeoutWork = nil
    }

    // MARK: - Connect / Disconnect

    /// Connect to a known device. Disconnects the current one first if
    /// the target differs. If the target isn't currently known to
    /// CoreBluetooth, starts a scan and connects when it appears.
    func connect(_ device: KnownDevice) {
        // If we're already attached to any peripheral that isn't the
        // target, route through disconnect-then-connect. `peripheral`
        // (not `activeDevice`) is the authoritative "already attached"
        // signal — `activeDevice` is only set after characteristic
        // discovery completes, so it's nil during .connecting /
        // .discovering when peripheral is non-nil.
        if let existing = peripheral, existing.identifier != device.id {
            pendingNextConnect = device
            disconnectInternal()
            return
        }
        if activeDevice?.id == device.id, state == .ready {
            return // no-op: already connected to this device
        }
        cancelPendingConnect()

        // Fast path: CB already knows this peripheral.
        if let known = central.retrievePeripherals(withIdentifiers: [device.id]).first {
            attachAndConnect(known)
            return
        }

        // Slow path: scan and match.
        let target = device.id
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Belt-and-braces: if the pending entry has been replaced
            // (user tapped a different device, or a successful match
            // already fired), don't clobber state.
            guard self.pendingConnect?.id == target else { return }
            self.cancelPendingConnect()
            self.state = .failed("Device not found")
        }
        pendingConnect = (target, timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanTimeout, execute: timeout)
        if state != .scanning { scan() }
    }

    func disconnect() {
        pendingNextConnect = nil
        disconnectInternal()
    }

    private func disconnectInternal() {
        cancelPendingConnect()
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        // `didDisconnect` clears state and may run a pendingNextConnect.
    }

    private func attachAndConnect(_ p: CBPeripheral) {
        cancelScanTimeout()
        central.stopScan()
        peripheral = p
        p.delegate = self
        // Set activeDevice provisionally so the UI can show the
        // in-flight connection during .connecting/.discovering.
        // upsertKnownAfterConnect re-assigns with the persisted record
        // on success (refreshed lastConnected, refined names).
        if let existing = knownDevices.first(where: { $0.id == p.identifier }) {
            activeDevice = existing
        } else {
            let advertised = (p.name?.isEmpty == false) ? p.name! : KnownDevice.placeholderName
            activeDevice = KnownDevice(
                id: p.identifier,
                friendlyName: advertised,
                advertisedName: advertised,
                lastConnected: Date()
            )
        }
        state = .connecting
        central.connect(p)
    }

    private func cancelPendingConnect() {
        pendingConnect?.work.cancel()
        pendingConnect = nil
    }

    // MARK: - Known list mutations

    func forget(_ device: KnownDevice) {
        if activeDevice?.id == device.id {
            disconnectInternal()
            // Clear activeDevice synchronously so it doesn't briefly
            // point at a KnownDevice that's already gone from the list.
            // didDisconnect runs later and is a no-op on activeDevice.
            activeDevice = nil
        }
        knownDevices.removeAll { $0.id == device.id }
        KnownDevice.save(knownDevices)
    }

    func rename(_ device: KnownDevice, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let idx = knownDevices.firstIndex(where: { $0.id == device.id }) else { return }
        knownDevices[idx].friendlyName = trimmed
        if activeDevice?.id == device.id {
            activeDevice = knownDevices[idx]
        }
        KnownDevice.save(knownDevices)
    }

    func tryAutoConnect() {
        guard !didAutoConnect else { return }
        didAutoConnect = true
        guard let target = knownDevices.first else { return }
        connect(target)
    }

    // MARK: - In-range tracking

    private func markInRange(_ id: UUID, advertisedName: String?) {
        inRange.insert(id)
        if let name = advertisedName, !name.isEmpty {
            advertisedNames[id] = name
        }
        inRangeExpiry[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.inRange.remove(id)
            self?.advertisedNames[id] = nil
            self?.inRangeExpiry[id] = nil
        }
        inRangeExpiry[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.inRangeTTL, execute: work)
    }

    // MARK: - Known list refinement on discovery

    private func refineKnownFromDiscovery(_ p: CBPeripheral) {
        guard let idx = knownDevices.firstIndex(where: { $0.id == p.identifier }) else { return }
        guard let name = p.name, !name.isEmpty,
              knownDevices[idx].advertisedName == KnownDevice.placeholderName,
              name != KnownDevice.placeholderName else { return }
        // Refine placeholder advertisedName from the real p.name. Also
        // refine friendlyName ONLY if the user hasn't customized it
        // (i.e. it still matches the placeholder advertisedName).
        if knownDevices[idx].friendlyName == knownDevices[idx].advertisedName {
            knownDevices[idx].friendlyName = name
        }
        knownDevices[idx].advertisedName = name
        if activeDevice?.id == p.identifier {
            activeDevice = knownDevices[idx]
        }
        KnownDevice.save(knownDevices)
    }

    private func upsertKnownAfterConnect(_ p: CBPeripheral) -> KnownDevice {
        let advertised = (p.name?.isEmpty == false) ? p.name! : KnownDevice.placeholderName
        if let idx = knownDevices.firstIndex(where: { $0.id == p.identifier }) {
            // Existing entry: refresh lastConnected, optionally refine names.
            knownDevices[idx].lastConnected = Date()
            if knownDevices[idx].advertisedName == KnownDevice.placeholderName,
               advertised != KnownDevice.placeholderName {
                if knownDevices[idx].friendlyName == knownDevices[idx].advertisedName {
                    knownDevices[idx].friendlyName = advertised
                }
                knownDevices[idx].advertisedName = advertised
            }
            KnownDevice.save(knownDevices)
            return knownDevices[idx]
        }
        // New enrollment (e.g. user tapped a "Nearby" row).
        let new = KnownDevice(
            id: p.identifier,
            friendlyName: advertised,
            advertisedName: advertised,
            lastConnected: Date()
        )
        knownDevices.append(new)
        KnownDevice.save(knownDevices)
        return new
    }

    // MARK: - Read / Write (unchanged behavior)

    func write(_ kind: CharKind, _ data: Data, completion: @escaping (Error?) -> Void = { _ in }) {
        guard case .ready = state else {
            completion(NSError(domain: "LEDTicker", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "not connected"]))
            return
        }
        writeQueue.append(PendingWrite(kind: kind, data: data, completion: completion))
        pumpWriteQueue()
    }

    func read(_ kind: CharKind, completion: @escaping (Result<Data, Error>) -> Void) {
        guard case .ready = state else {
            completion(.failure(NSError(domain: "LEDTicker", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "not connected"])))
            return
        }
        readQueue.append(PendingRead(kind: kind, completion: completion))
        pumpReadQueue()
    }

    func readAll(_ kinds: [CharKind],
                 completion: @escaping ([CharKind: Data]) -> Void) {
        var results: [CharKind: Data] = [:]
        var remaining = kinds
        func step() {
            guard !remaining.isEmpty else {
                completion(results)
                return
            }
            let k = remaining.removeFirst()
            read(k) { result in
                if case .success(let data) = result { results[k] = data }
                step()
            }
        }
        step()
    }

    private func pumpWriteQueue() {
        guard !writing, let p = peripheral, let next = writeQueue.first else { return }
        guard let ch = characteristics[next.kind] else {
            writeQueue.removeFirst()
            next.completion(NSError(domain: "LEDTicker", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "characteristic \(next.kind) not ready"]))
            pumpWriteQueue()
            return
        }
        writing = true
        p.writeValue(next.data, for: ch, type: .withResponse)
    }

    private func pumpReadQueue() {
        guard !reading, let p = peripheral, let next = readQueue.first else { return }
        guard let ch = characteristics[next.kind] else {
            readQueue.removeFirst()
            next.completion(.failure(NSError(domain: "LEDTicker", code: -2,
                                             userInfo: [NSLocalizedDescriptionKey: "characteristic \(next.kind) not ready"])))
            pumpReadQueue()
            return
        }
        reading = true
        p.readValue(for: ch)
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:    state = .idle
        case .poweredOff:   state = .poweredOff
        case .unauthorized: state = .unauthorized
        case .unsupported:  state = .failed("Bluetooth LE unsupported")
        default:            state = .idle
        }
    }

    func centralManager(_ c: CBCentralManager,
                        didDiscover p: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi: NSNumber) {
        // Prefer the per-advertisement local name when present (it's the
        // value the firmware emitted this packet); fall back to p.name
        // for the cached GAP name.
        let advertised = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        markInRange(p.identifier, advertisedName: advertised)
        refineKnownFromDiscovery(p)
        // Connect-when-discovered fires the pending one-shot callback.
        if let pending = pendingConnect, pending.id == p.identifier {
            pending.work.cancel()
            pendingConnect = nil
            attachAndConnect(p)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        state = .discovering
        p.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ c: CBCentralManager,
                        didFailToConnect p: CBPeripheral,
                        error: Error?) {
        // Mirror didDisconnect's cleanup so a later connect() doesn't
        // try to cancel a peripheral that never finished connecting.
        peripheral = nil
        characteristics.removeAll()
        activeDevice = nil
        state = .failed(error?.localizedDescription ?? "connect failed")
    }

    func centralManager(_ c: CBCentralManager,
                        didDisconnectPeripheral p: CBPeripheral,
                        error: Error?) {
        characteristics.removeAll()
        peripheral = nil
        activeDevice = nil
        writeQueue.removeAll()
        writing = false
        readQueue.removeAll()
        reading = false
        if let err = error {
            state = .failed(err.localizedDescription)
        } else {
            state = .idle
        }
        // If the user queued a switch while a previous device was still
        // disconnecting, run it now.
        if let next = pendingNextConnect {
            pendingNextConnect = nil
            connect(next)
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            state = .failed("service not found")
            return
        }
        p.discoverCharacteristics(CharKind.allCases.map(\.uuid), for: svc)
    }

    func peripheral(_ p: CBPeripheral,
                    didDiscoverCharacteristicsFor svc: CBService,
                    error: Error?) {
        for ch in svc.characteristics ?? [] {
            if let kind = CharKind.allCases.first(where: { $0.uuid == ch.uuid }) {
                characteristics[kind] = ch
            }
        }
        if characteristics.count == CharKind.allCases.count {
            activeDevice = upsertKnownAfterConnect(p)
            state = .ready
        } else {
            state = .failed("missing characteristics (\(characteristics.count)/\(CharKind.allCases.count))")
        }
    }

    func peripheral(_ p: CBPeripheral,
                    didWriteValueFor ch: CBCharacteristic,
                    error: Error?) {
        writing = false
        if !writeQueue.isEmpty {
            let done = writeQueue.removeFirst()
            done.completion(error)
        }
        pumpWriteQueue()
    }

    func peripheral(_ p: CBPeripheral,
                    didUpdateValueFor ch: CBCharacteristic,
                    error: Error?) {
        reading = false
        if !readQueue.isEmpty {
            let done = readQueue.removeFirst()
            if let err = error {
                done.completion(.failure(err))
            } else {
                done.completion(.success(ch.value ?? Data()))
            }
        }
        pumpReadQueue()
    }
}

import Foundation
import CoreBluetooth

enum CharKind: String, CaseIterable {
    case tickers   = "BEB5483E-36E1-4688-B7F5-EA07361B26A8"
    case mode      = "BEB5483E-36E1-4688-B7F5-EA07361B26A9"
    // 26AA was the legacy "Messages" characteristic. The firmware no
    // longer registers it (the UUID is reserved as a tombstone); do not
    // reuse it.
    case command   = "BEB5483E-36E1-4688-B7F5-EA07361B26AB"
    case wifi      = "BEB5483E-36E1-4688-B7F5-EA07361B26AC"
    case apikey    = "BEB5483E-36E1-4688-B7F5-EA07361B26AD"
    case locations = "BEB5483E-36E1-4688-B7F5-EA07361B26AE"
    case status    = "BEB5483E-36E1-4688-B7F5-EA07361B26AF"

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

    /// True while a view (the Device tab) wants continuous ambient
    /// discovery — we scan with `allowDuplicates: true` so each
    /// repeated advertisement refreshes the in-range TTL, keeping the
    /// "in range" badge stable instead of flapping after CoreBluetooth's
    /// first-discovery dedup kicks in.
    private var ambientScanRequested = false
    /// Edge-tracker for the underlying CB scan so reconcileScan() only
    /// calls `scanForPeripherals` / `stopScan` on transitions, not on
    /// every state notification.
    private var scanActive = false
    private static let pendingConnectTimeout: TimeInterval = 15
    private static let inRangeTTL: TimeInterval = 10
    /// Most-recent advertisement timestamp per peripheral. With
    /// `allowDuplicates: true` we get ~10 ads/sec/device; one shared
    /// prune timer is much cheaper than a per-id DispatchWorkItem that
    /// gets cancelled and rescheduled on every ad.
    private var lastSeen: [UUID: Date] = [:]
    private static let prunePollInterval: TimeInterval = 2
    private var pruneTimer: Timer?

    /// One-shot "connect when discovered" target. Set by connect() when
    /// the target peripheral isn't currently known to CoreBluetooth.
    /// Cleared by didDiscover on match or by the timeout.
    private var pendingConnect: (id: UUID, work: DispatchWorkItem)?

    /// If the user taps a different known device while one is active,
    /// the disconnect is async. Stash the next target here and the
    /// `didDisconnect` callback will call connect() on it.
    private var pendingNextConnect: KnownDevice?

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

    /// Request continuous ambient discovery. The Device tab calls this
    /// on appear; pair with `stopAmbientScan()` on disappear. Idempotent.
    /// The scan itself is started/stopped by `reconcileScan()` based on
    /// this flag plus the current connection state.
    func startAmbientScan() {
        ambientScanRequested = true
        reconcileScan()
    }

    func stopAmbientScan() {
        ambientScanRequested = false
        reconcileScan()
    }

    /// Single source of truth for whether `scanForPeripherals` is active.
    /// Call after any event that could change the answer: ambient flag,
    /// pending-connect set/clear, BLE power, connection state transitions.
    /// Edge-triggered — only hits CoreBluetooth on transitions.
    ///
    /// `allowDuplicates: true` is intentional — without it, CoreBluetooth
    /// only fires `didDiscover` once per peripheral per scan session, so
    /// the in-range TTL would expire and never be refreshed even when
    /// the device is still advertising right next to us.
    private func reconcileScan() {
        guard central.state == .poweredOn else { return }
        let wantScan = !isConnectionInFlight
            && (ambientScanRequested || pendingConnect != nil)
        if wantScan, !scanActive {
            central.scanForPeripherals(
                withServices: [Self.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
            scanActive = true
            switch state {
            case .idle, .failed: state = .scanning
            default: break
            }
        } else if !wantScan, scanActive {
            central.stopScan()
            scanActive = false
            if case .scanning = state { state = .idle }
        }
    }

    /// Force a fresh CoreBluetooth scan session — stop and immediately
    /// restart the scan if ambient is requested. Recovers from the rare
    /// case where the underlying CB scan gets wedged (no `didDiscover`
    /// events for a long time even though devices are advertising).
    /// Called from the Device tab's pull-to-refresh.
    func restartAmbientScan() {
        guard ambientScanRequested else { return }
        if scanActive {
            central.stopScan()
            scanActive = false
        }
        reconcileScan()
    }

    /// True only while the BLE handshake is in motion — scanning during
    /// `.connecting` / `.discovering` can destabilize the connection.
    /// Once we're fully `.ready`, ambient scan resumes so the Device
    /// tab can keep showing other in-range LED-Tickers (CoreBluetooth
    /// is fine running a scan alongside an active connection; the
    /// connected peripheral just won't appear in didDiscover).
    private var isConnectionInFlight: Bool {
        switch state {
        case .connecting, .discovering: return true
        default:                        return false
        }
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
            // If the Device tab is still requesting ambient discovery,
            // resume it after the slow-path scan ends in failure.
            self.reconcileScan()
        }
        pendingConnect = (target, timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pendingConnectTimeout, execute: timeout)
        reconcileScan()
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
        // Transitioning to .connecting; reconcileScan() will stop the
        // active scan (CoreBluetooth doesn't deliver ads for the
        // peripheral we're connecting to anyway).
        reconcileScan()
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

    // MARK: - In-range tracking

    /// Called from `didDiscover` on every advertisement — with
    /// `allowDuplicates: true` this runs ~10×/sec/device. Hot path:
    /// guard every `@Published` write against a no-op so we don't
    /// notify SwiftUI on values that didn't change, and refresh a
    /// plain `Date` instead of cancelling-and-rescheduling a per-id
    /// DispatchWorkItem. One shared prune timer runs at 2 Hz and
    /// retires entries that haven't been seen for `inRangeTTL`.
    private func markInRange(_ id: UUID, advertisedName: String?) {
        lastSeen[id] = Date()
        if !inRange.contains(id) {
            inRange.insert(id)
        }
        if let name = advertisedName, !name.isEmpty, advertisedNames[id] != name {
            advertisedNames[id] = name
        }
        startPruneTimerIfNeeded()
    }

    private func startPruneTimerIfNeeded() {
        guard pruneTimer == nil, !lastSeen.isEmpty else { return }
        pruneTimer = Timer.scheduledTimer(
            withTimeInterval: Self.prunePollInterval, repeats: true
        ) { [weak self] _ in
            self?.pruneInRange()
        }
    }

    /// Sweep `lastSeen` and drop anything older than the TTL. Mutates
    /// the `@Published` sets only when something actually changes so
    /// idle scans don't keep waking SwiftUI.
    private func pruneInRange() {
        let cutoff = Date().addingTimeInterval(-Self.inRangeTTL)
        var stale: [UUID] = []
        for (id, when) in lastSeen where when < cutoff {
            stale.append(id)
        }
        for id in stale {
            lastSeen.removeValue(forKey: id)
            if inRange.contains(id) { inRange.remove(id) }
            if advertisedNames[id] != nil { advertisedNames[id] = nil }
        }
        if lastSeen.isEmpty {
            pruneTimer?.invalidate()
            pruneTimer = nil
        }
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
        // BLE came online (or went away) — re-evaluate whether to be
        // scanning so an ambient request issued before powerOn lands
        // as soon as we're allowed to scan.
        reconcileScan()
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
        // We're out of the .connecting in-flight state — resume ambient
        // scanning if the Device tab is still asking for it.
        reconcileScan()
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
        // disconnecting, run it now. Otherwise resume ambient scan.
        if let next = pendingNextConnect {
            pendingNextConnect = nil
            connect(next)
        } else {
            reconcileScan()
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
        // We've left the in-flight discovery phase. On .ready we want
        // scanning off; on .failed we want ambient to resume.
        reconcileScan()
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

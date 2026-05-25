import SwiftUI

struct DeviceTab: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var app: AppState

    @State private var showResetConfirm = false
    @State private var renamingDevice: KnownDevice?
    @State private var renameDraft: String = ""
    @State private var forgettingDevice: KnownDevice?
    @State private var baselinesLoaded = false

    var body: some View {
        NavigationStack {
            Form {
                knownDevicesSection
                powerSection
                wifiSection
                apiKeySection
                resetSection
            }
            .navigationTitle("Device")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: saveDirty)
                        .disabled(!canWrite || !anyDirty)
                }
            }
            .refreshable {
                // Pull-to-refresh forces a fresh CB scan session.
                // With `allowDuplicates: true` we get continuous
                // advertisements anyway, so this is mostly cosmetic —
                // but it recovers from the rare wedged-scan case.
                ble.restartAmbientScan()
            }
            .onAppear {
                loadBaselinesIfNeeded()
                // Ambient scan runs continuously while the Device tab
                // is visible (except during an in-flight connection,
                // which BLEManager pauses internally). That keeps the
                // "in range" badge stable even when CoreBluetooth's
                // first-discovery dedup would otherwise suppress
                // subsequent ads from the same peripheral.
                ble.startAmbientScan()
            }
            .onDisappear { ble.stopAmbientScan() }
            .modifier(DeviceTabModals(
                ble: ble,
                renamingDevice: $renamingDevice,
                renameDraft: $renameDraft,
                forgettingDevice: $forgettingDevice,
                showResetConfirm: $showResetConfirm,
                onReset: {
                    // Destructive — warn before send fires so the
                    // user gets a haptic at the moment of commitment,
                    // not when the BLE round-trip completes.
                    Haptics.warning()
                    app.send(via: ble, kind: .command, data: Payloads.command("reset"), label: "Reset")
                }
            ))
        }
    }

    // MARK: - Known Devices section

    private var knownDevicesSection: some View {
        Section {
            if ble.knownDevices.isEmpty && nearbyUnknown.isEmpty {
                Text("No devices yet. Move closer to your LED-Ticker and pull to scan.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ble.knownDevices) { device in
                    deviceRow(device)
                }
                if !nearbyUnknown.isEmpty {
                    ForEach(nearbyUnknown, id: \.id) { peripheralPlaceholder in
                        nearbyRow(peripheralPlaceholder)
                    }
                }
            }
        } header: {
            Text("Known Devices").textCase(nil)
        } footer: {
            Text(footerHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func deviceRow(_ device: KnownDevice) -> some View {
        let rowState = state(for: device)
        return HStack(spacing: 12) {
            stateIcon(rowState)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.friendlyName)
                Text(statusText(rowState))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if rowState == .connected {
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { tap(device) }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            // Disconnect is only meaningful when this device is the
            // active one — hiding it on idle rows avoids a swipe action
            // that would no-op. Lets the user free the peripheral
            // (so another phone can connect) without force-quitting.
            if rowState == .connected {
                Button {
                    Haptics.tap()
                    ble.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "powerplug.fill")
                }
                .tint(.orange)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                renamingDevice = device
                renameDraft = device.friendlyName
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
            Button(role: .destructive) {
                forgettingDevice = device
            } label: {
                Label("Forget", systemImage: "trash")
            }
        }
    }

    private func nearbyRow(_ ph: NearbyPlaceholder) -> some View {
        // Synthesize a KnownDevice so state(for:) can return the
        // correct active-row state if this nearby device is mid-connect.
        let synth = KnownDevice(
            id: ph.id,
            friendlyName: ph.advertisedName,
            advertisedName: ph.advertisedName,
            lastConnected: Date()
        )
        let active = ble.activeDevice?.id == ph.id
        let rowState: RowState? = active ? state(for: synth) : nil

        return HStack(spacing: 12) {
            Group {
                if rowState == .connecting {
                    ProgressView().controlSize(.small)
                } else if rowState == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.blue)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(ph.advertisedName)
                Text(rowState.map(statusText) ?? "Tap to add")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { ble.connect(synth) }
    }

    /// Peripheral UUIDs currently in range but NOT already enrolled in
    /// knownDevices. Uses the per-UUID advertised name captured at scan
    /// time so two un-enrolled "LED-Ticker-XXXX" units are visibly
    /// distinct; falls back to the generic placeholder when iOS hasn't
    /// surfaced a name for that advertisement.
    private var nearbyUnknown: [NearbyPlaceholder] {
        let knownIDs = Set(ble.knownDevices.map(\.id))
        return ble.inRange
            .subtracting(knownIDs)
            .sorted { $0.uuidString < $1.uuidString }
            .map { id in
                NearbyPlaceholder(
                    id: id,
                    advertisedName: ble.advertisedNames[id] ?? KnownDevice.placeholderName
                )
            }
    }

    private var footerHint: String {
        if ble.state == .poweredOff { return "Bluetooth is off." }
        if ble.state == .unauthorized { return "Bluetooth permission denied." }
        if ble.knownDevices.isEmpty { return "Pull down to scan for LED-Tickers nearby." }
        return "Tap a device to connect. Swipe a row to rename or forget."
    }

    // MARK: - Row state

    private enum RowState: Equatable {
        case connected
        case connecting
        case failed
        case inRange
        case outOfRange
    }

    private func state(for device: KnownDevice) -> RowState {
        if ble.activeDevice?.id == device.id {
            switch ble.state {
            case .ready: return .connected
            case .connecting, .discovering, .scanning: return .connecting
            case .failed: return .failed
            default: break
            }
        }
        return ble.inRange.contains(device.id) ? .inRange : .outOfRange
    }

    @ViewBuilder
    private func stateIcon(_ s: RowState) -> some View {
        switch s {
        case .connected:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .connecting:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .inRange:
            Image(systemName: "circle.fill").foregroundStyle(.green).font(.caption)
        case .outOfRange:
            Image(systemName: "circle").foregroundStyle(.gray).font(.caption)
        }
    }

    private func statusText(_ s: RowState) -> String {
        switch s {
        case .connected:
            // The connected row is — by construction — the active device, so
            // `app.firmwareVersion` (populated from the Version characteristic
            // on connect) applies here. Older firmware that predates the
            // characteristic leaves it empty; in that case fall back to the
            // bare "connected" string rather than printing "v" with nothing
            // after it.
            return app.firmwareVersion.isEmpty
                ? "connected"
                : "connected · v\(app.firmwareVersion)"
        case .connecting:  return "connecting…"
        case .failed:      return "couldn't connect"
        case .inRange:     return "in range"
        case .outOfRange:  return "not in range"
        }
    }

    private func tap(_ device: KnownDevice) {
        if ble.activeDevice?.id == device.id, ble.state == .ready { return }
        ble.connect(device)
    }

    // MARK: - Existing sections

    private var wifiSection: some View {
        Section {
            TextField("SSID", text: $app.ssid)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            // The firmware never returns the password (BLE reads omit it),
            // so this field is always empty on load. The placeholder
            // shifts once we know the device has a network configured —
            // makes it clear that empty ≠ "no password set" so the user
            // doesn't second-guess what they're looking at.
            SecureField(passwordPlaceholder, text: $app.password)
        } header: {
            Text("WiFi").textCase(nil)
        } footer: {
            if !app.baselineSsid.isEmpty {
                Text("The device doesn't share its current password. Enter one only if you're changing networks or updating it.")
            }
        }
    }

    private var passwordPlaceholder: String {
        app.baselineSsid.isEmpty ? "Password" : "Enter password to change"
    }

    private var apiKeySection: some View {
        Section {
            SecureField("API Key", text: $app.apikey)
        } header: {
            Text("Finnhub API Key").textCase(nil)
        } footer: {
            Text("Get a free API key at finnhub.io")
        }
    }

    // MARK: - Power section

    /// Wrapped in `@ViewBuilder` + `if let` so the entire section
    /// disappears when the device doesn't expose a Power characteristic
    /// (firmware < 0.2.0). Power is a write-and-forget toggle — no Save
    /// button, no dirty tracking — so we update `displayPower`
    /// optimistically and roll back on BLE failure.
    @ViewBuilder
    private var powerSection: some View {
        if let current = app.displayPower {
            Section {
                Toggle("Display", isOn: Binding(
                    get: { current == .on },
                    set: { newValue in writePower(newValue ? .on : .off) }
                ))
            } header: {
                Text("Power")
            } footer: {
                Text("Turns the matrix and onboard LED off without changing your mode. Resets to on after power cycle.")
            }
        }
    }

    private func writePower(_ target: PowerState) {
        app.displayPower = target  // optimistic — refreshFromDevice corrects any drift on reconnect
        app.send(via: ble, kind: .power, data: Payloads.power(target), label: "Display")
    }

    private var resetSection: some View {
        Section {
            Button("Reset Device", role: .destructive) {
                showResetConfirm = true
            }
            .disabled(!canWrite)
        }
    }

    // MARK: - Dirty tracking (unchanged)

    private var wifiDirty: Bool {
        app.ssid != app.baselineSsid || app.password != app.baselinePassword
    }

    private var apiKeyDirty: Bool {
        app.apikey != app.baselineApiKey
    }

    private var anyDirty: Bool { wifiDirty || apiKeyDirty }

    private func loadBaselinesIfNeeded() {
        guard !baselinesLoaded else { return }
        app.baselineSsid     = app.ssid
        app.baselinePassword = app.password
        app.baselineApiKey   = app.apikey
        baselinesLoaded      = true
    }

    private var canWrite: Bool { ble.state == .ready }

    private func saveDirty() {
        if wifiDirty {
            do {
                let data = try Payloads.wifi(ssid: app.ssid, password: app.password)
                app.send(via: ble, kind: .wifi, data: data, label: "WiFi")
                app.baselineSsid = app.ssid
                app.baselinePassword = app.password
            } catch {
                app.show("WiFi: \(error)", isError: true)
                return
            }
        }
        if apiKeyDirty {
            do {
                let data = try Payloads.apiKey(app.apikey)
                app.send(via: ble, kind: .apikey, data: data, label: "API Key")
                app.baselineApiKey = app.apikey
            } catch {
                app.show("API Key: \(error)", isError: true)
                return
            }
        }
    }
}

/// Lightweight value type for the "Nearby" placeholder rows. We use
/// this rather than a fake KnownDevice because we don't want to add
/// the peripheral to `knownDevices` until the user successfully
/// connects to it.
private struct NearbyPlaceholder: Identifiable, Equatable {
    let id: UUID
    let advertisedName: String
}

/// Pulls the Rename alert, Forget dialog, and Reset dialog out of
/// DeviceTab.body's modifier chain. Keeping them in one large chain
/// causes SourceKit to report "compiler is unable to type-check this
/// expression in reasonable time" on the Form's modifier stack.
private struct DeviceTabModals: ViewModifier {
    @ObservedObject var ble: BLEManager
    @Binding var renamingDevice: KnownDevice?
    @Binding var renameDraft: String
    @Binding var forgettingDevice: KnownDevice?
    @Binding var showResetConfirm: Bool
    let onReset: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Rename device",
                   isPresented: Binding(
                    get: { renamingDevice != nil },
                    set: { if !$0 { renamingDevice = nil } })) {
                TextField("Name", text: $renameDraft)
                Button("Cancel", role: .cancel) { renamingDevice = nil }
                Button("Save") {
                    if let d = renamingDevice { ble.rename(d, to: renameDraft) }
                    renamingDevice = nil
                }
                .disabled(renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("Pick a name to identify this LED-Ticker.")
            }
            .confirmationDialog(
                forgettingDevice.map { "Forget '\($0.friendlyName)'?" } ?? "",
                isPresented: Binding(
                    get: { forgettingDevice != nil },
                    set: { if !$0 { forgettingDevice = nil } }),
                titleVisibility: .visible
            ) {
                Button("Forget", role: .destructive) {
                    if let d = forgettingDevice { ble.forget(d) }
                    forgettingDevice = nil
                }
                Button("Cancel", role: .cancel) { forgettingDevice = nil }
            } message: {
                Text("You'll need to scan to re-add it.")
            }
            .confirmationDialog(
                "Reset everything on the device?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) { onReset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Wipes WiFi, API key, tickers, weather locations, active sign, and cached data from the device. (Your local preset chips are not affected.)")
            }
    }
}

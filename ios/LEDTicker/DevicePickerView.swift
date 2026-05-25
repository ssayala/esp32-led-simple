import SwiftUI

/// Device-picker view shown on the Device tab when not connected
/// (or while connecting / failed). Lists known devices with state
/// icons, plus nearby unknown peripherals as "tap to add" rows.
/// Pull-to-refresh restarts the ambient scan; swipe actions on rows
/// rename or forget known devices.
struct DevicePickerView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var app: AppState

    @State private var renamingDevice: KnownDevice?
    @State private var renameDraft: String = ""
    @State private var forgettingDevice: KnownDevice?

    var body: some View {
        Form {
            knownDevicesSection
        }
        .navigationTitle("Devices")
        .refreshable {
            // Pull-to-refresh forces a fresh CB scan session.
            // With `allowDuplicates: true` we get continuous
            // advertisements anyway, so this is mostly cosmetic —
            // but it recovers from the rare wedged-scan case.
            ble.restartAmbientScan()
        }
        .onAppear {
            // Ambient scan runs continuously while the Device tab
            // is visible (except during an in-flight connection,
            // which BLEManager pauses internally). That keeps the
            // "in range" badge stable even when CoreBluetooth's
            // first-discovery dedup would otherwise suppress
            // subsequent ads from the same peripheral.
            ble.startAmbientScan()
        }
        .onDisappear { ble.stopAmbientScan() }
        .modifier(DevicePickerModals(
            ble: ble,
            renamingDevice: $renamingDevice,
            renameDraft: $renameDraft,
            forgettingDevice: $forgettingDevice
        ))
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
}

/// Lightweight value type for the "Nearby" placeholder rows. We use
/// this rather than a fake KnownDevice because we don't want to add
/// the peripheral to `knownDevices` until the user successfully
/// connects to it. Once they do, the row is rendered via `deviceRow`
/// instead.
private struct NearbyPlaceholder: Identifiable, Equatable {
    let id: UUID
    let advertisedName: String
}

/// Rename + Forget alerts for DevicePickerView. Lifted out of the
/// view's modifier chain to keep SwiftUI's type-checker happy on the
/// Form's modifier stack.
private struct DevicePickerModals: ViewModifier {
    @ObservedObject var ble: BLEManager
    @Binding var renamingDevice: KnownDevice?
    @Binding var renameDraft: String
    @Binding var forgettingDevice: KnownDevice?

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
    }
}

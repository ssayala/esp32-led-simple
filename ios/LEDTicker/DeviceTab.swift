import SwiftUI

struct DeviceTab: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var app: AppState

    @State private var showResetConfirm = false
    @State private var baselinesLoaded = false

    var body: some View {
        NavigationStack {
            if case .ready = ble.state {
                Form {
                    connectionSection
                    powerSection
                    wifiSection
                    apiKeySection
                    resetSection
                }
                .navigationTitle(ble.activeDevice?.friendlyName ?? "Device")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save", action: saveDirty)
                            .disabled(!canWrite || !anyDirty)
                    }
                }
                .onAppear { loadBaselinesIfNeeded() }
                .modifier(DeviceTabModals(
                    showResetConfirm: $showResetConfirm,
                    onReset: {
                        // Destructive — warn before send fires so the
                        // user gets a haptic at the moment of commitment,
                        // not when the BLE round-trip completes.
                        Haptics.warning()
                        app.send(via: ble, kind: .command, data: Payloads.command("reset"), label: "Reset")
                    }
                ))
            } else {
                DevicePickerView()
            }
        }
    }

    // MARK: - Connection section

    /// First section in the connected-state Device tab — shows which
    /// device the user is currently driving and offers a Disconnect
    /// action. Matches the iOS Settings → Bluetooth → device-detail
    /// shape: connected device prominent at top, destructive
    /// disconnect button at bottom of the section.
    private var connectionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(ble.activeDevice?.friendlyName ?? "Device")
                    .font(.body)
                if !app.firmwareVersion.isEmpty {
                    Text("Firmware v\(app.firmwareVersion)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Disconnect", role: .destructive) {
                // Reversible action — tap haptic, not warning. Reset
                // (which wipes NVS) is what warrants Haptics.warning().
                Haptics.tap()
                ble.disconnect()
            }
        } header: {
            Text("Connection").textCase(nil)
        }
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

/// Pulls the Reset dialog out of DeviceTab.body's modifier chain.
/// Keeping it in a separate ViewModifier mirrors the pattern used for
/// DevicePickerView's modals and keeps the type-checker happy if
/// future modals get added back to this view.
private struct DeviceTabModals: ViewModifier {
    @Binding var showResetConfirm: Bool
    let onReset: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
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

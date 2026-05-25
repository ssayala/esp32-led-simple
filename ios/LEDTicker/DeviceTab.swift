import SwiftUI

/// Top-level Device tab view. Switches between the device picker
/// (when not connected) and the settings view (when connected)
/// based on `ble.state`. Both child views own their own state,
/// modals, toolbar, and nav title; this shell just hosts the
/// NavigationStack.
///
/// Design rationale: see docs/superpowers/specs/2026-05-24-device-tab-split-design.md.
struct DeviceTab: View {
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        NavigationStack {
            if case .ready = ble.state {
                DeviceSettingsView()
            } else {
                DevicePickerView()
            }
        }
    }
}

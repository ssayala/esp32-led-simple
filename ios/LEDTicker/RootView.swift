import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var ble: BLEManager

    /// Track the selected tab so the empty-state "Open Device tab"
    /// button on the gated tabs can route the user back to the
    /// connect flow with a single tap.
    @State private var selectedTab: Tab = .device

    private enum Tab: Hashable {
        case device, display, stocks, weather, sign
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DeviceTab()
                .tabItem { Label("Device", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.device)

            gated(name: "Display", icon: "rectangle.on.rectangle") {
                DisplayTab()
            }
            .tabItem { Label("Display", systemImage: "rectangle.on.rectangle") }
            .tag(Tab.display)

            gated(name: "Stocks", icon: "chart.line.uptrend.xyaxis") {
                StocksTab()
            }
            .tabItem { Label("Stocks", systemImage: "chart.line.uptrend.xyaxis") }
            .tag(Tab.stocks)

            gated(name: "Weather", icon: "cloud.sun.fill") {
                WeatherTab()
            }
            .tabItem { Label("Weather", systemImage: "cloud.sun.fill") }
            .tag(Tab.weather)

            gated(name: "Sign", icon: "signpost.right") {
                StatusTab()
            }
            .tabItem { Label("Sign", systemImage: "signpost.right") }
            .tag(Tab.sign)
        }
        .toastOverlay($appState.toast)
        .onChange(of: ble.state) { newState in
            if case .ready = newState {
                appState.refreshFromDevice(via: ble)
            } else {
                // Any non-ready transition (disconnect, failure, scanning
                // again) wipes device-sourced fields so the UI never
                // displays stale data while we're not connected.
                appState.clearDeviceState()
            }
        }
    }

    /// Render `content` when the BLE connection is fully ready;
    /// otherwise show the shared `DisconnectedView` panel with copy
    /// that adapts to the current state and a button that switches
    /// back to the Device tab.
    @ViewBuilder
    private func gated<Content: View>(
        name: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if case .ready = ble.state {
            content()
        } else {
            DisconnectedView(
                tabName: name,
                tabIcon: icon,
                bleState: ble.state,
                onOpenDevice: { selectedTab = .device }
            )
        }
    }
}

#Preview {
    RootView()
        .environmentObject(BLEManager())
        .environmentObject(AppState())
}

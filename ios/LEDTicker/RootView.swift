import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var ble: BLEManager

    /// Track the selected tab so the empty-state "Open Device tab"
    /// button on the gated tabs can route the user back to the
    /// connect flow with a single tap.
    @State private var selectedTab: Tab = .device

    /// Tab cases carry their own display name and SF Symbol so
    /// `gated(...)` is a single source of truth — no name/icon
    /// duplication between the helper call and a separate `.tabItem`.
    private enum Tab: Hashable {
        case device, display, stocks, weather, sign

        var name: String {
            switch self {
            case .device:  return "Device"
            case .display: return "Display"
            case .stocks:  return "Stocks"
            case .weather: return "Weather"
            case .sign:    return "Sign"
            }
        }

        var icon: String {
            switch self {
            case .device:  return "antenna.radiowaves.left.and.right"
            case .display: return "rectangle.on.rectangle"
            case .stocks:  return "chart.line.uptrend.xyaxis"
            case .weather: return "cloud.sun.fill"
            case .sign:    return "signpost.right"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DeviceTab()
                .tabItem { Label(Tab.device.name, systemImage: Tab.device.icon) }
                .tag(Tab.device)

            gated(.display) { DisplayTab() }
            gated(.stocks)  { StocksTab() }
            gated(.weather) { WeatherTab() }
            gated(.sign)    { StatusTab() }
        }
        .toastOverlay($appState.toast)
        .onChange(of: ble.state) { oldState, newState in
            // Haptic feedback for ready transitions — the device is across
            // the room, so the phone is the only signal that "connect"
            // (or "disconnect") actually took. Distinguishing the
            // transitions means a refresh-only event with no state change
            // won't buzz.
            let becameReady = oldState != .ready && newState == .ready
            let leftReady   = oldState == .ready && newState != .ready
            if becameReady { Haptics.success() }
            if leftReady   { Haptics.tap() }

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
    /// otherwise show the shared `DisconnectedView` panel. Applies the
    /// `.tabItem` and `.tag` itself so caller passes only the Tab case.
    @ViewBuilder
    private func gated<Content: View>(
        _ tab: Tab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Group {
            if case .ready = ble.state {
                content()
            } else {
                DisconnectedView(
                    tabName: tab.name,
                    tabIcon: tab.icon,
                    bleState: ble.state,
                    onOpenDevice: { selectedTab = .device }
                )
            }
        }
        .tabItem { Label(tab.name, systemImage: tab.icon) }
        .tag(tab)
    }
}

#Preview {
    RootView()
        .environmentObject(BLEManager())
        .environmentObject(AppState())
}

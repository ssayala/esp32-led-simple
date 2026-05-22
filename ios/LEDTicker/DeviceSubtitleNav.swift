import SwiftUI

/// Sets the active device's friendly name as the navigation subtitle on the
/// gated tabs (Display / Stocks / Weather / Sign). The nav title itself stays
/// the tab name; iOS 18+ `.navigationSubtitle(_:)` gives the device name its
/// own line so it never truncates the way the old `topBarLeading` chip did.
///
/// These tabs only render when `ble.state == .ready` — when we're not
/// connected, RootView swaps in `DisconnectedView`. We still surface the
/// in-flight states (e.g. peripheral disconnect mid-tab) so the subtitle
/// doesn't briefly lie before the gate kicks in.
struct DeviceSubtitleNav: ViewModifier {
    @EnvironmentObject var ble: BLEManager

    func body(content: Content) -> some View {
        content.navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        switch ble.state {
        case .ready:                    return ble.activeDevice?.friendlyName ?? "Connected"
        case .connecting, .discovering: return "Connecting…"
        case .failed:                   return "Disconnected"
        default:                        return "Not connected"
        }
    }
}

extension View {
    /// Adds the active device's friendly name as a navigation subtitle.
    /// Pair with `NavigationStack` — subtitles are scoped to the navigation
    /// bar, not the TabView.
    func deviceSubtitleNav() -> some View {
        modifier(DeviceSubtitleNav())
    }
}

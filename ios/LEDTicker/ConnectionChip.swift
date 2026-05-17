import SwiftUI

/// Compact "you're connected to X" indicator. Lives in the topBarLeading
/// toolbar slot of the gated tabs (Display / Stocks / Weather / Sign).
///
/// Those tabs only render when `ble.state == .ready` — when we're not
/// connected, the parent `RootView` swaps in `DisconnectedView` which
/// already broadcasts the state, so the chip never needs to render a
/// "not connected" variant. We do still adapt subtly to in-flight
/// states (e.g. a peripheral disconnect mid-tab) so the chip doesn't
/// briefly lie before the gate kicks in.
struct ConnectionChip: View {
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status")
        .accessibilityValue(label)
    }

    private var tint: Color {
        switch ble.state {
        case .ready:                    return .green
        case .connecting, .discovering: return .orange
        case .failed:                   return .red
        default:                        return .gray
        }
    }

    private var label: String {
        switch ble.state {
        case .ready:                    return ble.activeDevice?.friendlyName ?? "Connected"
        case .connecting, .discovering: return "Connecting…"
        case .failed:                   return "Disconnected"
        default:                        return "Not connected"
        }
    }
}

/// Reusable view modifier so each gated tab can drop the chip in with
/// a single call. Apply it on the NavigationStack's content (inside the
/// tab, not at the TabView level — toolbars belong to NavigationStack).
struct ConnectionChipToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectionChip()
            }
        }
    }
}

extension View {
    /// Adds the shared `ConnectionChip` to the topBarLeading slot. Pair
    /// with `NavigationStack` — toolbars are scoped to the navigation
    /// stack, not the TabView.
    func connectionChipToolbar() -> some View {
        modifier(ConnectionChipToolbar())
    }
}

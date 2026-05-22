import SwiftUI
import UIKit  // for UIApplication.openSettingsURLString

/// Empty-state panel rendered in place of a tab's content while the
/// app isn't connected to an LED-Ticker. Mirrors Apple's empty-state
/// pattern (Find My pre-sign-in, Wallet with no cards): a large icon,
/// a short title, one line of context, and a single primary action
/// that gets the user back to the connect flow.
///
/// The exact copy adapts to the underlying BLE state — Bluetooth-off,
/// permission-denied, mid-connect, and "just not connected" each
/// warrant slightly different guidance.
struct DisconnectedView: View {
    /// Human-readable name of the tab being gated, e.g. "Stocks".
    /// Used in the body copy so the user knows what they're missing.
    let tabName: String

    /// SF Symbol for the tab. Rendered large above the title so the
    /// panel still feels like "the Stocks tab" rather than a generic
    /// not-connected screen.
    let tabIcon: String

    let bleState: ConnectionState
    let onOpenDevice: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 18) {
            iconView
                .frame(height: 72)
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2).bold()
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)

            if showButton {
                Button(action: handleButtonTap) {
                    Label(buttonTitle, systemImage: buttonIcon)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Primary action

    /// When BLE permission is denied, the only useful action is to jump
    /// the user into Settings → Bluetooth — the Device tab can't help.
    /// In every other non-ready state, route them to the Device tab to
    /// pick or re-connect to a peripheral.
    private func handleButtonTap() {
        if case .unauthorized = bleState,
           let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        } else {
            onOpenDevice()
        }
    }

    private var buttonTitle: String {
        if case .unauthorized = bleState { return "Open Settings" }
        return "Open Device tab"
    }

    private var buttonIcon: String {
        if case .unauthorized = bleState { return "gearshape" }
        return "antenna.radiowaves.left.and.right"
    }

    // MARK: - Pieces

    private var iconView: some View {
        // Pulse the tab icon while connecting instead of a generic spinner —
        // keeps visual continuity with the rest of the tab and reads as
        // "we're working on this specific thing."
        Image(systemName: tabIcon)
            .font(.system(size: 56))
            .foregroundStyle(.secondary)
            .symbolEffect(.pulse, options: .repeating, isActive: isConnecting)
    }

    private var isConnecting: Bool {
        switch bleState {
        case .connecting, .discovering: return true
        default: return false
        }
    }

    private var title: String {
        switch bleState {
        case .poweredOff:                return "Bluetooth is off"
        case .unauthorized:              return "Bluetooth not allowed"
        case .connecting, .discovering:  return "Connecting…"
        case .failed:                    return "Couldn't connect"
        default:                         return "Not connected"
        }
    }

    private var message: String {
        switch bleState {
        case .poweredOff:
            return "Turn on Bluetooth to use \(tabName)."
        case .unauthorized:
            return "Allow Bluetooth for LED Ticker in Settings to use \(tabName)."
        case .connecting, .discovering:
            return "Hang tight while we link up with your LED Ticker."
        case .failed:
            return "Try connecting again from the Device tab."
        default:
            return "Connect to a device on the Device tab to use \(tabName)."
        }
    }

    /// Hide the button mid-connect — nothing useful happens if the
    /// user mashes it then. We let the state transition resolve first.
    private var showButton: Bool {
        switch bleState {
        case .connecting, .discovering: return false
        default: return true
        }
    }
}

import SwiftUI

/// 2nd tab. Owns the multi-category display-mode toggles, a status row
/// that reflects what the device is actually scrolling, and a Save flow
/// that mirrors the rest of the app (stage edits, then write).
struct DisplayTab: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var app: AppState

    @State private var pendingCategories: Categories = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                categoriesSection
            }
            .navigationTitle("Display")
            .deviceSubtitleNav()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: saveMode)
                        .disabled(!saveEnabled)
                }
            }
            .onAppear(perform: loadBaselineIfNeeded)
            .onChange(of: app.baselineCategories) { _, newValue in
                pendingCategories = newValue
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(statusTint.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: statusSymbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(statusTint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Currently showing").font(.body)
                    Text(statusBody)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var categoriesSection: some View {
        Section {
            toggleRow(label: "Stocks",  category: .stocks)
            toggleRow(label: "Weather", category: .weather)
            toggleRow(label: "Clock",   category: .clock)
        } header: {
            Text("Categories").textCase(nil)
        } footer: {
            Text("At least one category must be enabled.")
        }
    }

    @ViewBuilder
    private func toggleRow(label: String, category: Categories) -> some View {
        let binding = Binding<Bool>(
            get: { pendingCategories.contains(category) },
            set: { isOn in
                if isOn {
                    pendingCategories.insert(category)
                } else {
                    pendingCategories.remove(category)
                }
            }
        )
        let prereq = prereqStatus(category)
        VStack(alignment: .leading, spacing: 4) {
            Toggle(label, isOn: binding)
                .disabled(toggleDisabled(category: category,
                                          isOn: binding.wrappedValue,
                                          prereqMet: prereq.met))
            if let hint = prereq.hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Toggle gating

    /// A toggle is disabled when its prereq is unmet, OR when it would
    /// leave `pendingCategories` empty (firmware ignores empty-mask writes).
    private func toggleDisabled(category: Categories, isOn: Bool, prereqMet: Bool) -> Bool {
        if !prereqMet { return true }
        if isOn && pendingCategories == [category] { return true }
        return false
    }

    /// Whether a category's prerequisites are met, and if not, a short
    /// hint to show beneath the toggle. Single source of truth for both
    /// the disabled state and the helper text.
    private func prereqStatus(_ category: Categories) -> (met: Bool, hint: String?) {
        let wifi = !app.ssid.isEmpty
        let apiKey = !app.apikey.isEmpty
        switch category {
        case .stocks:
            return (wifi && apiKey, (wifi && apiKey) ? nil : "Requires WiFi & Finnhub API key")
        case .weather, .clock:
            return (wifi, wifi ? nil : "Requires WiFi")
        default:
            return (true, nil)
        }
    }

    // MARK: - State helpers

    private func loadBaselineIfNeeded() {
        guard !loaded else { return }
        pendingCategories = app.baselineCategories
        loaded = true
    }

    private var saveEnabled: Bool {
        guard case .ready = ble.state else { return false }
        return !pendingCategories.isEmpty && pendingCategories != app.baselineCategories
    }

    // MARK: - Save

    private func saveMode() {
        do {
            let data = try Payloads.mode(pendingCategories)
            app.send(via: ble, kind: .mode, data: data, label: "Display")
            // Optimistic local update so the status row + dirty tracking
            // reflect the just-sent mask without waiting for a re-read.
            // If the BLE write fails the toast surfaces it.
            app.baselineCategories = pendingCategories
            app.deviceMode = .content(pendingCategories)
        } catch {
            app.show("Display: \(error)", isError: true)
        }
    }

    // MARK: - Status decoration

    private var statusSymbol: String {
        switch app.deviceMode {
        case .content: return "checkmark.circle.fill"
        case .setup:   return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var statusTint: Color {
        switch app.deviceMode {
        case .content: return .green
        case .setup:   return .orange
        case .unknown: return .gray
        }
    }

    private var statusBody: String {
        switch app.deviceMode {
        case .content(let cats):
            return humanReadable(cats)
        case .setup:
            if app.ssid.isEmpty {
                return "Setup needed — configure WiFi"
            } else if app.apikey.isEmpty {
                return "Setup needed — configure Finnhub key"
            } else {
                return "Setup needed"
            }
        case .unknown:
            return "—"
        }
    }

    private func humanReadable(_ c: Categories) -> String {
        if c == .all { return "All categories" }
        var parts: [String] = []
        if c.contains(.stocks)  { parts.append("Stocks") }
        if c.contains(.weather) { parts.append("Weather") }
        if c.contains(.clock)   { parts.append("Clock") }
        return parts.joined(separator: ", ")
    }
}

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
            .connectionChipToolbar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: saveMode)
                        .fontWeight(.semibold)
                        .disabled(!saveEnabled)
                }
            }
            .onAppear(perform: loadBaselineIfNeeded)
            .onChange(of: app.baselineCategories) { newValue in
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
            Text("Categories")
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
        VStack(alignment: .leading, spacing: 4) {
            Toggle(label, isOn: binding)
                .disabled(toggleDisabled(category: category, isOn: binding.wrappedValue))
            if let hint = prereqHint(for: category) {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Toggle gating

    /// A toggle is disabled when its prereq is unmet, OR when it would
    /// leave `pendingCategories` empty (firmware ignores empty-mask writes).
    private func toggleDisabled(category: Categories, isOn: Bool) -> Bool {
        if !prereqMet(category) { return true }
        if isOn && pendingCategories == [category] { return true }
        return false
    }

    private func prereqMet(_ category: Categories) -> Bool {
        if category == .stocks  { return !app.ssid.isEmpty && !app.apikey.isEmpty }
        if category == .weather { return !app.ssid.isEmpty }
        if category == .clock   { return !app.ssid.isEmpty }
        return true
    }

    private func prereqHint(for category: Categories) -> String? {
        if prereqMet(category) { return nil }
        if category == .stocks { return "Requires WiFi & Finnhub API key" }
        if category == .weather || category == .clock { return "Requires WiFi" }
        return nil
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

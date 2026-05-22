import SwiftUI

struct WeatherTab: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var app: AppState
    @State private var newLocation = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.locations, id: \.self) { loc in
                        Text(loc)
                    }
                    .onDelete { app.locations.remove(atOffsets: $0) }
                    .onMove   { app.locations.move(fromOffsets: $0, toOffset: $1) }

                    HStack {
                        TextField("City, State or ZIP", text: $newLocation)
                            .autocorrectionDisabled()
                            .focused($inputFocused)
                            .onSubmit(addLocation)
                        if !trimmedNew.isEmpty {
                            Button("Add", action: addLocation)
                                .disabled(app.locations.count >= Payloads.locationMaxCount)
                        }
                    }
                } header: {
                    Text("Locations").textCase(nil)
                } footer: {
                    footerText
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Weather")
            .deviceSubtitleNav()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: saveLocations)
                        .disabled(!canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { inputFocused = false }
                }
            }
        }
    }

    // MARK: - Actions

    private var canWrite: Bool { ble.state == .ready }
    private var trimmedNew: String { newLocation.trimmingCharacters(in: .whitespaces) }

    // Mirror StocksTab: Save disabled until the local list diverges from
    // what the device last reported. Reorder-only changes still surface
    // as unsaved so the user isn't surprised by silent persistence gaps.
    private var isDirty: Bool { app.locations != app.baselineLocations }
    private var canSave: Bool { canWrite && !app.locations.isEmpty && isDirty }

    @ViewBuilder
    private var footerText: some View {
        let diff = changeCount
        if diff > 0 {
            Text("\(diff) unsaved change\(diff == 1 ? "" : "s") — tap Save to push to device.")
                .foregroundStyle(.orange)
        } else {
            Text("\(app.locations.count) of \(Payloads.locationMaxCount). Enter a ZIP code or \"City, State\" — the device geocodes each via Open-Meteo.")
        }
    }

    private var changeCount: Int {
        guard isDirty else { return 0 }
        let baseline = Set(app.baselineLocations)
        let current = Set(app.locations)
        let added = current.subtracting(baseline).count
        let removed = baseline.subtracting(current).count
        return max(added + removed, 1)
    }

    private func addLocation() {
        let loc = trimmedNew
        newLocation = ""
        inputFocused = false
        guard !loc.isEmpty,
              !loc.contains("|"),
              loc.utf8.count <= Payloads.locationMaxLen,
              !app.locations.contains(loc),
              app.locations.count < Payloads.locationMaxCount
        else {
            return
        }
        app.locations.append(loc)
    }

    private func saveLocations() {
        do {
            let data = try Payloads.locations(app.locations)
            app.send(via: ble, kind: .locations, data: data, label: "Locations")
            // Optimistic — mirror the other tabs. A failed write surfaces
            // via toast, and the next refresh corrects baseline if needed.
            app.baselineLocations = app.locations
        } catch {
            app.show("Locations: \(error)", isError: true)
        }
    }
}

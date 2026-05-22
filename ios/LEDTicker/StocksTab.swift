import SwiftUI

struct StocksTab: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var app: AppState
    @State private var newTicker = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.tickers, id: \.self) { t in
                        Text(t).font(.body.monospaced())
                    }
                    .onDelete { app.tickers.remove(atOffsets: $0) }
                    .onMove   { app.tickers.move(fromOffsets: $0, toOffset: $1) }

                    HStack {
                        TextField("Add symbol (e.g. NVDA)", text: $newTicker)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .focused($inputFocused)
                            .onSubmit(addTicker)
                        if !trimmedNew.isEmpty {
                            Button("Add", action: addTicker)
                                .disabled(app.tickers.count >= Payloads.tickerMaxCount)
                        }
                    }
                } header: {
                    Text("Tickers").textCase(nil)
                } footer: {
                    footerText
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await reloadQuotes() }
            .navigationTitle("Stocks")
            .deviceSubtitleNav()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: saveTickers)
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
    private var trimmedNew: String { newTicker.trimmingCharacters(in: .whitespaces) }

    // Local list diverges from the device on every add/delete/reorder.
    // The Save button stays disabled (and the footer skips the unsaved
    // notice) until divergence exists — so a tap to Save always does
    // something useful, and the user can tell at a glance whether they
    // still need to push.
    private var isDirty: Bool { app.tickers != app.baselineTickers }
    private var canSave: Bool { canWrite && !app.tickers.isEmpty && isDirty }

    @ViewBuilder
    private var footerText: some View {
        let diff = changeCount
        if diff > 0 {
            Text("\(diff) unsaved change\(diff == 1 ? "" : "s") — tap Save to push to device.")
                .foregroundStyle(.orange)
        } else {
            Text("\(app.tickers.count) of \(Payloads.tickerMaxCount). Pull down to refresh quotes.")
        }
    }

    private var changeCount: Int {
        guard isDirty else { return 0 }
        let baseline = Set(app.baselineTickers)
        let current = Set(app.tickers)
        let added = current.subtracting(baseline).count
        let removed = baseline.subtracting(current).count
        // Reorder-only counts as 1 (no symmetric difference) so the user
        // still sees an unsaved-change notice; a pure reorder shouldn't
        // silently look saved.
        return max(added + removed, 1)
    }

    private func addTicker() {
        let t = trimmedNew.uppercased()
        newTicker = ""
        inputFocused = false
        guard !t.isEmpty,
              t.utf8.count <= Payloads.tickerMaxLen,
              !app.tickers.contains(t),
              app.tickers.count < Payloads.tickerMaxCount
        else {
            return
        }
        app.tickers.append(t)
    }

    private func saveTickers() {
        do {
            let data = try Payloads.tickers(app.tickers)
            app.send(via: ble, kind: .tickers, data: data, label: "Tickers")
            // Optimistic — mirror the other tabs. A failed write surfaces
            // via toast, and the next refresh corrects baseline if needed.
            app.baselineTickers = app.tickers
        } catch {
            app.show("Tickers: \(error)", isError: true)
        }
    }

    /// Pull-to-refresh: tell the device to force-fetch new quotes from Finnhub.
    /// We don't get a response from the device, so we hold the spinner briefly
    /// so it feels connected to the action rather than snapping back instantly.
    private func reloadQuotes() async {
        guard canWrite else { return }
        app.send(via: ble, kind: .command, data: Payloads.command("reload"), label: "Reload")
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }
}

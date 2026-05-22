import SwiftUI

/// "Sign" tab — manage the device's active status (the sign that
/// preempts the ambient scroll modes). The device only knows about one
/// active status at a time; the preset chips shown here are app-local
/// and live in `AppState.presetTexts` (persisted to UserDefaults).
struct StatusTab: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var app: AppState

    /// Pending duration-sheet target. When non-nil, the duration sheet
    /// is shown and confirming it sends the status write. Stored as the
    /// Identifiable wrapper directly so `.sheet(item:)` sees a stable
    /// identity for the lifetime of the presentation (binding-derived
    /// versions would mint a fresh UUID per body invocation and flip
    /// the sheet's identity).
    @State private var pendingPreset: PresetTarget?

    /// Custom text input + its own duration selection.
    @State private var customText: String = ""
    @State private var customDuration: DurationChoice = .lastUsedOrDefault

    @State private var showEditPresets = false

    @FocusState private var customFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                activeSection
                presetSection
                customSection
            }
            .navigationTitle("Sign")
            .deviceSubtitleNav()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showEditPresets = true
                    } label: {
                        Label("Edit Presets", systemImage: "slider.horizontal.3")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { customFocused = false }
                }
            }
            .sheet(isPresented: $showEditPresets) {
                EditPresetsSheet()
                    .environmentObject(app)
            }
            .sheet(item: $pendingPreset) { target in
                DurationSheet(text: target.text, initial: .lastUsedOrDefault) { secs in
                    send(text: target.text, secondsRemaining: secs)
                    pendingPreset = nil
                } onCancel: {
                    pendingPreset = nil
                }
                .presentationDetents([.medium])
            }
            // Auto-clear local state once the deadline passes. Runs while
            // the Sign tab is visible; if the user is on another tab when
            // expiry hits, the next time they return the task fires
            // immediately (sleep duration ≤ 0) and clears in-place. The
            // device's own clear is authoritative — this just keeps the
            // local view honest until the next refresh.
            .task(id: app.activeStatus) {
                guard let expiresAt = app.activeStatus?.expiresAt else { return }
                let delay = expiresAt.timeIntervalSinceNow
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { return }
                // Re-check: activeStatus could have been replaced or
                // cleared during the sleep.
                if app.activeStatus?.expiresAt == expiresAt {
                    app.activeStatus = nil
                }
            }
        }
    }

    // MARK: - Sections

    private var activeSection: some View {
        Section {
            if let s = app.activeStatus {
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.text)
                        .font(.title2).bold()
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                    expiryLine(for: s)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button(role: .destructive, action: clearStatus) {
                            Label("Clear", systemImage: "xmark.circle")
                        }
                        .disabled(!canWrite)
                    }
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(.secondary)
                    Text("No active sign.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Active sign").textCase(nil)
        } footer: {
            if app.activeStatus != nil {
                Text("Clearing resumes the device's ambient mode immediately.")
            } else {
                Text("Pick a preset below or write a custom message to set the sign.")
            }
        }
    }

    private var presetSection: some View {
        Section {
            if app.presetTexts.isEmpty {
                Text("No presets. Tap “Edit Presets” to add one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 10) {
                    ForEach(app.presetTexts, id: \.self) { preset in
                        Button {
                            pendingPreset = PresetTarget(text: preset)
                        } label: {
                            Text(preset)
                                .font(.callout).bold()
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .padding(.horizontal, 8)
                                // Plain glass — tinting the glass with .accentColor
                                // made it opaque and hid the (also-accent) label.
                                // Foreground carries the color; glass carries the
                                // material.
                                .glassEffect(.regular, in: .rect(cornerRadius: 10))
                                .foregroundStyle(canWrite ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canWrite)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Presets").textCase(nil)
        }
    }

    private var customSection: some View {
        Section {
            TextField("Custom text", text: $customText)
                .focused($customFocused)
                .submitLabel(.done)
                .autocorrectionDisabled()
            Picker("Duration", selection: $customDuration) {
                ForEach(DurationChoice.all, id: \.self) { d in
                    Text(d.label).tag(d)
                }
            }
            Button(action: sendCustom) {
                HStack {
                    Spacer()
                    Text("Set sign").fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(!canSendCustom)
        } header: {
            Text("Custom").textCase(nil)
        } footer: {
            footerForCustom
        }
    }

    @ViewBuilder
    private var footerForCustom: some View {
        let bytes = trimmedCustom.utf8.count
        let over = bytes > Payloads.statusTextMaxBytes
        let hasPipe = trimmedCustom.contains("|")
        HStack {
            Group {
                if hasPipe {
                    Text("Text cannot contain ‘|’.")
                } else if over {
                    Text("Too long.")
                } else {
                    Text("Up to \(Payloads.statusTextMaxBytes) bytes. No ‘|’.")
                }
            }
            Spacer()
            Text("\(bytes) / \(Payloads.statusTextMaxBytes)")
                .foregroundStyle(over ? .red : .secondary)
        }
        .font(.footnote)
    }

    // MARK: - Helpers

    private var canWrite: Bool { ble.state == .ready }

    private var trimmedCustom: String {
        customText.trimmingCharacters(in: .whitespaces)
    }

    private var canSendCustom: Bool {
        guard canWrite, !trimmedCustom.isEmpty else { return false }
        guard !trimmedCustom.contains("|") else { return false }
        return trimmedCustom.utf8.count <= Payloads.statusTextMaxBytes
    }

    private var gridColumns: [GridItem] {
        // 2-column on phone, 3-column when there's room. Adaptive
        // keeps long preset labels readable without manual tuning.
        [GridItem(.adaptive(minimum: 110), spacing: 10)]
    }

    /// Live-updating expiry line. iOS 26's `Text("\(date, style: .relative)")`
    /// interpolation auto-refreshes ("in 30 minutes" -> "in 29 minutes" ->
    /// ...) without any timer plumbing on our side. (The `Text + Text`
    /// overload that worked pre-26 was deprecated in iOS 26 in favor of
    /// string interpolation.)
    @ViewBuilder
    private func expiryLine(for s: ActiveStatus) -> some View {
        if let expiresAt = s.expiresAt {
            Text("Expires \(expiresAt, style: .relative)")
        } else {
            Text("Indefinite")
        }
    }

    // MARK: - Actions

    private func send(text: String, secondsRemaining: UInt32) {
        do {
            let data = try Payloads.status(text: text, durationSeconds: secondsRemaining)
            app.send(via: ble, kind: .status, data: data, label: "Sign")
            // Optimistic local update so the active card reflects the
            // write without waiting for a re-read. The next refresh
            // overwrites this with the device's authoritative state.
            let expiresAt = secondsRemaining == 0
                ? nil
                : Date().addingTimeInterval(TimeInterval(secondsRemaining))
            app.activeStatus = ActiveStatus(text: text, expiresAt: expiresAt)
        } catch {
            app.show("Sign: \(error)", isError: true)
        }
    }

    private func sendCustom() {
        let text = trimmedCustom
        guard canSendCustom else { return }
        DurationChoice.persistLastUsed(customDuration)
        send(text: text, secondsRemaining: customDuration.seconds)
        customFocused = false
        customText = ""
    }

    private func clearStatus() {
        Haptics.warning()
        app.send(via: ble, kind: .status, data: Payloads.statusClear(), label: "Clear sign")
        app.activeStatus = nil
    }
}

// MARK: - Preset target (Identifiable wrapper)

/// `.sheet(item:)` requires Identifiable, and preset text isn't
/// unique enough on its own (duplicates can briefly exist while
/// editing). A UUID minted once per presentation gives the sheet a
/// stable identity for its full lifetime.
private struct PresetTarget: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - Duration choices

enum DurationChoice: Hashable {
    case minutes(UInt32)
    case indefinite

    static let all: [DurationChoice] = [
        .minutes(15), .minutes(30), .minutes(60), .minutes(90), .indefinite,
    ]

    static let lastUsedKey = "presetDuration.v1"

    /// Restore the user's last pick, or fall back to 30 min for a fresh
    /// install. `object(forKey:)` distinguishes "no value" from an
    /// explicit 0, which is needed because 0 seconds means indefinite.
    static var lastUsedOrDefault: DurationChoice {
        guard let raw = UserDefaults.standard.object(forKey: lastUsedKey) as? Int else {
            return .minutes(30)
        }
        if raw <= 0 { return .indefinite }
        return .minutes(UInt32(raw / 60))
    }

    static func persistLastUsed(_ d: DurationChoice) {
        // Store as seconds (0 = indefinite), matching the wire format.
        UserDefaults.standard.set(Int(d.seconds), forKey: lastUsedKey)
    }

    var seconds: UInt32 {
        switch self {
        case .minutes(let m): return m * 60
        case .indefinite:     return 0
        }
    }

    var label: String {
        switch self {
        case .minutes(let m): return "\(m) min"
        case .indefinite:     return "Indefinite"
        }
    }
}

// MARK: - Duration sheet (per-preset)

private struct DurationSheet: View {
    let text: String
    @State var selection: DurationChoice
    let onConfirm: (UInt32) -> Void
    let onCancel: () -> Void

    init(text: String,
         initial: DurationChoice,
         onConfirm: @escaping (UInt32) -> Void,
         onCancel: @escaping () -> Void) {
        self.text = text
        self._selection = State(initialValue: initial)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(text)
                        .font(.title3).bold()
                        .lineLimit(2)
                } header: {
                    Text("Sign text").textCase(nil)
                }
                Section {
                    ForEach(DurationChoice.all, id: \.self) { d in
                        Button {
                            selection = d
                        } label: {
                            HStack {
                                Text(d.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selection == d {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Duration").textCase(nil)
                }
            }
            .navigationTitle("Set sign")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Set") {
                        DurationChoice.persistLastUsed(selection)
                        onConfirm(selection.seconds)
                    }
                }
            }
        }
    }
}

// MARK: - Edit presets sheet

private struct EditPresetsSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var newPreset = ""
    @FocusState private var newFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.presetTexts, id: \.self) { preset in
                        Text(preset)
                    }
                    .onDelete { app.presetTexts.remove(atOffsets: $0) }
                    .onMove   { app.presetTexts.move(fromOffsets: $0, toOffset: $1) }

                    HStack {
                        TextField("New preset", text: $newPreset)
                            .focused($newFocused)
                            .submitLabel(.done)
                            .onSubmit(add)
                            .autocorrectionDisabled()
                        if !trimmed.isEmpty {
                            Button("Add", action: add)
                                .disabled(!isValid)
                        }
                    }
                } footer: {
                    if !trimmed.isEmpty && !isValid {
                        Text(invalidReason)
                            .foregroundStyle(.red)
                    } else {
                        Text("Chips appear on the Sign tab. They never sync to the device.")
                    }
                }
            }
            .navigationTitle("Edit Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { newFocused = false }
                }
            }
        }
    }

    private var trimmed: String {
        newPreset.trimmingCharacters(in: .whitespaces)
    }

    private var isValid: Bool {
        !trimmed.isEmpty
            && !trimmed.contains("|")
            && trimmed.utf8.count <= Payloads.statusTextMaxBytes
            && !app.presetTexts.contains(trimmed)
    }

    private var invalidReason: String {
        if trimmed.contains("|") { return "Cannot contain ‘|’." }
        if trimmed.utf8.count > Payloads.statusTextMaxBytes { return "Too long." }
        if app.presetTexts.contains(trimmed) { return "Already a preset." }
        return ""
    }

    private func add() {
        guard isValid else { return }
        app.presetTexts.append(trimmed)
        newPreset = ""
        newFocused = false
    }
}

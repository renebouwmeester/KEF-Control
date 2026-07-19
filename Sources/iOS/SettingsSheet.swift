// iOS settings: one scrolling Form instead of the Mac's tabbed window, same
// Save/Cancel staging semantics. Hotkeys don't exist here; volume step is a
// hotkey concern, so it stays Mac-only too.
import SwiftUI
import Combine

/// Staged copies of everything the sheet edits; written back only on Save.
/// A trimmed sibling of the Mac SettingsSession (which also stages hotkey
/// recorders) — keep the shared fields in step.
@MainActor
final class SettingsSheetSession: ObservableObject {
    let model: SpeakerModel

    struct SourceRow: Identifiable {
        let id: String
        let name: String
        var visible: Bool
    }

    @Published var ipText: String
    @Published var sourceRows: [SourceRow]
    @Published var presetValues: [String]        // "" = empty slot
    @Published var radioSelection: [String]      // station path, "" = empty
    @Published var stations: [SpeakerModel.RadioStation] = []
    @Published var stationsLoaded = false

    init(model: SpeakerModel) {
        self.model = model
        ipText = model.speakerIP
        sourceRows = model.orderedSources.map {
            SourceRow(id: $0.id, name: $0.name,
                      visible: !model.hiddenSources.contains($0.id))
        }
        presetValues = model.presetSlots.map { $0 > 0 ? String($0) : "" }
        radioSelection = model.radioSlots.map { $0?.path ?? "" }
    }

    /// Stations already in slots are merged in, so a saved preset survives
    /// dropping off the speaker's history.
    func loadStations() async {
        var found = await model.radioPickerStations()
        for slot in model.radioSlots.compactMap({ $0 })
        where !found.contains(where: { $0.path == slot.path }) {
            found.append(slot)
        }
        stations = found
        stationsLoaded = true
    }

    func save() {
        model.setPresetSlots(presetValues.map { Int($0) ?? 0 })
        model.setSourceLayout(order: sourceRows.map(\.id),
                              hidden: Set(sourceRows.filter { !$0.visible }.map(\.id)))
        model.setRadioSlots(radioSelection.map { path in
            stations.first { $0.path == path }
        })
        model.setSpeakerIP(ipText)
    }
}

struct SettingsSheet: View {
    @StateObject private var session: SettingsSheetSession
    @ObservedObject private var discovery: SpeakerDiscovery
    @Environment(\.dismiss) private var dismiss

    init(model: SpeakerModel) {
        _session = StateObject(wrappedValue: SettingsSheetSession(model: model))
        discovery = model.discovery
    }

    var body: some View {
        NavigationStack {
            Form {
                speakerSection
                sourcesSection
                radioSection
                volumeSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        session.save()
                        dismiss()
                    }
                }
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private var speakerSection: some View {
        Section {
            if discovery.found.isEmpty {
                Text(discovery.isSearching ? "Searching…" : "No speakers found")
                    .foregroundStyle(.secondary)
            }
            ForEach(discovery.found) { found in
                Button {
                    session.ipText = found.ip
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(found.name)
                                .foregroundStyle(.primary)
                            Text("\(found.model.isEmpty ? "KEF" : found.model) · \(found.ip)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if found.ip == session.ipText {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.phoneAccent)
                        }
                    }
                }
            }
            TextField("IP address or hostname", text: $session.ipText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Speaker")
        } footer: {
            Text("Speakers on your network are found automatically; "
                 + "you can also type an address.")
        }
    }

    private var sourcesSection: some View {
        Section {
            ForEach($session.sourceRows) { $row in
                Toggle(row.name, isOn: $row.visible)
            }
            .onMove { session.sourceRows.move(fromOffsets: $0, toOffset: $1) }
        } header: {
            HStack {
                Text("Sources")
                Spacer()
                EditButton().font(.caption)
            }
        } footer: {
            Text("Edit to reorder — the panel shows inputs in this order.")
        }
    }

    private var radioSection: some View {
        Section {
            if !session.stationsLoaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading stations from the speaker…")
                        .foregroundStyle(.secondary)
                }
            } else {
                // 5 on iOS; later slots set on the Mac keep their values.
                ForEach(0..<5, id: \.self) { i in
                    Picker("Slot \(i + 1)", selection: $session.radioSelection[i]) {
                        Text("—").tag("")
                        ForEach(session.stations, id: \.path) { station in
                            Text(station.title).tag(station.path)
                        }
                    }
                }
            }
        } header: {
            Text("Radio presets")
        } footer: {
            Text("Stations come from the speaker's radio history and favourites "
                 + "— play one in KEF Connect once and it appears here.")
        }
        .task { if !session.stationsLoaded { await session.loadStations() } }
    }

    private var volumeSection: some View {
        Section {
            // 5 on iOS; later slots set on the Mac keep their values.
            ForEach(0..<5, id: \.self) { i in
                LabeledContent("Preset \(i + 1)") {
                    TextField("—", text: $session.presetValues[i])
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
            }
        } header: {
            Text("Volume presets")
        }
    }
}

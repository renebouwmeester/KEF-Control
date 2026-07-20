// iOS settings: one scrolling Form instead of the Mac's tabbed window, same
// Save/Cancel staging semantics. Hotkeys don't exist here; volume step is a
// hotkey concern, so it stays Mac-only too.
import SwiftUI
import Combine
import UIKit

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
    @Published var shortcutValues: [String]      // Shortcut names, "" = empty
    /// Cached shortcut names for the picker — iOS apps can't enumerate the
    /// Shortcuts library, so this comes from the Mac (same iCloud-synced
    /// library) or a clipboard import; free-typed names merge in.
    @Published var knownShortcuts: [String] =
        (UserDefaults.standard.array(forKey: "KnownShortcuts") as? [String]) ?? []
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
        shortcutValues = model.shortcutSlots
        // Slot names always appear in the picker, even if the cache is stale.
        for name in shortcutValues where !name.isEmpty && !knownShortcuts.contains(name) {
            knownShortcuts.append(name)
        }
    }

    func rememberShortcut(_ name: String) {
        guard !name.isEmpty, !knownShortcuts.contains(name) else { return }
        knownShortcuts.append(name)
        UserDefaults.standard.set(knownShortcuts, forKey: "KnownShortcuts")
    }

    /// Replace the cache from the clipboard (one shortcut name per line) —
    /// fed by a helper shortcut: Get My Shortcuts -> Copy to Clipboard.
    func importShortcutsFromClipboard() -> Int {
        guard let text = UIPasteboard.general.string else { return 0 }
        let names = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard names.count > 1 else { return 0 }
        var merged = names
        for slot in shortcutValues where !slot.isEmpty && !merged.contains(slot) {
            merged.append(slot)
        }
        knownShortcuts = merged
        UserDefaults.standard.set(knownShortcuts, forKey: "KnownShortcuts")
        return names.count
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
        // Only write the slots once the station list actually loaded — saving
        // before that (airable browsing can take ~20s) matched every path
        // against an empty list and silently wiped all slots.
        if stationsLoaded {
            model.setRadioSlots(radioSelection.map { path in
                stations.first { $0.path == path }
            })
        }
        model.setShortcutSlots(shortcutValues)
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
                handednessSection
                sourcesSection
                volumeSection
                shortcutSection
                radioSection
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

    /// Live, not staged: flipping it mirrors the layout instantly, which is
    /// its own confirmation.
    @AppStorage("LeftHanded") private var leftHanded = false

    private var handednessSection: some View {
        Section {
            Picker("Use app", selection: $leftHanded) {
                Text("Right-handed").tag(false)
                Text("Left-handed").tag(true)
            }
        } footer: {
            Text("Mirrors the controls so they cluster on your thumb's side, "
                 + "and keeps the volume number where the dragging thumb "
                 + "can't cover it.")
        }
    }

    private var sourcesSection: some View {
        Section {
            // An embedded plain List with its own always-active edit mode:
            // dragging rows directly in the grouped Form lurched sideways,
            // and a pushed screen was an extra step. The inner List scopes
            // the smooth reordering to just these rows.
            SourceOrderInline(session: session)
                // Stride triangulated on device at ~49.6pt (49 clipped a
                // sliver, 52+8 overshot by half a row); 50 lands within a
                // couple of points and the tiny surplus reads as padding.
                .frame(height: CGFloat(session.sourceRows.count) * 50)
                .listRowInsets(EdgeInsets())
        } header: {
            Text("Sources")
        } footer: {
            Text("Drag to reorder — the bar shows inputs in this order. "
                 + "Up to four can be shown: with four selected the others "
                 + "are greyed out until you switch one off.")
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
                // 6 on iOS; a 7th slot set on the Mac keep their values.
                ForEach(0..<6, id: \.self) { i in
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
            // 6 on iOS; a 7th slot set on the Mac keep their values.
            ForEach(0..<6, id: \.self) { i in
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

    private var shortcutSection: some View {
        Section {
            ForEach(0..<6, id: \.self) { i in
                NavigationLink {
                    ShortcutPickerScreen(session: session, slot: i)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(session.shortcutValues[i].isEmpty
                                          ? Color.white.opacity(0.06)
                                          : Color.white.opacity(0.14))
                            Text("\(i + 1)")
                                .font(.footnote.weight(.semibold).monospacedDigit())
                                .foregroundStyle(session.shortcutValues[i].isEmpty
                                                 ? .tertiary : .secondary)
                        }
                        .frame(width: 26, height: 26)
                        Text(session.shortcutValues[i].isEmpty
                             ? "—" : session.shortcutValues[i])
                            .foregroundStyle(session.shortcutValues[i].isEmpty
                                             ? .secondary : .primary)
                            .lineLimit(1)
                    }
                }
            }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("Each slot appears as a numbered button in the quick row "
                 + "and runs that Apple Shortcut. Running briefly opens the "
                 + "Shortcuts app — iOS offers no background way.")
        }
    }
}

/// Embedded reorder list: plain style, fixed height, scroll disabled, its
/// own permanently-active edit mode — smooth List dragging inline in the
/// Form without a pushed screen.
struct SourceOrderInline: View {
    @ObservedObject var session: SettingsSheetSession

    var body: some View {
        let visibleCount = session.sourceRows.filter(\.visible).count
        List {
            ForEach(session.sourceRows) { row in
                Toggle(row.name, isOn: visibleBinding(row.id))
                    .disabled(!row.visible && visibleCount >= 4)
                    // Match the surrounding grouped-Form row colour — plain
                    // style would otherwise stand out against the section.
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
            .onMove { session.sourceRows.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        // Pin the metrics so the fixed frame's row math holds exactly —
        // stray content margins clipped the last row (USB) out of view.
        .environment(\.defaultMinListRowHeight, 44)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .environment(\.editMode, .constant(.active))
    }

    private func visibleBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { session.sourceRows.first(where: { $0.id == id })?.visible ?? true },
            set: { value in
                if let i = session.sourceRows.firstIndex(where: { $0.id == id }) {
                    session.sourceRows[i].visible = value
                }
            }
        )
    }
}

/// Searchable picker over the cached shortcut-name list, with free entry
/// and a clipboard refresh — the closest iOS allows to browsing the
/// Shortcuts library.
struct ShortcutPickerScreen: View {
    @ObservedObject var session: SettingsSheetSession
    let slot: Int
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var custom = ""
    @State private var importedCount: Int?

    private var filtered: [String] {
        search.isEmpty ? session.knownShortcuts
                       : session.knownShortcuts.filter {
                             $0.localizedCaseInsensitiveContains(search)
                         }
    }

    var body: some View {
        List {
            Section {
                row(name: "", label: "None")
                ForEach(filtered, id: \.self) { name in
                    row(name: name, label: name)
                }
            }
            Section {
                TextField("Type a name not in the list", text: $custom)
                    .autocorrectionDisabled()
                    .onSubmit {
                        let name = custom.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        session.rememberShortcut(name)
                        session.shortcutValues[slot] = name
                        dismiss()
                    }
                Button {
                    importedCount = session.importShortcutsFromClipboard()
                } label: {
                    if let n = importedCount {
                        Text(n > 0 ? "Imported \(n) shortcuts" : "Clipboard had no list")
                    } else {
                        Text("Refresh list from clipboard")
                    }
                }
            } footer: {
                Text("iOS apps can't read your Shortcuts library. To refresh "
                     + "the list: in Shortcuts, run Get My Shortcuts → Copy "
                     + "to Clipboard, then tap refresh. The Mac app seeds "
                     + "this list too — the library syncs via iCloud.")
            }
        }
        .searchable(text: $search, prompt: "Search shortcuts")
        .navigationTitle("Slot \(slot + 1)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(name: String, label: String) -> some View {
        Button {
            session.shortcutValues[slot] = name
            dismiss()
        } label: {
            HStack {
                Text(label)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if session.shortcutValues[slot] == name {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.phoneAccent)
                }
            }
        }
    }
}

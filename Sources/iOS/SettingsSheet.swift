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
    /// One row per slot rather than parallel arrays: dragging has to carry a
    /// slot's name and its icon together, and ForEach can only reorder what
    /// it can identify. Same shape as the Mac settings.
    struct ShortcutRow: Identifiable {
        let id = UUID()
        var name: String        // "" = empty slot
        var glyph: String       // "" = derive from the name
    }
    struct WebhookRow: Identifiable {
        let id = UUID()
        var url: String         // "" = empty slot
    }
    @Published var shortcutRows: [ShortcutRow]
    @Published var webhookRows: [WebhookRow]
    /// Cached shortcut names for the picker — iOS apps can't enumerate the
    /// Shortcuts library, so the list is imported from the clipboard by the
    /// helper shortcut; free-typed names merge in. (There is no Mac sync:
    /// nothing here ever read one, despite what the footer used to claim.)
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
        shortcutRows = (0..<6).map { i in
            ShortcutRow(name: model.shortcutSlots.indices.contains(i)
                              ? model.shortcutSlots[i] : "",
                        glyph: model.shortcutGlyphs.indices.contains(i)
                               ? model.shortcutGlyphs[i] : "")
        }
        webhookRows = (0..<6).map { i in
            WebhookRow(url: model.webhookSlots.indices.contains(i)
                            ? model.webhookSlots[i] : "")
        }
        // Slot names always appear in the picker, even if the cache is stale.
        for row in shortcutRows where !row.name.isEmpty && !knownShortcuts.contains(row.name) {
            knownShortcuts.append(row.name)
        }
    }

    func row(_ id: UUID) -> ShortcutRow? { shortcutRows.first { $0.id == id } }

    func shortcutPosition(of id: UUID) -> Int {
        (shortcutRows.firstIndex { $0.id == id } ?? 0) + 1
    }

    func setName(_ name: String, for id: UUID) {
        guard let i = shortcutRows.firstIndex(where: { $0.id == id }) else { return }
        shortcutRows[i].name = name
    }

    func setGlyph(_ glyph: String, for id: UUID) {
        guard let i = shortcutRows.firstIndex(where: { $0.id == id }) else { return }
        shortcutRows[i].glyph = glyph
    }

    /// Which quick-row button a webhook row will be: its place in the list.
    func position(of id: UUID) -> Int {
        (webhookRows.firstIndex { $0.id == id } ?? 0) + 1
    }

    /// What a row's circle draws: the chosen glyph, else the one its name
    /// suggests.
    static func glyph(for row: ShortcutRow) -> String {
        row.glyph.isEmpty ? SpeakerModel.guessedGlyph(for: row.name) : row.glyph
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
        for row in shortcutRows where !row.name.isEmpty && !merged.contains(row.name) {
            merged.append(row.name)
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
        model.setShortcutSlots(shortcutRows.map(\.name))
        model.setShortcutGlyphs(shortcutRows.map(\.glyph))
        model.setWebhookSlots(webhookRows.map(\.url))
        model.setSpeakerIP(ipText)
    }
}

struct SettingsSheet: View {
    @StateObject private var session: SettingsSheetSession
    @ObservedObject private var discovery: SpeakerDiscovery
    @Environment(\.dismiss) private var dismiss
    /// Raised by the sync shortcut's return trip: pull the names it left on
    /// the clipboard as soon as the sheet is up.
    @Binding var importOnAppear: Bool

    init(model: SpeakerModel, importOnAppear: Binding<Bool> = .constant(false)) {
        _session = StateObject(wrappedValue: SettingsSheetSession(model: model))
        discovery = model.discovery
        _importOnAppear = importOnAppear
    }

    var body: some View {
        NavigationStack {
            Form {
                speakerSection
                handednessSection
                sourcesSection
                volumeSection
                radioSection
                shortcutSection
                webhookSection
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
        .onAppear {
            discovery.start()
            if importOnAppear {
                importOnAppear = false
                syncedCount = session.importShortcutsFromClipboard()
            }
        }
        .onDisappear { discovery.stop() }
        // Sync tapped from inside the sheet: it stayed on screen the whole
        // trip, so the return arrives here instead of at onAppear.
        .onReceive(NotificationCenter.default.publisher(for: .kefShortcutSyncReturned)) { _ in
            let n = session.importShortcutsFromClipboard()
            if n > 0 { syncedCount = n }
        }
    }

    /// How many names the last sync brought in, for the footer.
    @State private var syncedCount: Int?

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
            ForEach($session.shortcutRows) { $row in
                NavigationLink {
                    ShortcutPickerScreen(session: session, rowID: row.id)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(row.name.isEmpty
                                          ? Color.white.opacity(0.06)
                                          : Color.white.opacity(0.14))
                            Image(systemName: SettingsSheetSession.glyph(for: row))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(row.name.isEmpty ? .tertiary : .secondary)
                        }
                        .frame(width: 26, height: 26)
                        Text(row.name.isEmpty ? "—" : row.name)
                            .foregroundStyle(row.name.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                    }
                }
            }
            NavigationLink {
                SlotOrderScreen(session: session, kind: .shortcuts)
            } label: {
                Label("Reorder slots", systemImage: "arrow.up.arrow.down")
                    .font(.callout)
            }
            Button {
                // The helper collects the names, copies them, and opens us
                // back up — the import happens on the way in.
                if let url = URL(string:
                    "shortcuts://run-shortcut?name=KEF%20Control%20Sync") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Sync my shortcuts", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
            }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text(syncedCount.map { "Synced \($0) shortcut names." }
                 ?? ("Each slot appears as a button in the quick row and runs "
                     + "that Apple Shortcut. iOS can't read your Shortcuts "
                     + "library, so tap Sync: the KEF Control Sync shortcut "
                     + "hands the names over."))
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

extension SettingsSheet {
    var webhookSection: some View {
        Section {
            // A numbered circle like the quick-row buttons, with the URL
            // flowing left-aligned beside it; long URLs wrap.
            ForEach($session.webhookRows) { $row in
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(row.url.isEmpty
                                      ? Color.white.opacity(0.06)
                                      : Color.white.opacity(0.14))
                        Text("\(session.position(of: row.id))")
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(row.url.isEmpty ? .tertiary : .secondary)
                    }
                    .frame(width: 26, height: 26)
                    TextField("https://…", text: $row.url, axis: .vertical)
                        .font(.callout)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...4)
                }
            }
            NavigationLink {
                SlotOrderScreen(session: session, kind: .webhooks)
            } label: {
                Label("Reorder slots", systemImage: "arrow.up.arrow.down")
                    .font(.callout)
            }
        } header: {
            Text("Webhooks")
        } footer: {
            Text("Each slot appears as a button in the quick row "
                 + "and fires a GET request at its URL.")
        }
    }
}

/// Drag the six slots into order. A screen of its own: rows only drag in a
/// List's edit mode, and edit mode swallows the taps the settings rows need
/// for picking a shortcut or typing a URL.
struct SlotOrderScreen: View {
    @ObservedObject var session: SettingsSheetSession
    enum Kind { case shortcuts, webhooks }
    let kind: Kind

    private var shortcutRows: some View {
        ForEach(session.shortcutRows) { row in
            HStack(spacing: 12) {
                Image(systemName: SettingsSheetSession.glyph(for: row))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(row.name.isEmpty ? AnyShapeStyle(.tertiary)
                                                      : AnyShapeStyle(.secondary))
                    .frame(width: 22)
                Text(row.name.isEmpty ? "—" : row.name)
                    .foregroundStyle(row.name.isEmpty ? AnyShapeStyle(.secondary)
                                                      : AnyShapeStyle(Color.white))
                    .lineLimit(1)
            }
        }
        .onMove { session.shortcutRows.move(fromOffsets: $0, toOffset: $1) }
    }

    private var webhookRows: some View {
        ForEach(session.webhookRows) { row in
            HStack(spacing: 12) {
                Text("\(session.position(of: row.id))")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(row.url.isEmpty ? AnyShapeStyle(.tertiary)
                                                     : AnyShapeStyle(.secondary))
                    .frame(width: 22)
                Text(row.url.isEmpty ? "—" : row.url)
                    .foregroundStyle(row.url.isEmpty ? AnyShapeStyle(.secondary)
                                                     : AnyShapeStyle(Color.white))
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .onMove { session.webhookRows.move(fromOffsets: $0, toOffset: $1) }
    }

    var body: some View {
        List {
            // Each branch in its own property: a switch inside the List's
            // builder made the compiler reach for ForEach's Binding overload.
            if kind == .shortcuts { shortcutRows } else { webhookRows }
        }
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
    let rowID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var custom = ""
    @State private var importedCount: Int?

    private var filtered: [String] {
        let all = session.knownShortcuts.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return search.isEmpty ? all
                              : all.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            glyphSection
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
                        session.setName(name, for: rowID)
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
                Text("iOS apps can't read your Shortcuts library, so the list "
                     + "is imported. Tap Sync to run the helper shortcut, "
                     + "which copies your shortcut names over and hands them "
                     + "back here.")
            }
        }
        .searchable(text: $search, prompt: "Search shortcuts")
        .tint(Color.phoneAccent)
        .navigationTitle("Slot \(session.shortcutPosition(of: rowID))")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Icon grid. iOS keeps a Shortcut's own glyph to itself, so the button
    /// gets one of ours — automatic reads it off the name.
    private var glyphSection: some View {
        Section {
            Button {
                session.setGlyph("", for: rowID)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: SettingsSheetSession.glyph(
                              for: session.row(rowID) ?? .init(name: "", glyph: "")))
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 26)
                    Text("Automatic").foregroundStyle(.white)
                    Spacer()
                    if session.row(rowID)?.glyph.isEmpty ?? true {
                        Image(systemName: "checkmark").foregroundStyle(Color.phoneAccent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                     count: 6), spacing: 10) {
                ForEach(SpeakerModel.glyphChoices, id: \.self) { name in
                    let picked = session.row(rowID)?.glyph == name
                    Button {
                        session.setGlyph(name, for: rowID)
                    } label: {
                        Image(systemName: name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(picked ? AnyShapeStyle(Color.phoneAccent)
                                                    : AnyShapeStyle(.white))
                            .frame(width: 38, height: 38)
                            .background {
                                Circle().fill(picked ? Color.phoneAccent.opacity(0.22)
                                                     : Color.white.opacity(0.07))
                            }
                            .overlay {
                                if picked {
                                    Circle().strokeBorder(Color.phoneAccent, lineWidth: 1)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Icon")
        }
    }

    private func row(name: String, label: String) -> some View {
        Button {
            session.setName(name, for: rowID)
            dismiss()
        } label: {
            HStack {
                Text(label)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                if session.row(rowID)?.name == name {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.phoneAccent)
                }
            }
            .contentShape(Rectangle())
        }
        // Plain: the default list-button style tints labels blue.
        .buttonStyle(.plain)
    }
}

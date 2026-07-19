import SwiftUI
import AppKit
import Combine

// MARK: - Settings window (one tabbed window; grouped forms like System Settings)

/// Hosts the AppKit shortcut recorder inside SwiftUI so the capture logic —
/// the key monitor, esc/delete handling, the one-recorder-at-a-time rule —
/// is reused verbatim rather than rewritten.
struct ShortcutRecorderView: NSViewRepresentable {
    let button: ShortcutRecorderButton
    func makeNSView(context: Context) -> ShortcutRecorderButton { button }
    func updateNSView(_ view: ShortcutRecorderButton, context: Context) {}
}

/// Everything the Settings window stages. Values are copied in when the window
/// opens and written back only on Save — the same semantics the old
/// per-feature windows had, now shared by every tab.
@MainActor
final class SettingsSession: ObservableObject {
    let model: SpeakerModel
    /// One live AppKit recorder per action; Save reads their staged shortcuts.
    let recorders: [HotKeyAction: ShortcutRecorderButton]

    struct SourceRow: Identifiable {
        let id: String
        let name: String
        var visible: Bool
    }

    @Published var ipText: String
    @Published var sourceRows: [SourceRow]
    @Published var presetValues: [String]        // "" = empty slot
    @Published var volumeStep: String
    @Published var showVolumeInMenuBar: Bool
    @Published var radioSelection: [String]      // station path, "" = empty
    @Published var stations: [SpeakerModel.RadioStation] = []
    @Published var stationsLoaded = false

    init(model: SpeakerModel) {
        self.model = model
        var recs: [HotKeyAction: ShortcutRecorderButton] = [:]
        for action in HotKeyAction.allCases {
            let button = ShortcutRecorderButton()
            button.configure(initial: ShortcutStore.shortcut(action))
            recs[action] = button
        }
        recorders = recs
        ipText = model.speakerIP
        sourceRows = model.orderedSources.map {
            SourceRow(id: $0.id, name: $0.name,
                      visible: !model.hiddenSources.contains($0.id))
        }
        presetValues = model.presetSlots.map { $0 > 0 ? String($0) : "" }
        volumeStep = String(ShortcutStore.volumeStep)
        showVolumeInMenuBar = model.showVolumeInMenuBar
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
        for (action, recorder) in recorders {
            ShortcutStore.setShortcut(action, recorder.shortcut)
        }
        if let step = Int(volumeStep) { ShortcutStore.setVolumeStep(step) }
        model.setPresetSlots(presetValues.map { Int($0) ?? 0 })
        model.showVolumeInMenuBar = showVolumeInMenuBar
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
        model.setSpeakerIP(ipText)
    }
}

struct SettingsView: View {
    @ObservedObject var session: SettingsSession
    @ObservedObject var discovery: SpeakerDiscovery
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                speakerTab
                    .tabItem { Label("Speaker", systemImage: "hifispeaker.2") }
                sourcesTab
                    .tabItem { Label("Sources", systemImage: "arrow.up.arrow.down") }
                radioTab
                    .tabItem { Label("Radio", systemImage: "radio") }
                volumeTab
                    .tabItem { Label("Volume", systemImage: "speaker.wave.2") }
                hotkeysTab
                    .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            }
            .padding(12)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 540)
    }

    // MARK: tabs

    private var speakerTab: some View {
        Form {
            Section("Speakers on your network") {
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
                                Text("\(found.model.isEmpty ? "KEF" : found.model) · \(found.ip)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if found.ip == session.ipText {
                                // Not appAccent: that is white now, invisible
                                // in this light window.
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.primary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Address") {
                TextField("IP address or hostname", text: $session.ipText)
            }
        }
        .formStyle(.grouped)
        .onAppear { discovery.start() }
    }

    private var sourcesTab: some View {
        // A List, not a Form: grouped Forms don't support row dragging, and
        // drag-to-reorder beats the old type-a-number ordering.
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(session.sourceRows) { row in
                    HStack {
                        Text(row.name)
                        Spacer()
                        Toggle("", isOn: visibleBinding(row.id))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { session.sourceRows.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered)
            Text("Drag to reorder — the panel shows inputs in this order.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
        .padding(16)
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

    private var radioTab: some View {
        Form {
            if !session.stationsLoaded {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading stations from the speaker…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    ForEach(0..<SpeakerModel.radioSlotCount, id: \.self) { i in
                        Picker("Slot \(i + 1)", selection: $session.radioSelection[i]) {
                            Text("—").tag("")
                            ForEach(session.stations, id: \.path) { station in
                                Text(station.title).tag(station.path)
                            }
                        }
                    }
                } footer: {
                    Text("Stations come from the speaker's radio history and "
                         + "favourites — play one in KEF Connect once and it "
                         + "appears here.")
                }
            }
        }
        .formStyle(.grouped)
        .task { if !session.stationsLoaded { await session.loadStations() } }
    }

    private var volumeTab: some View {
        Form {
            Section("Presets · value and hotkey") {
                ForEach(Array(HotKeyAction.presetActions.enumerated()), id: \.offset) { i, action in
                    HStack(spacing: 8) {
                        Text("Preset \(i + 1)")
                            .frame(width: 64, alignment: .leading)
                        // Empty label + prompt, not TextField("—", …): inside a
                        // Form the title renders as a leading row label, which
                        // put a stray dash before every field.
                        TextField("", text: $session.presetValues[i], prompt: Text("—"))
                            .labelsHidden()
                            .multilineTextAlignment(.center)
                            .frame(width: 44)
                        Spacer()
                        recorder(for: action)
                    }
                }
            }
            Section {
                LabeledContent("Volume step") {
                    TextField("", text: $session.volumeStep)
                        .labelsHidden()
                        .multilineTextAlignment(.center)
                        .frame(width: 44)
                }
                Toggle("Show volume in menu bar", isOn: $session.showVolumeInMenuBar)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    private var hotkeysTab: some View {
        Form {
            Section {
                ForEach(HotKeyAction.mediaActions, id: \.self) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        recorder(for: action)
                    }
                }
            } footer: {
                Text("Click a shortcut, then press the key combo — Esc cancels, "
                     + "Delete clears. Hotkeys always control the speaker, even "
                     + "with the panel closed.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func recorder(for action: HotKeyAction) -> some View {
        if let button = session.recorders[action] {
            HStack(spacing: 4) {
                ShortcutRecorderView(button: button)
                    .frame(width: 140, height: 22)
                Button {
                    button.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onFinish: () -> Void
    private let session: SettingsSession

    /// `onFinish` re-registers the global hotkeys; it runs on every close
    /// (Save or Cancel) because they are suspended while the window is open so
    /// any combo can be re-recorded.
    init(model: SpeakerModel, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        self.session = SettingsSession(model: model)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "KEF Control Settings"
        super.init(window: win)
        win.delegate = self
        let view = SettingsView(
            session: session,
            discovery: model.discovery,
            onSave: { [weak self] in
                self?.session.save()
                self?.window?.close()
            },
            onCancel: { [weak self] in self?.window?.close() }
        )
        win.contentView = NSHostingView(rootView: view)
        win.setContentSize(NSSize(width: 560, height: 540))
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        ShortcutRecorderButton.endActiveRecording()
        session.model.discovery.stop()
        onFinish()
    }
}

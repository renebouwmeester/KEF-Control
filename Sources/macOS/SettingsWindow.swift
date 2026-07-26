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
    /// One row per slot. A struct with a stable id, not two parallel arrays:
    /// dragging has to carry a slot's name and its icon together, and ForEach
    /// can only reorder something it can identify.
    struct ShortcutRow: Identifiable {
        let id = UUID()
        var name: String        // "" = empty slot
        var glyph: String       // "" = derive from the name
    }
    @Published var shortcutRows: [ShortcutRow]
    /// Same identified-row trick as the shortcut slots, so a URL can be
    /// dragged into another position.
    struct WebhookRow: Identifiable {
        let id = UUID()
        var url: String         // "" = empty slot
    }
    @Published var webhookRows: [WebhookRow]
    /// Installed shortcuts, from `shortcuts list`; slot names not in the
    /// list are merged in so they survive a rename on the Shortcuts side.
    @Published var shortcutNames: [String] = []
    @Published var shortcutsLoaded = false
    private var lastShortcutLoad = Date.distantPast

    /// Re-read on the way back from the Shortcuts app, but not on every
    /// window activation in a row.
    func refreshShortcutsIfStale() {
        guard Date().timeIntervalSince(lastShortcutLoad) > 2 else { return }
        Task { await loadShortcuts() }
    }
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

    /// What a row's button draws: the chosen glyph, else the one its name
    /// suggests.
    static func glyph(for row: ShortcutRow) -> String {
        row.glyph.isEmpty ? SpeakerModel.guessedGlyph(for: row.name) : row.glyph
    }

    /// `shortcuts list` enumerates the user's shortcuts — a luxury iOS
    /// doesn't offer. Cheap (~30ms even with a couple of hundred), so it
    /// re-runs whenever the window comes forward rather than caching for the
    /// lifetime of the session.
    func loadShortcuts() async {
        let names: [String] = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                task.arguments = ["list"]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let out = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(returning: out.split(separator: "\n").map(String.init))
                } catch {
                    cont.resume(returning: [])
                }
            }
        }
        var merged = names
        for row in shortcutRows where !row.name.isEmpty && !merged.contains(row.name) {
            merged.append(row.name)
        }
        // `shortcuts list` returns them in the Shortcuts app's own order.
        shortcutNames = merged.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        shortcutsLoaded = true
        lastShortcutLoad = Date()
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
        model.setShortcutSlots(shortcutRows.map(\.name))
        model.setShortcutGlyphs(shortcutRows.map(\.glyph))
        model.setWebhookSlots(webhookRows.map(\.url))
        model.setSpeakerIP(ipText)
    }
}

struct SettingsView: View {
    @ObservedObject var session: SettingsSession
    @ObservedObject var discovery: SpeakerDiscovery
    let onSave: () -> Void
    let onCancel: () -> Void
    /// Which row's icon grid is open, if any.
    @State private var glyphPopover: UUID?

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                speakerTab
                    .tabItem { Label("Speaker", systemImage: "hifispeaker.2") }
                sourcesTab
                    .tabItem { Label("Sources", systemImage: "arrow.up.arrow.down") }
                volumeTab
                    .tabItem { Label("Volume", systemImage: "speaker.wave.2") }
                radioTab
                    .tabItem { Label("Radio", systemImage: "radio") }
                shortcutsTab
                    .tabItem { Label("Shortcuts", systemImage: "bolt") }
                webhooksTab
                    .tabItem { Label("Webhooks", systemImage: "link") }
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
        .frame(width: 720, height: 540)
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
                    // 6, like the panel row and the iOS app; a 7th slot from the
                    // old layout keeps its stored value but isn't edited.
                    ForEach(0..<6, id: \.self) { i in
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

    private var webhooksTab: some View {
        // A List, not a Form: grouped Forms don't support row dragging.
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach($session.webhookRows) { $row in
                    HStack(spacing: 8) {
                        Text("\(webhookPosition(row.id))")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        TextField("", text: $row.url, prompt: Text("https://…"))
                            .labelsHidden()
                    }
                    .padding(.vertical, 2)
                }
                .onMove { session.webhookRows.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered)
            Text("Drag to reorder — the numbered buttons in the quick row "
                 + "follow this order, and each fires a GET at its URL.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
        .padding(16)
    }

    private func webhookPosition(_ id: UUID) -> Int {
        (session.webhookRows.firstIndex { $0.id == id } ?? 0) + 1
    }

    private var shortcutsTab: some View {
        // A List, not a Form, for the same reason as the sources tab: grouped
        // Forms don't support row dragging.
        VStack(alignment: .leading, spacing: 8) {
            if !session.shortcutsLoaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your shortcuts…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($session.shortcutRows) { $row in
                        HStack(spacing: 8) {
                            glyphButton(row: $row)
                            Picker("", selection: $row.name) {
                                Text("—").tag("")
                                ForEach(session.shortcutNames, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .labelsHidden()
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { session.shortcutRows.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.bordered)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Drag to reorder — the quick row follows this order. "
                         + "The icon is ours to choose: neither macOS nor iOS "
                         + "lets an app read a shortcut's own glyph.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Reload") { Task { await session.loadShortcuts() } }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Re-read the list from the Shortcuts app")
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(16)
        .task { if !session.shortcutsLoaded { await session.loadShortcuts() } }
        // Add a shortcut, switch back here, and it's in the list.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshShortcutsIfStale()
        }
    }

    /// The row's icon, with a grid to change it. A popover, not a Menu:
    /// macOS drops images from menu rows, so a menu of glyphs would be blank.
    private func glyphButton(row: Binding<SettingsSession.ShortcutRow>) -> some View {
        let id = row.wrappedValue.id
        return Button {
            glyphPopover = glyphPopover == id ? nil : id
        } label: {
            ZStack {
                Circle().fill(Color.primary.opacity(0.07))
                Image(systemName: SettingsSession.glyph(for: row.wrappedValue))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(row.wrappedValue.name.isEmpty
                                     ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Icon for this slot")
        .popover(isPresented: Binding(get: { glyphPopover == id },
                                      set: { if !$0 { glyphPopover = nil } }),
                 arrowEdge: .bottom) {
            glyphGrid(row: row)
        }
    }

    private func glyphGrid(row: Binding<SettingsSession.ShortcutRow>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                row.wrappedValue.glyph = ""
                glyphPopover = nil
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: SpeakerModel.guessedGlyph(for: row.wrappedValue.name))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 18)
                    Text("Automatic").font(.callout)
                    if row.wrappedValue.glyph.isEmpty {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.appAccent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6),
                                     count: 8), spacing: 6) {
                ForEach(SpeakerModel.glyphChoices, id: \.self) { name in
                    let picked = row.wrappedValue.glyph == name
                    Button {
                        row.wrappedValue.glyph = name
                        glyphPopover = nil
                    } label: {
                        Image(systemName: name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(picked ? AnyShapeStyle(Color.appAccent)
                                                    : AnyShapeStyle(.primary))
                            .frame(width: 28, height: 28)
                            .background {
                                Circle().fill(picked ? Color.appAccent.opacity(0.20)
                                                     : Color.primary.opacity(0.06))
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var volumeTab: some View {
        Form {
            Section("Presets · value and hotkey") {
                // 6, like the panel row and the iOS app (preset 7's hotkey
                // action still exists for old bindings, just isn't offered).
                ForEach(Array(HotKeyAction.presetActions.prefix(6).enumerated()), id: \.offset) { i, action in
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
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
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
        win.setContentSize(NSSize(width: 720, height: 540))
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        ShortcutRecorderButton.endActiveRecording()
        session.model.discovery.stop()
        onFinish()
    }
}

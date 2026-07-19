// Global hotkeys (Carbon, so no accessibility permission) and the AppKit
// shortcut-recorder button the Settings window wraps.
import AppKit
import Carbon.HIToolbox

extension NSColor {
    static let appAccent = NSColor(srgbRed: 0.5961, green: 0.6588, blue: 0.8510, alpha: 1)
}

// MARK: - Global hotkeys (customizable)

enum HotKeyAction: String, CaseIterable {
    case togglePanel, volumeUp, volumeDown, toggleMute, playPause, next, previous
    case preset1, preset2, preset3, preset4, preset5, preset6, preset7

    static let mediaActions: [HotKeyAction] =
        [.togglePanel, .volumeUp, .volumeDown, .toggleMute, .playPause, .next, .previous]
    static let presetActions: [HotKeyAction] =
        [.preset1, .preset2, .preset3, .preset4, .preset5, .preset6, .preset7]

    /// 0-based preset slot index, or nil for non-preset actions.
    var presetIndex: Int? {
        HotKeyAction.presetActions.firstIndex(of: self)
    }

    var title: String {
        switch self {
        case .togglePanel: return "Show / Hide Player"
        case .volumeUp:    return "Volume Up"
        case .volumeDown:  return "Volume Down"
        case .toggleMute:  return "Toggle Mute"
        case .playPause:   return "Play / Pause"
        case .next:        return "Next Track"
        case .previous:    return "Previous Track"
        default:           return "Preset \((presetIndex ?? 0) + 1)"
        }
    }

    /// Stable Carbon hot-key id.
    var id: UInt32 { UInt32(HotKeyAction.allCases.firstIndex(of: self)! + 1) }

    /// Nothing is bound out of the box. This app is designed to sit ALONGSIDE
    /// KEF Audio, which owns the ⌘⌥⌃ media combos; Carbon hot keys are
    /// first-come-first-served, so any shared default would just leave one
    /// app's binding silently dead. Assign what you want in
    /// Hotkeys & Volume Presets….
    var defaultShortcut: Shortcut? { nil }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier flags
    var label: String       // display label for the key itself

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + label
    }

    /// Build from an NSEvent keyDown; nil if no non-shift modifier is held.
    static func from(_ event: NSEvent) -> Shortcut? {
        var carbon: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.command) { carbon |= UInt32(cmdKey) }
        if f.contains(.option) { carbon |= UInt32(optionKey) }
        if f.contains(.control) { carbon |= UInt32(controlKey) }
        if f.contains(.shift) { carbon |= UInt32(shiftKey) }
        // require at least one of cmd/opt/ctrl so global keys don't hijack typing
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: carbon,
                        label: Self.label(for: event))
    }

    private static let special: [Int: String] = [
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_Space: "␣", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
    ]

    private static func label(for event: NSEvent) -> String {
        if let sp = special[Int(event.keyCode)] { return sp }
        let ch = event.charactersIgnoringModifiers ?? ""
        return ch.uppercased()
    }
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) { handlers[id]?() }

    /// Temporarily unregister every hotkey (so combos can be re-recorded).
    /// Handlers are kept; call the app's apply routine to restore them.
    func suspend() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    func register(_ action: HotKeyAction, _ shortcut: Shortcut?, handler: @escaping () -> Void) {
        installHandler()
        if let ref = refs[action.id] { UnregisterEventHotKey(ref); refs[action.id] = nil }
        handlers[action.id] = handler
        guard let shortcut else { return }
        var ref: EventHotKeyRef?
        let hotID = EventHotKeyID(signature: OSType(0x4B45_4668), id: action.id)  // "KEFh"
        if RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotID,
                               GetApplicationEventTarget(), 0, &ref) == noErr {
            refs[action.id] = ref
        }
    }
}

enum ShortcutStore {
    static func shortcut(_ action: HotKeyAction) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: "hotkey.\(action.rawValue)") else {
            return action.defaultShortcut
        }
        if data.isEmpty { return nil }   // explicitly cleared
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    static func setShortcut(_ action: HotKeyAction, _ shortcut: Shortcut?) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        UserDefaults.standard.set(data, forKey: "hotkey.\(action.rawValue)")
    }

    static var volumeStep: Int {
        let v = UserDefaults.standard.integer(forKey: "VolumeStep")
        return v > 0 ? v : 1
    }
    static func setVolumeStep(_ v: Int) {
        UserDefaults.standard.set(max(1, min(50, v)), forKey: "VolumeStep")
    }
}

/// A button that records a global shortcut into a pending value (not persisted
/// until the window's Save). Click, then press the combo.
final class ShortcutRecorderButton: NSButton {
    static weak var active: ShortcutRecorderButton?
    static func endActiveRecording() { active?.stop() }

    private(set) var shortcut: Shortcut?   // staged value
    private var recording = false
    private var monitor: Any?

    func configure(initial: Shortcut?) {
        shortcut = initial
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        updateAppearance()
    }

    private func updateAppearance() {
        if recording {
            title = "Recording…"
            bezelColor = .appAccent
        } else {
            bezelColor = nil
            title = shortcut?.display ?? "Press keys"
        }
    }

    @objc private func startRecording() {
        guard !recording else { return }
        ShortcutRecorderButton.active?.stop()   // only one records at a time
        ShortcutRecorderButton.active = self
        recording = true
        updateAppearance()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stop(); return nil }              // esc: cancel
            if event.keyCode == 51 || event.keyCode == 117 {                // delete: clear
                self.shortcut = nil; self.stop(); return nil
            }
            if let sc = Shortcut.from(event) {
                self.shortcut = sc; self.stop()
            }
            return nil   // swallow everything while recording
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if ShortcutRecorderButton.active === self { ShortcutRecorderButton.active = nil }
        updateAppearance()
    }

    func clear() { stop(); shortcut = nil; updateAppearance() }
    @objc func clearAction() { clear() }
}

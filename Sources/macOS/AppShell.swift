import SwiftUI
import AppKit
import Combine

// MARK: - Menu bar label (SwiftUI, so icon and digits center-align)

struct MenuBarLabel: View {
    @ObservedObject var model: SpeakerModel

    /// Every icon the label can show; used only to reserve width.
    private static let iconVariants = ["hifispeaker.2.fill", "hifispeaker.2",
                                       "speaker.slash.fill", "power"]

    /// Icon alone, or icon + value. Building both from one place keeps the
    /// hidden width-reservation copies identical to the visible label.
    private static func labelText(icon: String, value: String?) -> Text {
        guard let value else { return Text(Image(systemName: icon)) }
        return Text("\(Image(systemName: icon)) \(Text(value).monospacedDigit())")
    }

    var body: some View {
        // The status item is exactly as wide as this label, and macOS lays menu
        // bar items out from the right — so a narrower state used to shift this
        // icon and everything left of it. Reserve the widest state's width and
        // keep the icon leading: the icon then holds its place in every state.
        // With the volume hidden the reservation still matters: the icon
        // variants are not all the same width either, so the widest is
        // reserved to stop the item shifting as the state changes.
        ZStack(alignment: .leading) {
            ForEach(Self.iconVariants, id: \.self) { icon in
                Self.labelText(icon: icon,
                               value: model.showVolumeInMenuBar ? "88" : nil)
                    .hidden()
            }
            Self.labelText(icon: model.menuBarIcon,
                           value: model.showVolumeInMenuBar ? model.menuBarTitle : nil)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 2)
        .allowsHitTesting(false)
    }
}

// MARK: - App shell: custom status item + panel flush with the menu bar

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = SpeakerModel()
    private var statusItem: NSStatusItem!
    private var panel: KeyablePanel!
    private var hosting: NSHostingView<PlayerView>!
    private var barLabel: NSHostingView<MenuBarLabel>!
    private var stateSink: AnyCancellable?
    private var outsideClickMonitor: Any?
    private var lastPanelClose = Date.distantPast
    private var settingsWC: SettingsWindowController?


    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            barLabel = NSHostingView(rootView: MenuBarLabel(model: model))
            barLabel.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(barLabel)
            NSLayoutConstraint.activate([
                barLabel.topAnchor.constraint(equalTo: button.topAnchor),
                barLabel.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                barLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                barLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            ])
        }

        // A fixed-size transparent canvas. The panel never resizes, so the
        // hosting view's bounds always match the SwiftUI root: nothing can
        // overflow, and NSHostingView (which centres overflowing content, and
        // so slid every row) never gets the chance. The card, its rounded
        // corners and its shadow are all drawn — and animated — by SwiftUI.
        hosting = NSHostingView(rootView: PlayerView(model: model))
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: PanelMetrics.width + PanelMetrics.shadowMargin * 2,
                                height: PanelMetrics.canvasHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // SwiftUI draws it, so it tracks the card
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)  // always dark
        panel.contentView = hosting

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.panel.isVisible == true {  // esc
                self?.closePanel()
                return nil
            }
            return event
        }

        stateSink = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.stateChanged() }
        }
        loadPersistedAnchor()
        stateChanged()
        scheduleAnchorWarmup()
        applyHotKeys()
    }

    /// (Re)register all global hotkeys from the saved bindings. Carbon hot keys
    /// need no accessibility permission, unlike NSEvent global monitors.
    private func applyHotKeys() {
        let hk = HotKeyCenter.shared
        hk.register(.togglePanel, ShortcutStore.shortcut(.togglePanel)) { [weak self] in
            self?.togglePanel()
        }
        hk.register(.volumeUp, ShortcutStore.shortcut(.volumeUp)) { [weak self] in
            guard let m = self?.model, m.reachable, !m.isStandby else { return }
            m.setVolumeOnKEF(m.volume + ShortcutStore.volumeStep)
        }
        hk.register(.volumeDown, ShortcutStore.shortcut(.volumeDown)) { [weak self] in
            guard let m = self?.model, m.reachable, !m.isStandby else { return }
            m.setVolumeOnKEF(m.volume - ShortcutStore.volumeStep)
        }
        hk.register(.toggleMute, ShortcutStore.shortcut(.toggleMute)) { [weak self] in
            self?.model.toggleMute()
        }
        hk.register(.playPause, ShortcutStore.shortcut(.playPause)) { [weak self] in
            self?.model.control("pause")
        }
        hk.register(.next, ShortcutStore.shortcut(.next)) { [weak self] in
            self?.model.control("next")
        }
        hk.register(.previous, ShortcutStore.shortcut(.previous)) { [weak self] in
            self?.model.control("previous")
        }
        for action in HotKeyAction.presetActions {
            hk.register(action, ShortcutStore.shortcut(action)) { [weak self] in
                guard let m = self?.model, m.reachable, !m.isStandby,
                      let i = action.presetIndex, i < m.presetSlots.count else { return }
                let v = m.presetSlots[i]
                if v > 0 { m.setVolumeOnKEF(v) }
            }
        }
    }

    private func stateChanged() {
        statusItem.length = barLabel.fittingSize.width
        refreshAnchor()
        if panel.isVisible { positionPanel() }
    }

    /// Left click toggles the panel; right click shows a menu with Quit.
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            let menu = NSMenu()
            let settings = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings), keyEquivalent: ",")
            settings.target = self
            menu.addItem(settings)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quit KEF Control",
                                  action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil  // so left clicks keep toggling the panel
        } else {
            togglePanel()
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openSettings() {
        // Suspend global hotkeys while the window is open so any combo —
        // including currently bound ones — can be re-recorded; onFinish
        // restores them from the saved bindings on close.
        HotKeyCenter.shared.suspend()
        settingsWC = SettingsWindowController(model: model) { [weak self] in self?.applyHotKeys() }
        NSApp.activate(ignoringOtherApps: true)
        settingsWC?.window?.center()
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc fileprivate func togglePanel() {
        if panel.isVisible {
            closePanel()
        } else if Date().timeIntervalSince(lastPanelClose) > 0.25 {
            // The guard stops the click on the status item from reopening the
            // panel it just closed by stealing key status (resign → close → action).
            openPanel()
        }
    }

    private func openPanel() {
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        // The status button's window can lack screen geometry until the panel
        // is on screen (macOS hosts menu bar icons out-of-process); re-anchor.
        positionPanel()
        DispatchQueue.main.async { [weak self] in self?.positionPanel() }
        for delay in [0.05, 0.15, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.positionPanel()
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        lastPanelClose = Date()
        panel.orderOut(nil)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }


    private var cachedAnchor: (bottom: CGFloat, left: CGFloat)?

    private func refreshAnchor() {
        if let a = statusItemAnchor() {
            cachedAnchor = a
            UserDefaults.standard.set(a.bottom, forKey: "PanelAnchorBottom")
            UserDefaults.standard.set(a.left, forKey: "PanelAnchorLeft")
        }
    }

    /// Restore the last known-good icon position so a relaunch doesn't fall back
    /// to the screen corner before a fresh frame is available. Menu bar layout is
    /// stable across launches, so this is right the moment the app starts.
    private func loadPersistedAnchor() {
        let d = UserDefaults.standard
        if d.object(forKey: "PanelAnchorBottom") != nil {
            cachedAnchor = (d.double(forKey: "PanelAnchorBottom"), d.double(forKey: "PanelAnchorLeft"))
        }
    }

    /// Warm the cached anchor right after launch — the menu bar icon may not be
    /// placed yet (worse with several menu bar apps starting together), so the
    /// first open would otherwise fall back to the screen corner.
    private func scheduleAnchorWarmup() {
        for delay in [0.2, 0.6, 1.2, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshAnchor()
            }
        }
    }

    /// Where the status icon actually is: the in-process button window when it
    /// has valid geometry, else the window server's answer (the in-process
    /// window can report stale frames on macOS 27's out-of-process menu bar).
    private func statusItemAnchor() -> (bottom: CGFloat, left: CGFloat)? {
        // The proxy window sometimes reports an "unplaced" default slot flush
        // against the screen's right edge (x = screenWidth - iconWidth). A real
        // status icon is never there — Control Center and friends occupy that
        // zone — so treat it as unknown and keep the last known-good position.
        if let w = statusItem.button?.window, let s = w.screen,
           w.frame.width > 0, w.frame.minY > s.frame.midY,
           w.frame.maxX < s.frame.maxX - 1 {
            return (w.frame.minY, w.frame.minX)
        }
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let pid = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32, owner == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == NSWindow.Level.statusBar.rawValue,
                  let boundsDict = info[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary),
                  bounds.width > 0 else { continue }
            // CG coordinates are top-left origin; convert to Cocoa
            return (primaryHeight - bounds.maxY, bounds.minX)
        }
        return nil
    }

    /// Park the fixed-size canvas so the card's top-left sits exactly on the
    /// status icon's anchor. The size never depends on the content, so nothing
    /// here moves while the presets row animates.
    private func positionPanel() {
        if let anchor = statusItemAnchor() { cachedAnchor = anchor }
        guard let fallbackScreen = NSScreen.main ?? NSScreen.screens.first else { return }
        let top = (cachedAnchor?.bottom ?? fallbackScreen.visibleFrame.maxY).rounded()
        let left = cachedAnchor?.left ?? (fallbackScreen.frame.maxX - PanelMetrics.width)
        let screen = NSScreen.screens.first {
            $0.frame.contains(CGPoint(x: left + 1, y: top - 1))
        } ?? fallbackScreen
        let cardX = max(screen.frame.minX, min(left, screen.frame.maxX - PanelMetrics.width))
        let height = min(PanelMetrics.canvasHeight, top - screen.frame.minY)
        panel.setFrame(
            NSRect(x: (cardX - PanelMetrics.shadowMargin).rounded(),
                   y: (top - height).rounded(),
                   width: PanelMetrics.width + PanelMetrics.shadowMargin * 2,
                   height: height.rounded()),
            display: true
        )
    }
}

@main
struct KEFMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

import AppKit
import ServiceManagement
import SwiftUI

final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The settings that require a new DockView when they change.
struct DockLayout: Equatable {
    var edge: DockEdge
    var alignment: DockAlignment
    var iconSize: CGFloat
    var magnification: Bool
}

/// One dock window pinned to one edge of one display.
final class DockController {
    var screen: NSScreen
    let key: String
    let layout: DockLayout
    let panel = DockPanel()
    let view: DockView
    private(set) var shown = true
    private var lastInside = Date()

    init(screen: NSScreen, layout: DockLayout) {
        self.screen = screen
        self.key = Displays.key(screen)
        self.layout = layout
        view = DockView(iconSize: layout.iconSize, magnification: layout.magnification,
                        edge: layout.edge, alignment: layout.alignment, displayKey: key)
        panel.contentView = view
        view.onSizeChange = { [weak self] in self?.reposition() }
        refreshItems()
        reposition()
        panel.orderFrontRegardless()
        if ConfigStore.shared.autoHide { setShown(false, animated: false) }
    }

    func refreshItems() {
        view.setItems(DockModel.shared.items(for: ConfigStore.shared.config(for: key)))
    }

    func reposition() {
        let s = view.preferredSize
        let p = screen.visibleFrame
        let m: CGFloat = 4
        var o = NSPoint.zero
        switch layout.edge {
        case .bottom: o.y = p.minY + m
        case .top: o.y = p.maxY - s.height - m
        case .left: o.x = p.minX + m
        case .right: o.x = p.maxX - s.width - m
        }
        if layout.edge.isVertical {
            switch layout.alignment {
            case .start: o.y = p.maxY - s.height - m
            case .center: o.y = p.midY - s.height / 2
            case .end: o.y = p.minY + m
            }
        } else {
            switch layout.alignment {
            case .start: o.x = p.minX + m
            case .center: o.x = p.midX - s.width / 2
            case .end: o.x = p.maxX - s.width - m
            }
        }
        panel.setFrame(NSRect(origin: NSPoint(x: round(o.x), y: round(o.y)), size: s), display: true)
    }

    func close() { panel.orderOut(nil) }

    func setShown(_ show: Bool, animated: Bool = true) {
        guard show != shown else { return }
        shown = show
        panel.ignoresMouseEvents = !show
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.18 : 0
            panel.animator().alphaValue = show ? 1 : 0
        }
    }

    /// Called ~30x a second while auto-hide is on.
    func autoHideTick(mouse p: NSPoint) {
        let f = screen.frame
        let dock = panel.convertToScreen(view.convert(view.activeRect, to: nil))
        let onScreen = f.contains(p) || p.x == f.maxX || p.y == f.maxY
        let atEdge: Bool
        switch layout.edge {
        case .bottom: atEdge = p.y <= f.minY + 2 && p.x >= dock.minX - 40 && p.x <= dock.maxX + 40
        case .top: atEdge = p.y >= f.maxY - 2 && p.x >= dock.minX - 40 && p.x <= dock.maxX + 40
        case .left: atEdge = p.x <= f.minX + 2 && p.y >= dock.minY - 40 && p.y <= dock.maxY + 40
        case .right: atEdge = p.x >= f.maxX - 2 && p.y >= dock.minY - 40 && p.y <= dock.maxY + 40
        }
        let inside = dock.insetBy(dx: -6, dy: -6).contains(p)

        if inside { lastInside = Date() }
        if !shown, onScreen, atEdge {
            lastInside = Date()
            setShown(true)
        } else if shown, !inside, Date().timeIntervalSince(lastInside) > 0.5 {
            setShown(false)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controllers: [CGDirectDisplayID: DockController] = [:]
    private var statusItem: NSStatusItem!
    private var autoHideTimer: Timer?
    private var screenCheckTimer: Timer?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockModel.shared.onChange = { [weak self] in
            self?.controllers.values.forEach { $0.refreshItems() }
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(configChanged), name: .multiDockConfigChanged, object: nil)
        nc.addObserver(self, selector: #selector(showSettings), name: .multiDockOpenSettings, object: nil)
        // The real Dock can hop between displays without a screen-change
        // notification, so re-check which display it's on every couple of seconds.
        screenCheckTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.syncControllers()
        }
        // Undoes a hide left over from a crash, or re-applies one.
        SystemDock.sync()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willPowerOff),
                                                          name: NSWorkspace.willPowerOffNotification, object: nil)
        setUpStatusItem()
        syncControllers()
        updateAutoHideTimer()
        Updater.shared.start()

        if !UserDefaults.standard.bool(forKey: "hasShownSettings") {
            UserDefaults.standard.set(true, forKey: "hasShownSettings")
            showSettings()
        }
    }

    /// Quitting MultiDock gives the user their macOS Dock back.
    func applicationWillTerminate(_ notification: Notification) {
        SystemDock.restore(restart: !isPoweringOff)
    }

    private var isPoweringOff = false
    @objc private func willPowerOff() { isPoweringOff = true }

    /// Opening the app again while it's running brings up Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: - Docks

    @objc private func screensChanged() { syncControllers(force: true) }

    @objc private func configChanged() {
        SystemDock.sync()
        syncControllers()
        controllers.values.forEach { $0.refreshItems() }
        updateAutoHideTimer()
    }

    private func layout(for screen: NSScreen) -> DockLayout {
        let store = ConfigStore.shared
        let c = store.config(for: Displays.key(screen))
        return DockLayout(edge: c.edge, alignment: c.alignment,
                          iconSize: store.iconSize, magnification: store.magnification)
    }

    private func syncControllers(force: Bool = false) {
        let targets = NSScreen.screens.filter(Displays.isEnabled)
        let ids = Set(targets.map(Displays.id))
        for (id, c) in controllers where !ids.contains(id) {
            c.close()
            controllers[id] = nil
        }
        for s in targets {
            let id = Displays.id(s)
            let layout = layout(for: s)
            if let c = controllers[id], c.layout == layout {
                if force || c.screen.frame != s.frame || c.screen.visibleFrame != s.visibleFrame {
                    c.screen = s
                    c.reposition()
                }
            } else {
                controllers[id]?.close()
                controllers[id] = DockController(screen: s, layout: layout)
            }
        }
    }

    // MARK: - Auto-hide

    private func updateAutoHideTimer() {
        let on = ConfigStore.shared.autoHide
        guard on != (autoHideTimer != nil) else { return }
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        if on {
            autoHideTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                let p = NSEvent.mouseLocation
                self?.controllers.values.forEach { $0.autoHideTick(mouse: p) }
            }
        } else {
            controllers.values.forEach { $0.setShown(true) }
        }
    }

    // MARK: - Settings window

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "MultiDock Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "MultiDock")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = ConfigStore.shared

        let settings = BlockMenuItem(title: "Settings…") { [weak self] in self?.showSettings() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())

        let autoHide = BlockMenuItem(title: "Auto-hide") { store.autoHide.toggle() }
        autoHide.state = store.autoHide ? .on : .off
        menu.addItem(autoHide)

        let hideDock = BlockMenuItem(title: "Hide macOS Dock") { store.hideSystemDock.toggle() }
        hideDock.state = store.hideSystemDock ? .on : .off
        menu.addItem(hideDock)

        menu.addItem(.separator())
        if let r = Updater.shared.available {
            menu.addItem(BlockMenuItem(title: "Update to MultiDock \(r.version)…") { Updater.shared.offer(r) })
        }
        let check = BlockMenuItem(title: "Check for Updates…") { Updater.shared.check(userInitiated: true) }
        check.isEnabled = !Updater.shared.isInstalling
        menu.addItem(check)
        let version = NSMenuItem(title: "Version \(Updater.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        menu.addItem(.separator())
        let quit = BlockMenuItem(title: "Quit MultiDock") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nTip: move MultiDock into your Applications folder first."
            alert.runModal()
        }
    }
}

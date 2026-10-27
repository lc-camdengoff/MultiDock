import AppKit

struct DockItem: Equatable {
    enum Kind: Equatable { case app, folder, trash, divider, window }

    let kind: Kind
    var url: URL? = nil
    var bundleID: String? = nil
    var name: String = ""
    var isRunning = false
    /// Kept in this dock (as opposed to only shown because it's running).
    var pinned = false
    /// For a minimized window's tile (`url` is then its app).
    var windowID: Int? = nil
    /// A minimized window's tile shows its picture instead of the app's icon.
    var hasPreview = false
    /// The Trash has something in it.
    var isFull = false

    static let divider = DockItem(kind: .divider)

    /// Same identity = same tile, even if the running state differs.
    func sameTile(as other: DockItem) -> Bool {
        kind == other.kind && url == other.url && bundleID == other.bundleID && pinned == other.pinned
            && windowID == other.windowID && hasPreview == other.hasPreview && isFull == other.isFull
    }
}

/// Knows the real Dock's pinned items (from com.apple.dock's preferences) and
/// the running apps, and builds each display's item list from its config.
final class DockModel {
    static let shared = DockModel()

    var onChange: (() -> Void)?

    private var pinnedApps: [DockItem] = []
    private var pinnedOthers: [DockItem] = []
    private var rawPrefs: NSArray?
    private var timer: Timer?
    private var iconCache: [String: NSImage] = [:]
    private var itemCache: [String: DockItem] = [:]

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willLaunchApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(self, selector: #selector(runningAppsChanged), name: name, object: nil)
        }
        MinimizedWindows.shared.onChange = { [weak self] in
            let ids = Set(MinimizedWindows.shared.windows.map(\.id))
            WindowPreviews.shared.keep(ids)
            self?.iconCache = self?.iconCache.filter { key, _ in
                !key.hasPrefix("preview#") || Int(key.dropFirst(8)).map(ids.contains) == true
            } ?? [:]
            self?.onChange?()
        }
        WindowPreviews.shared.onChange = { [weak self] in self?.onChange?() }
        reloadPinned()
        // The Dock doesn't broadcast pref changes, so check now and then for
        // pins added or removed in the real Dock.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.reloadPinnedIfChanged()
        }
        trashTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkTrash() }
        checkTrash()
    }

    // MARK: - Trash

    private var trashFull = false
    private var checkingTrash = false
    private var trashTimer: Timer?

    /// Re-checks whether the Trash has anything in it, e.g. after dropping files on it.
    func checkTrash() {
        guard !checkingTrash else { return }
        checkingTrash = true
        DispatchQueue.global(qos: .utility).async {
            let full = Self.trashHasItems()
            DispatchQueue.main.async {
                self.checkingTrash = false
                guard let full, full != self.trashFull else { return }
                self.trashFull = full
                self.onChange?()
            }
        }
    }

    /// Asks Finder, which counts every volume's Trash; macOS doesn't let apps
    /// read the Trash folder without Full Disk Access. That needs a one-time
    /// approval to control Finder, and until then this tries the folder.
    /// Runs off the main thread, since Finder can be slow to answer.
    private static func trashHasItems() -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Finder\" to count items of trash"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning, Date() < deadline { usleep(50_000) }
            if p.isRunning {
                p.terminate()
            } else if p.terminationStatus == 0 {
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if let count = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return count > 0 }
            }
        }
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: trash.path) else { return nil }
        return names.contains { $0 != ".DS_Store" }
    }

    @objc private func runningAppsChanged() { onChange?() }

    /// The real Dock's items, Finder first, as paths (used to seed custom lists).
    var mainDockPaths: [String] { (pinnedApps + pinnedOthers).compactMap { $0.url?.path } }

    func icon(for item: DockItem) -> NSImage {
        switch item.kind {
        case .trash:
            return NSImage(named: item.isFull ? NSImage.trashFullName : NSImage.trashEmptyName) ?? NSImage()
        case .divider:
            return NSImage()
        case .window:
            if item.hasPreview, let id = item.windowID, let preview = WindowPreviews.shared.cached(id) {
                return previewIcon(preview, id: id, app: item)
            }
            return windowIcon(for: item)
        case .app, .folder:
            guard let path = item.url?.path else { return NSImage() }
            if let cached = iconCache[path] { return cached }
            let img = NSWorkspace.shared.icon(forFile: path)
            img.size = NSSize(width: 256, height: 256)
            iconCache[path] = img
            return img
        }
    }

    /// A minimized window's tile: its app's icon with a small window badge.
    private func windowIcon(for item: DockItem) -> NSImage {
        guard let url = item.url else { return NSImage() }
        let key = url.path + "#window"
        if let cached = iconCache[key] { return cached }
        let appIcon = icon(for: DockItem(kind: .app, url: url))
        let symbol = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 56, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        let img = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { r in
            appIcon.draw(in: r.insetBy(dx: 24, dy: 24))
            let badge = NSRect(x: r.maxX - 108, y: 10, width: 98, height: 98)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 24, yRadius: 24).fill()
            if let symbol {
                let s = symbol.size
                symbol.draw(in: NSRect(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
        iconCache[key] = img
        return img
    }

    /// A minimized window's tile with its picture: the window, with the
    /// app's icon in the corner, like the macOS Dock.
    private func previewIcon(_ preview: NSImage, id: Int, app item: DockItem) -> NSImage {
        let key = "preview#\(id)"
        if let cached = iconCache[key] { return cached }
        let appIcon = icon(for: DockItem(kind: .app, url: item.url))
        let img = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { r in
            let s = preview.size
            let fit = min(236 / s.width, 236 / s.height)
            let w = s.width * fit, h = s.height * fit
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.set()
            preview.draw(in: NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            appIcon.draw(in: NSRect(x: r.maxX - 104, y: 0, width: 104, height: 104))
            return true
        }
        iconCache[key] = img
        return img
    }

    // MARK: - Real Dock's pinned items

    private func dockPrefs() -> NSArray {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let apps = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [Any] ?? []
        let others = CFPreferencesCopyAppValue("persistent-others" as CFString, "com.apple.dock" as CFString) as? [Any] ?? []
        return [apps, others] as NSArray
    }

    private func reloadPinnedIfChanged() {
        if dockPrefs() != rawPrefs {
            reloadPinned()
            onChange?()
        }
    }

    private func reloadPinned() {
        let prefs = dockPrefs()
        rawPrefs = prefs
        let apps = prefs[0] as? [[String: Any]] ?? []
        let others = prefs[1] as? [[String: Any]] ?? []

        let finder = DockItem(kind: .app,
                              url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                              bundleID: "com.apple.finder",
                              name: "Finder")
        pinnedApps = [finder] + apps.compactMap(parseTile).filter { $0.kind == .app }
        pinnedOthers = others.compactMap(parseTile).filter { $0.kind == .folder }
    }

    private func parseTile(_ entry: [String: Any]) -> DockItem? {
        guard let tile = entry["tile-data"] as? [String: Any],
              let file = tile["file-data"] as? [String: Any],
              let s = file["_CFURLString"] as? String else { return nil }
        let url: URL? = (file["_CFURLStringType"] as? Int == 15) ? URL(string: s) : URL(fileURLWithPath: s)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }

        let label = tile["file-label"] as? String ?? url.deletingPathExtension().lastPathComponent
        let type = entry["tile-type"] as? String
        if url.pathExtension == "app" {
            let bundleID = tile["bundle-identifier"] as? String ?? Bundle(url: url)?.bundleIdentifier
            return DockItem(kind: .app, url: url, bundleID: bundleID, name: label)
        }
        if type == "directory-tile" {
            return DockItem(kind: .folder, url: url, name: label)
        }
        return nil
    }

    /// A tile for a path saved in a custom list.
    func item(forPath path: String) -> DockItem? {
        if let cached = itemCache[path] { return cached }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        let item = url.pathExtension == "app"
            ? DockItem(kind: .app, url: url, bundleID: Bundle(url: url)?.bundleIdentifier, name: name)
            : DockItem(kind: .folder, url: url, name: FileManager.default.displayName(atPath: path))
        itemCache[path] = item
        return item
    }

    // MARK: - Assemble one display's dock

    /// `displayKey` is the display this dock is on, for its minimized windows.
    func items(for config: DisplayConfig, displayKey: String) -> [DockItem] {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))

        var kept: [DockItem]
        switch config.itemsMode {
        case .mirror: kept = pinnedApps + pinnedOthers
        case .custom: kept = config.customItems.compactMap { item(forPath: $0.path) }
        }
        kept = kept.map { item in
            var i = item
            i.pinned = true
            i.isRunning = item.bundleID.map(runningIDs.contains) ?? false
            return i
        }

        var result = kept.filter { $0.kind == .app }
        if config.showRunningApps {
            let keptIDs = Set(result.compactMap(\.bundleID))
            let extras = running.compactMap { app -> DockItem? in
                guard let id = app.bundleIdentifier, !keptIDs.contains(id), let url = app.bundleURL else { return nil }
                return DockItem(kind: .app, url: url, bundleID: id,
                                name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                isRunning: true)
            }
            if !extras.isEmpty {
                if !result.isEmpty { result.append(.divider) }
                result += extras
            }
        }

        var tail = kept.filter { $0.kind == .folder }
        // A window's tile goes on the dock of the display it was minimized
        // from; if that display has no dock (or it can't tell), on every dock.
        let docked = Set(NSScreen.screens.filter(Displays.isEnabled).map(Displays.key))
        tail += MinimizedWindows.shared.windows.compactMap { w -> DockItem? in
            if let key = w.screen.map(Displays.key), docked.contains(key), key != displayKey { return nil }
            guard let app = NSRunningApplication(processIdentifier: w.pid), let url = app.bundleURL else { return nil }
            return DockItem(kind: .window, url: url, bundleID: app.bundleIdentifier, name: w.title, windowID: w.id,
                            hasPreview: WindowPreviews.shared.image(for: w) != nil)
        }
        if config.showTrash {
            tail.append(DockItem(kind: .trash, url: URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"), name: "Trash",
                                 isFull: trashFull))
        }
        if !tail.isEmpty {
            if !result.isEmpty { result.append(.divider) }
            result += tail
        }
        return result
    }
}

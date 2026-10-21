import AppKit

struct DockItem: Equatable {
    enum Kind: Equatable { case app, folder, trash, divider }

    let kind: Kind
    var url: URL? = nil
    var bundleID: String? = nil
    var name: String = ""
    var isRunning = false
    /// Kept in this dock (as opposed to only shown because it's running).
    var pinned = false

    static let divider = DockItem(kind: .divider)

    /// Same identity = same tile, even if the running state differs.
    func sameTile(as other: DockItem) -> Bool {
        kind == other.kind && url == other.url && bundleID == other.bundleID && pinned == other.pinned
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
        reloadPinned()
        // The Dock doesn't broadcast pref changes, so check now and then for
        // pins added or removed in the real Dock.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.reloadPinnedIfChanged()
        }
    }

    @objc private func runningAppsChanged() { onChange?() }

    /// The real Dock's items, Finder first, as paths (used to seed custom lists).
    var mainDockPaths: [String] { (pinnedApps + pinnedOthers).compactMap { $0.url?.path } }

    func icon(for item: DockItem) -> NSImage {
        switch item.kind {
        case .trash:
            return NSImage(named: NSImage.trashEmptyName) ?? NSImage()
        case .divider:
            return NSImage()
        case .app, .folder:
            guard let path = item.url?.path else { return NSImage() }
            if let cached = iconCache[path] { return cached }
            let img = NSWorkspace.shared.icon(forFile: path)
            img.size = NSSize(width: 256, height: 256)
            iconCache[path] = img
            return img
        }
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

    func items(for config: DisplayConfig) -> [DockItem] {
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
        if config.showTrash {
            tail.append(DockItem(kind: .trash, url: URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"), name: "Trash"))
        }
        if !tail.isEmpty {
            if !result.isEmpty { result.append(.divider) }
            result += tail
        }
        return result
    }
}

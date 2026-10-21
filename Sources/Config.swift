import AppKit
import SwiftUI

enum DockEdge: String, Codable, CaseIterable {
    case bottom, left, right, top
    var isVertical: Bool { self == .left || self == .right }
    var title: String { rawValue.capitalized }
}

/// Where along the edge the dock sits. For bottom/top docks start = left,
/// for left/right docks start = top. Start and end give you corner docks.
enum DockAlignment: String, Codable, CaseIterable {
    case start, center, end
    func title(for edge: DockEdge) -> String {
        switch self {
        case .start: edge.isVertical ? "Top" : "Left"
        case .center: "Center"
        case .end: edge.isVertical ? "Bottom" : "Right"
        }
    }
}

enum ItemsMode: String, Codable { case mirror, custom }

struct SavedItem: Codable, Hashable, Identifiable {
    var path: String
    var id: String { path }
}

struct DisplayConfig: Codable, Equatable {
    /// nil = default: on everywhere except the display with the real Dock
    /// (unless the real Dock is hidden).
    var enabled: Bool? = nil
    var edge: DockEdge = .bottom
    var alignment: DockAlignment = .center
    var itemsMode: ItemsMode = .mirror
    var customItems: [SavedItem] = []
    var showRunningApps = true
    var showTrash = true
}

extension Notification.Name {
    static let multiDockConfigChanged = Notification.Name("MultiDockConfigChanged")
    static let multiDockOpenSettings = Notification.Name("MultiDockOpenSettings")
}

/// All settings, persisted in UserDefaults. Per-display settings are keyed by
/// a stable display identifier (vendor/model/serial) so they survive reboots.
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()
    private let d = UserDefaults.standard

    @Published var displays: [String: DisplayConfig] { didSet { save() } }
    @Published var iconSize: Double { didSet { save() } }
    @Published var magnification: Bool { didSet { save() } }
    @Published var autoHide: Bool { didSet { save() } }
    /// Hide the real macOS Dock so a MultiDock dock can take its place.
    @Published var hideSystemDock: Bool { didSet { save() } }
    @Published var autoUpdate: Bool { didSet { save() } }

    private init() {
        displays = (d.data(forKey: "displayConfigs")).flatMap { try? JSONDecoder().decode([String: DisplayConfig].self, from: $0) } ?? [:]
        let size = d.double(forKey: "iconSize")
        iconSize = size > 0 ? size : 48
        magnification = d.object(forKey: "magnification") as? Bool ?? true
        autoHide = d.bool(forKey: "autoHide")
        hideSystemDock = d.bool(forKey: "hideSystemDock")
        autoUpdate = d.object(forKey: "autoUpdate") as? Bool ?? true
    }

    private func save() {
        d.set(try? JSONEncoder().encode(displays), forKey: "displayConfigs")
        d.set(iconSize, forKey: "iconSize")
        d.set(magnification, forKey: "magnification")
        d.set(autoHide, forKey: "autoHide")
        d.set(hideSystemDock, forKey: "hideSystemDock")
        d.set(autoUpdate, forKey: "autoUpdate")
        NotificationCenter.default.post(name: .multiDockConfigChanged, object: nil)
    }

    func config(for key: String) -> DisplayConfig { displays[key] ?? DisplayConfig() }

    func update(_ key: String, _ change: (inout DisplayConfig) -> Void) {
        var c = config(for: key)
        change(&c)
        if c != displays[key] { displays[key] = c }
    }

    func binding(_ key: String) -> Binding<DisplayConfig> {
        Binding(get: { self.config(for: key) }, set: { new in self.update(key) { $0 = new } })
    }

    /// Switches a display to its own list, starting from the main Dock's items.
    func makeCustom(_ key: String) {
        update(key) { c in
            guard c.itemsMode == .mirror else { return }
            c.customItems = DockModel.shared.mainDockPaths.map(SavedItem.init)
            c.itemsMode = .custom
        }
    }

    func addItems(_ paths: [String], to key: String) {
        makeCustom(key)
        update(key) { c in
            for p in paths where !c.customItems.contains(where: { $0.path == p }) {
                c.customItems.append(SavedItem(path: p))
            }
        }
    }

    func removeItem(_ path: String, from key: String) {
        makeCustom(key)
        update(key) { $0.customItems.removeAll { $0.path == path } }
    }
}

enum Displays {
    static func id(_ s: NSScreen) -> CGDirectDisplayID {
        s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    static func key(_ s: NSScreen) -> String {
        let i = id(s)
        return "\(CGDisplayVendorNumber(i))-\(CGDisplayModelNumber(i))-\(CGDisplaySerialNumber(i))"
    }

    /// The display the real Dock is on: the one whose usable area is inset
    /// at the bottom/left/right. Falls back to the primary display when the
    /// Dock is auto-hidden (no inset anywhere), which is also where it stays
    /// while MultiDock hides it.
    static func systemDockScreen() -> NSScreen? {
        NSScreen.screens.first { s in
            let f = s.frame, v = s.visibleFrame
            return v.minY > f.minY + 1 || v.minX > f.minX + 1 || v.maxX < f.maxX - 1
        } ?? NSScreen.screens.first
    }

    static func hasSystemDock(_ s: NSScreen) -> Bool {
        systemDockScreen().map(id) == id(s)
    }

    /// Whether a display gets a dock when the user hasn't said either way.
    static func enabledByDefault(hasSystemDock: Bool) -> Bool {
        !hasSystemDock || ConfigStore.shared.hideSystemDock
    }

    static func isEnabled(_ s: NSScreen) -> Bool {
        ConfigStore.shared.config(for: key(s)).enabled ?? enabledByDefault(hasSystemDock: hasSystemDock(s))
    }
}

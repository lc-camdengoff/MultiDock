import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DisplayInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let frame: CGRect
    let hasSystemDock: Bool

    static func all() -> [DisplayInfo] {
        NSScreen.screens
            .map { DisplayInfo(id: Displays.key($0), name: $0.localizedName, frame: $0.frame, hasSystemDock: Displays.hasSystemDock($0)) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }
}

/// Where the dock pill sits inside a display drawn at `size` (SwiftUI, y down).
func dockPillRect(in size: CGSize, edge: DockEdge, alignment: DockAlignment) -> CGRect {
    let thick = max(5, min(size.width, size.height) * 0.07)
    let inset = thick * 0.5
    let along = (edge.isVertical ? size.height : size.width) * (alignment == .center ? 0.45 : 0.3)
    func pos(_ total: CGFloat) -> CGFloat {
        switch alignment {
        case .start: inset
        case .center: (total - along) / 2
        case .end: total - along - inset
        }
    }
    switch edge {
    case .bottom: return CGRect(x: pos(size.width), y: size.height - thick - inset, width: along, height: thick)
    case .top: return CGRect(x: pos(size.width), y: inset + size.height * 0.05, width: along, height: thick)
    case .left: return CGRect(x: inset, y: pos(size.height), width: thick, height: along)
    case .right: return CGRect(x: size.width - thick - inset, y: pos(size.height), width: thick, height: along)
    }
}

struct SettingsView: View {
    @ObservedObject private var store = ConfigStore.shared
    @State private var displays = DisplayInfo.all()
    @State private var selectedID: String?

    private var selected: DisplayInfo? {
        displays.first { $0.id == selectedID } ?? displays.first { !$0.hasSystemDock } ?? displays.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Click a display to set up its dock.")
                .font(.headline)
            ArrangementView(displays: displays, selectedID: selected?.id) { selectedID = $0 }
                .frame(height: 150)

            if let d = selected {
                Divider()
                DisplayDetailView(display: d)
                    .id(d.id)
            }

            Divider()
            GeneralSettingsView()
        }
        .padding(22)
        .frame(width: 820)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayInfo.all()
        }
    }
}

/// Miniature of the display arrangement, like System Settings > Displays.
struct ArrangementView: View {
    let displays: [DisplayInfo]
    let selectedID: String?
    let onSelect: (String) -> Void
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        GeometryReader { geo in
            let box = displays.reduce(CGRect.null) { $0.union($1.frame) }
            let scale = min(geo.size.width / box.width, geo.size.height / box.height) * 0.95
            let offX = (geo.size.width - box.width * scale) / 2
            let offY = (geo.size.height - box.height * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(displays) { d in
                    let size = CGSize(width: d.frame.width * scale - 6, height: d.frame.height * scale - 6)
                    MiniDisplay(display: d, config: store.config(for: d.id), selected: d.id == selectedID, size: size)
                        .offset(x: offX + (d.frame.minX - box.minX) * scale + 3,
                                y: offY + (box.maxY - d.frame.maxY) * scale + 3)
                        .onTapGesture { onSelect(d.id) }
                }
            }
        }
    }
}

struct MiniDisplay: View {
    let display: DisplayInfo
    let config: DisplayConfig
    let selected: Bool
    let size: CGSize

    var body: some View {
        let enabled = config.enabled ?? Displays.enabledByDefault(hasSystemDock: display.hasSystemDock)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.15))
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: selected ? 2 : 1)
            if display.hasSystemDock, !ConfigStore.shared.hideSystemDock {
                let r = dockPillRect(in: size, edge: .bottom, alignment: .center)
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.35))
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
            }
            if enabled {
                let r = dockPillRect(in: size, edge: config.edge, alignment: config.alignment)
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
            }
            Text(display.name)
                .font(.caption)
                .lineLimit(1)
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
    }
}

struct DisplayDetailView: View {
    let display: DisplayInfo
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        let config = store.binding(display.id)
        let enabled = Binding(
            get: { config.wrappedValue.enabled ?? Displays.enabledByDefault(hasSystemDock: display.hasSystemDock) },
            set: { config.wrappedValue.enabled = $0 })

        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text(display.name).font(.title3.bold())
                if display.hasSystemDock {
                    Toggle("Hide the macOS Dock", isOn: Binding(
                        get: { store.hideSystemDock },
                        set: { hide in
                            store.hideSystemDock = hide
                            // Hiding the real Dock means this display needs ours.
                            if hide { config.wrappedValue.enabled = true }
                        }))
                    Text(store.hideSystemDock
                         ? "The macOS Dock is hidden. It comes back when you turn this off or quit MultiDock."
                         : "The macOS Dock is on this display. Hide it to use a MultiDock dock here instead.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Show a dock on this display", isOn: enabled)

                PositionPicker(display: display, config: config)
                    .disabled(!enabled.wrappedValue)
                    .opacity(enabled.wrappedValue ? 1 : 0.4)

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Edge")
                        Picker("", selection: config.edge) {
                            ForEach(DockEdge.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    GridRow {
                        Text("Position")
                        Picker("", selection: config.alignment) {
                            ForEach(DockAlignment.allCases, id: \.self) { Text($0.title(for: config.wrappedValue.edge)).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                }
                .disabled(!enabled.wrappedValue)
            }
            .frame(width: 360)

            ItemsEditor(displayID: display.id, config: config)
                .disabled(!enabled.wrappedValue)
        }
    }
}

/// Big preview of one display; click near an edge or corner to put the dock there.
struct PositionPicker: View {
    let display: DisplayInfo
    @Binding var config: DisplayConfig

    private struct Spot: Hashable { let edge: DockEdge; let alignment: DockAlignment }
    private var spots: [Spot] {
        DockEdge.allCases.flatMap { e in DockAlignment.allCases.map { Spot(edge: e, alignment: $0) } }
    }

    var body: some View {
        let width: CGFloat = 360
        let size = CGSize(width: width, height: width * display.frame.height / display.frame.width)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.4))
            // Menu bar
            Rectangle().fill(Color.secondary.opacity(0.25))
                .frame(width: size.width - 2, height: size.height * 0.04).offset(x: 1, y: 1)
            ForEach(spots, id: \.self) { s in
                let r = dockPillRect(in: size, edge: s.edge, alignment: s.alignment)
                let isOn = s.edge == config.edge && s.alignment == config.alignment
                RoundedRectangle(cornerRadius: 4)
                    .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(isOn ? 0 : 0.3), style: StrokeStyle(lineWidth: 1, dash: [3])))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .zIndex(isOn ? 1 : 0)
            }
            Text("Click where you want the dock")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture { p in
            let nearest = spots.min { a, b in
                distance(p, dockPillRect(in: size, edge: a.edge, alignment: a.alignment)) <
                    distance(p, dockPillRect(in: size, edge: b.edge, alignment: b.alignment))
            }
            if let nearest {
                config.edge = nearest.edge
                config.alignment = nearest.alignment
            }
        }
    }

    private func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}

struct ItemsEditor: View {
    let displayID: String
    @Binding var config: DisplayConfig
    @State private var selection = Set<String>()
    private let store = ConfigStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Items").font(.title3.bold())
            Picker("", selection: Binding(
                get: { config.itemsMode },
                set: { mode in
                    if mode == .custom { store.makeCustom(displayID) } else { config.itemsMode = .mirror }
                })) {
                Text("Same as the macOS Dock").tag(ItemsMode.mirror)
                Text("Custom for this display").tag(ItemsMode.custom)
            }
            .pickerStyle(.segmented).labelsHidden()

            if config.itemsMode == .mirror {
                List(DockModel.shared.mainDockPaths, id: \.self) { ItemRow(path: $0) }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    .frame(height: 250)
                    .opacity(0.6)
                Text("Pick Custom to choose this display's own apps and folders. You can also right-click any icon in the dock and choose Remove from This Dock or Keep in This Dock.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                List(selection: $selection) {
                    ForEach(config.customItems) { item in
                        ItemRow(path: item.path)
                            .contextMenu { Button("Remove") { remove([item.path]) } }
                    }
                    .onMove { config.customItems.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 250)
                .onDeleteCommand { remove(selection) }

                HStack {
                    Button { addItems() } label: { Image(systemName: "plus") }
                        .help("Add apps or folders")
                    Button { remove(selection) } label: { Image(systemName: "minus") }
                        .disabled(selection.isEmpty)
                        .help("Remove selected")
                    Spacer()
                    Button("Reset to macOS Dock") {
                        config.customItems = DockModel.shared.mainDockPaths.map(SavedItem.init)
                    }
                }
                Text("Drag rows to reorder. You can also drop apps or folders onto the dock itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Show running apps that aren't in this dock", isOn: $config.showRunningApps)
            Toggle("Show Trash", isOn: $config.showTrash)
        }
    }

    private func remove(_ paths: some Collection<String>) {
        let set = Set(paths)
        config.customItems.removeAll { set.contains($0.path) }
        selection.subtract(set)
    }

    private func addItems() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application, .folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add to Dock"
        if panel.runModal() == .OK {
            store.addItems(panel.urls.map(\.path), to: displayID)
        }
    }
}

struct ItemRow: View {
    let path: String

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable().frame(width: 20, height: 20)
            Text(FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""))
            if !FileManager.default.fileExists(atPath: path) {
                Text("missing").font(.caption).foregroundStyle(.red)
            }
        }
        .tag(path)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject private var store = ConfigStore.shared
    @ObservedObject private var guardian = WindowGuard.shared
    @State private var size: Double = ConfigStore.shared.iconSize
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row
            HStack(spacing: 12) {
                Toggle("Keep windows out of the dock", isOn: $store.keepWindowsClear)
                if store.keepWindowsClear && !guardian.isTrusted {
                    Text("Allow MultiDock in Privacy & Security → Accessibility to turn this on.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Settings") { WindowGuard.openAccessibilitySettings() }
                    Button("Reset Permission") { guardian.resetPermission() }
                        .help("Use this if MultiDock is already switched on in Accessibility but this still shows. It removes the old entry so you can allow MultiDock again.")
                } else {
                    Text("Moves windows that overlap a dock, like the macOS Dock does.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 24) {
            HStack {
                Text("Icon size")
                Slider(value: $size, in: 32...80, step: 4) { editing in
                    if !editing { store.iconSize = size }
                }
                .frame(width: 160)
            }
            Toggle("Magnification", isOn: $store.magnification)
            Toggle("Auto-hide", isOn: $store.autoHide)
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { LaunchAtLogin.set($0); launchAtLogin = LaunchAtLogin.isEnabled }))
            Toggle("Update automatically", isOn: $store.autoUpdate)
            Spacer()
            Text("v\(Updater.currentVersion)").foregroundStyle(.secondary)
            Button("Check for Updates") { Updater.shared.check(userInitiated: true) }
        }
    }
}

import AppKit

/// Maps "dock space" to view coordinates so the layout code is written once
/// for every edge. In dock space `a` runs along the edge (left→right for
/// bottom/top docks, top→bottom for side docks) and `c` runs away from the
/// screen edge.
struct DockGeometry {
    let edge: DockEdge
    let size: NSSize

    var length: CGFloat { edge.isVertical ? size.height : size.width }
    var depth: CGFloat { edge.isVertical ? size.width : size.height }

    func rect(a: CGFloat, c: CGFloat, la: CGFloat, lc: CGFloat) -> NSRect {
        switch edge {
        case .bottom: NSRect(x: a, y: c, width: la, height: lc)
        case .top: NSRect(x: a, y: size.height - c - lc, width: la, height: lc)
        case .left: NSRect(x: c, y: size.height - a - la, width: lc, height: la)
        case .right: NSRect(x: size.width - c - lc, y: size.height - a - la, width: lc, height: la)
        }
    }

    func point(_ p: NSPoint) -> (a: CGFloat, c: CGFloat) {
        switch edge {
        case .bottom: (p.x, p.y)
        case .top: (p.x, size.height - p.y)
        case .left: (size.height - p.y, p.x)
        case .right: (size.height - p.y, size.width - p.x)
        }
    }

    /// Along-axis span of a view-space rect.
    func span(_ r: NSRect) -> (start: CGFloat, end: CGFloat) {
        edge.isVertical ? (size.height - r.maxY, size.height - r.minY) : (r.minX, r.maxX)
    }
}

/// Draws one tile. All mouse handling happens in DockView.
final class IconView: NSView {
    var item: DockItem { didSet { needsDisplay = true } }
    var image: NSImage
    let edge: DockEdge
    var iconSize: CGFloat = 48
    var iconBottom: CGFloat = 8
    var lift: CGFloat = 0 { didSet { if lift != oldValue { needsDisplay = true } } }
    var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }

    init(item: DockItem, image: NSImage, edge: DockEdge) {
        self.item = item
        self.image = image
        self.edge = edge
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Icon side length at the current magnification.
    var side: CGFloat { DockGeometry(edge: edge, size: bounds.size).length / 1.12 }

    override func draw(_ dirtyRect: NSRect) {
        let g = DockGeometry(edge: edge, size: bounds.size)
        if item.kind == .divider {
            NSColor.labelColor.withAlphaComponent(0.25).setFill()
            g.rect(a: g.length / 2 - 0.5, c: 6, la: 1, lc: iconSize + 2).fill()
            return
        }
        let rect = g.rect(a: (g.length - side) / 2, c: iconBottom + lift, la: side, lc: side)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        if pressed {
            NSColor.black.withAlphaComponent(0.35).setFill()
            rect.fill(using: .sourceAtop)
        }
        if item.isRunning {
            NSColor.labelColor.withAlphaComponent(0.85).setFill()
            let d: CGFloat = max(4, iconSize / 12)
            NSBezierPath(ovalIn: g.rect(a: g.length / 2 - d / 2, c: 1.5, la: d, lc: d)).fill()
        }
    }
}

/// The floating name label shown next to the hovered icon.
final class LabelView: NSView {
    static let maxWidth: CGFloat = 240
    var text = "" { didSet { needsDisplay = true } }
    private var attrs: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        p.alignment = .center
        return [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: p]
    }
    var fittingWidth: CGFloat { min(Self.maxWidth, (text as NSString).size(withAttributes: attrs).width + 22) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        let h = (text as NSString).size(withAttributes: attrs).height
        (text as NSString).draw(in: NSRect(x: 10, y: (bounds.height - h) / 2, width: bounds.width - 20, height: h),
                                withAttributes: attrs)
    }
}

/// The whole dock: blurred background, icons with magnification, label,
/// and the click / right-click / drag-and-drop handling.
final class DockView: NSView {
    let iconSize: CGFloat
    let magnify: CGFloat
    let edge: DockEdge
    let alignment: DockAlignment
    let displayKey: String
    private let gap: CGFloat
    private let dividerWidth: CGFloat
    private let iconBottom: CGFloat = 8
    private let pad: CGFloat = 8
    let backgroundDepth: CGFloat

    private let background = NSVisualEffectView()
    private let label = LabelView()
    private var items: [DockItem] = []
    private var icons: [IconView] = []
    private var scales: [CGFloat] = []
    private var mouseA: CGFloat?
    private var pressedIndex: Int?
    private var dropIndex: Int?
    private var bouncing: [String: Date] = [:]
    private var animTimer: Timer?

    var onSizeChange: (() -> Void)?

    private var geo: DockGeometry { DockGeometry(edge: edge, size: bounds.size) }

    init(iconSize: CGFloat, magnification: Bool, edge: DockEdge, alignment: DockAlignment, displayKey: String) {
        self.iconSize = iconSize
        self.magnify = magnification ? min(1.7, 96 / iconSize + 0.15) : 1
        self.edge = edge
        self.alignment = alignment
        self.displayKey = displayKey
        self.gap = iconSize * 0.12
        self.dividerWidth = max(12, iconSize * 0.3)
        self.backgroundDepth = iconSize + 16
        super.init(frame: .zero)

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        addSubview(background)

        label.isHidden = true
        addSubview(label)

        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Sizing

    private func slotLength(_ item: DockItem) -> CGFloat {
        item.kind == .divider ? dividerWidth : iconSize + gap
    }

    private var baseLength: CGFloat { items.reduce(0) { $0 + slotLength($1) } + pad * 2 }
    private var magnifyExtra: CGFloat { (magnify - 1) * (iconSize + gap) * 2.2 }

    /// Room for the dock at its most magnified, plus the label beside it.
    var preferredSize: NSSize {
        let length = ceil(baseLength + magnifyExtra + 4)
        let labelRoom: CGFloat = edge.isVertical ? LabelView.maxWidth + 12 : 40
        let depth = ceil(backgroundDepth + max((magnify - 1) * iconSize, iconSize * 0.4) + labelRoom)
        return edge.isVertical ? NSSize(width: depth, height: length) : NSSize(width: length, height: depth)
    }

    /// Where a run of `total` length starts along the edge, per alignment.
    private func anchor(_ total: CGFloat) -> CGFloat {
        switch alignment {
        case .start: 2
        case .center: (geo.length - total) / 2
        case .end: geo.length - total - 2
        }
    }

    // MARK: - Items

    func setItems(_ newItems: [DockItem]) {
        let sameTiles = newItems.count == items.count && zip(newItems, items).allSatisfy { $0.sameTile(as: $1) }
        items = newItems
        if sameTiles {
            for (icon, item) in zip(icons, items) { icon.item = item }
            return
        }
        icons.forEach { $0.removeFromSuperview() }
        icons = items.map { item in
            let v = IconView(item: item, image: DockModel.shared.icon(for: item), edge: edge)
            v.iconSize = iconSize
            v.iconBottom = iconBottom
            addSubview(v, positioned: .below, relativeTo: label)
            return v
        }
        scales = Array(repeating: 1, count: items.count)
        pressedIndex = nil
        onSizeChange?()
        layoutIcons()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutIcons()
        updateTrackingAreas()
    }

    /// Unmagnified center of each slot, used for the magnification falloff.
    private func baseCenters() -> [CGFloat] {
        var a = anchor(baseLength) + pad
        return items.map { item in
            let l = slotLength(item)
            defer { a += l }
            return a + l / 2
        }
    }

    private func targetScales() -> [CGFloat] {
        guard let ma = mouseA, magnify > 1 else { return Array(repeating: 1, count: items.count) }
        let range = (iconSize + gap) * 2.6
        return zip(items, baseCenters()).map { item, center in
            if item.kind == .divider { return 1 }
            let d = abs(ma - center)
            guard d < range else { return 1 }
            return 1 + (magnify - 1) * (cos(.pi * d / range) + 1) / 2
        }
    }

    private func layoutIcons() {
        guard !items.isEmpty, scales.count == items.count else { return }
        let g = geo
        let lengths = zip(items, scales).map { slotLength($0) * $1 }
        let total = lengths.reduce(0, +) + pad * 2
        var a = anchor(total)
        background.frame = g.rect(a: a, c: 0, la: total, lc: backgroundDepth)
        a += pad
        for (icon, l) in zip(icons, lengths) {
            icon.frame = g.rect(a: a, c: 0, la: l, lc: g.depth)
            a += l
        }
        updateLabel()
    }

    private func updateLabel() {
        guard let ma = mouseA, let i = index(atA: ma), items[i].kind != .divider, pressedIndex == nil || dropIndex != nil else {
            label.isHidden = true
            return
        }
        let g = geo
        let icon = icons[i]
        label.text = items[i].name
        let w = label.fittingWidth, h: CGFloat = 26
        let span = g.span(icon.frame)
        let center = (span.start + span.end) / 2
        let c = iconBottom + icon.side + 10
        if edge.isVertical {
            let a = min(max(2, center - h / 2), g.length - h - 2)
            label.frame = g.rect(a: a, c: min(c, g.depth - w - 2), la: h, lc: w)
        } else {
            let a = min(max(2, center - w / 2), g.length - w - 2)
            label.frame = g.rect(a: a, c: min(c, g.depth - h - 2), la: w, lc: h)
        }
        label.isHidden = false
    }

    private func index(atA a: CGFloat) -> Int? {
        let g = geo
        return icons.firstIndex { let s = g.span($0.frame); return s.start <= a && a < s.end }
    }

    private func index(at p: NSPoint) -> Int? {
        let (a, c) = geo.point(p)
        guard c <= backgroundDepth + (magnify - 1) * iconSize else { return nil }
        guard let i = index(atA: a), items[i].kind != .divider else { return nil }
        return i
    }

    /// The area that counts as "on the dock" for auto-hide, in view coordinates.
    var activeRect: NSRect {
        let depth = backgroundDepth + 4 + (mouseA != nil ? (magnify - 1) * iconSize : 0)
        let s = geo.span(background.frame)
        return geo.rect(a: s.start, c: 0, la: s.end - s.start, lc: depth)
    }

    // MARK: - Animation (magnification + launch bounce)

    private func startAnimating() {
        guard animTimer == nil else { return }
        let t = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    private func tick() {
        let targets = targetScales()
        var settled = true
        for i in scales.indices {
            let diff = targets[i] - scales[i]
            if abs(diff) > 0.002 {
                scales[i] += diff * 0.35
                settled = false
            } else {
                scales[i] = targets[i]
            }
        }

        let now = Date()
        for (id, start) in bouncing {
            let elapsed = now.timeIntervalSince(start)
            let launched = NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.isFinishedLaunching }
            // Finish the current hop before stopping.
            let phase = elapsed.truncatingRemainder(dividingBy: 0.5)
            if (launched && elapsed > 0.5 && phase < 0.05) || elapsed > 8 {
                bouncing[id] = nil
            }
        }
        for (icon, item) in zip(icons, items) {
            if let id = item.bundleID, let start = bouncing[id] {
                icon.lift = abs(sin(now.timeIntervalSince(start) * .pi * 2)) * iconSize * 0.35
            } else {
                icon.lift = 0
            }
        }

        layoutIcons()
        if settled && bouncing.isEmpty {
            animTimer?.invalidate()
            animTimer = nil
        }
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        let rect = geo.rect(a: 0, c: 0, la: geo.length, lc: backgroundDepth)
        addTrackingArea(NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self))
        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return background.frame.contains(p) || index(at: p) != nil ? self : nil
    }

    var isMouseInside: Bool { mouseA != nil }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        let a = geo.point(convert(event.locationInWindow, from: nil)).a
        let s = geo.span(background.frame)
        mouseA = (a >= s.start - 4 && a <= s.end + 4) ? a : nil
        startAnimating()
        updateLabel()
    }

    override func mouseExited(with event: NSEvent) {
        mouseA = nil
        startAnimating()
        updateLabel()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        pressedIndex = index(at: convert(event.locationInWindow, from: nil))
        if let i = pressedIndex { icons[i].pressed = true }
        updateLabel()
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer {
            if let i = pressedIndex, i < icons.count { icons[i].pressed = false }
            pressedIndex = nil
            updateLabel()
        }
        guard let i = pressedIndex, index(at: p) == i else { return }
        open(items[i])
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        label.isHidden = true
        let menu = index(at: p).map { contextMenu(for: items[$0]) } ?? NSMenu()
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(BlockMenuItem(title: "Dock Settings…") {
            NotificationCenter.default.post(name: .multiDockOpenSettings, object: nil)
        })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Actions

    private func open(_ item: DockItem) {
        guard let url = item.url else { return }
        switch item.kind {
        case .app:
            if item.isRunning, let app = runningApp(item), MinimizedWindows.shared.restoreIfAllMinimized(app) { return }
            if !item.isRunning, let id = item.bundleID {
                bouncing[id] = Date()
                startAnimating()
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        case .folder, .trash:
            NSWorkspace.shared.open(url)
        case .window:
            if let w = item.windowID.flatMap({ MinimizedWindows.shared.window(id: $0) }) { MinimizedWindows.shared.restore(w) }
        case .divider:
            break
        }
    }

    private func runningApp(_ item: DockItem) -> NSRunningApplication? {
        item.bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
    }

    private func contextMenu(for item: DockItem) -> NSMenu {
        let menu = NSMenu()
        let key = displayKey
        func add(_ title: String, _ action: @escaping () -> Void) {
            menu.addItem(BlockMenuItem(title: title, action))
        }
        func keepOrRemove() {
            guard let path = item.url?.path else { return }
            if item.pinned {
                add("Remove from This Dock") { ConfigStore.shared.removeItem(path, from: key) }
            } else {
                add("Keep in This Dock") { ConfigStore.shared.addItems([path], to: key) }
            }
        }
        switch item.kind {
        case .app:
            if let app = runningApp(item) {
                let minimized = MinimizedWindows.shared.windows(of: app)
                for w in minimized { add(w.title) { MinimizedWindows.shared.restore(w) } }
                if !minimized.isEmpty { menu.addItem(.separator()) }
                add("Show") { [weak self] in self?.open(item) }
                if app.isHidden { add("Unhide") { app.unhide() } } else { add("Hide") { app.hide() } }
                menu.addItem(.separator())
                keepOrRemove()
                add("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url!]) }
                menu.addItem(.separator())
                add("Quit") { app.terminate() }
                let force = BlockMenuItem(title: "Force Quit") { app.forceTerminate() }
                force.isAlternate = true
                force.keyEquivalentModifierMask = .option
                menu.addItem(force)
            } else {
                add("Open") { [weak self] in self?.open(item) }
                menu.addItem(.separator())
                keepOrRemove()
                add("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url!]) }
            }
        case .folder:
            add("Open \"\(item.name)\"") { [weak self] in self?.open(item) }
            add("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url!]) }
            menu.addItem(.separator())
            keepOrRemove()
        case .trash:
            add("Open Trash") { [weak self] in self?.open(item) }
        case .window:
            add("Show \"\(item.name)\"") { [weak self] in self?.open(item) }
        case .divider:
            break
        }
        return menu
    }

    // MARK: - Drag and drop

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func setDropTarget(_ i: Int?) {
        if let old = dropIndex, old < icons.count { icons[old].pressed = false }
        dropIndex = i
        if let i { icons[i].pressed = true }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        mouseA = geo.point(p).a
        startAnimating()
        guard let i = index(at: p), items[i].kind != .folder, items[i].kind != .window else {
            setDropTarget(nil)
            updateLabel()
            // Dropping apps or folders on an empty part of the dock adds them to it.
            return background.frame.contains(p) ? .copy : []
        }
        setDropTarget(i)
        updateLabel()
        return items[i].kind == .trash ? .delete : .generic
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropTarget(nil)
        mouseA = nil
        startAnimating()
        updateLabel()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setDropTarget(nil) }
        let p = convert(sender.draggingLocation, from: nil)
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        guard let i = index(at: p), let target = items[i].url, items[i].kind != .folder, items[i].kind != .window else {
            let addable = urls.filter { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
            guard !addable.isEmpty else { return false }
            ConfigStore.shared.addItems(addable.map(\.path), to: displayKey)
            return true
        }
        switch items[i].kind {
        case .app:
            NSWorkspace.shared.open(urls, withApplicationAt: target, configuration: NSWorkspace.OpenConfiguration())
            return true
        case .trash:
            NSWorkspace.shared.recycle(urls)
            return true
        default:
            return false
        }
    }
}

final class BlockMenuItem: NSMenuItem {
    private let block: () -> Void
    init(title: String, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { block() }
}

import AppKit
import ApplicationServices

/// Keeps other apps' windows out from under the docks, the way the macOS Dock
/// does. macOS has no way to reserve screen space, so this watches windows
/// with the Accessibility API and moves or shrinks any that overlap a dock
/// once the user lets go of them. Needs Accessibility permission.
final class WindowGuard: ObservableObject {
    static let shared = WindowGuard()

    /// Part of a screen that windows must stay inside, because of the dock on `edge`.
    struct Zone {
        let screen: NSRect
        let allowed: NSRect
        let edge: DockEdge
    }

    /// Provided by the app delegate: one zone per visible dock.
    var zones: () -> [Zone] = { [] }

    @Published private(set) var isTrusted = AXIsProcessTrusted()
    private var running = false
    private var observers: [pid_t: AXObserver] = [:]
    private var pending: [AXUIElement] = []
    private var flushScheduled = false
    private var trustTimer: Timer?

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, self.running, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.observe(app)
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.stopObserving(app.processIdentifier)
        }
    }

    /// Matches the setting. Asks for permission the first time it's turned on.
    func sync() {
        guard ConfigStore.shared.keepWindowsClear else { return stop() }
        if running { return sweep() }
        // Already asked and waiting for the user to allow it.
        guard trustTimer == nil else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        if isTrusted { start() } else { waitForTrust() }
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func waitForTrust() {
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self, AXIsProcessTrusted() else { return }
            t.invalidate()
            self.trustTimer = nil
            self.isTrusted = true
            if ConfigStore.shared.keepWindowsClear { self.start() }
        }
    }

    private func start() {
        guard !running else { return }
        running = true
        NSWorkspace.shared.runningApplications.forEach(observe)
        sweep()
    }

    private func stop() {
        running = false
        trustTimer?.invalidate()
        trustTimer = nil
        for pid in Array(observers.keys) { stopObserving(pid) }
        pending.removeAll()
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, _, _ in WindowGuard.shared.windowChanged(element) }, &observer) == .success,
              let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        for n in [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(observer, appElement, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func stopObserving(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Re-checks every window, e.g. after a dock moved.
    func sweep() {
        guard running else { return }
        for pid in observers.keys {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
            (value as? [AXUIElement])?.forEach(windowChanged)
        }
    }

    // MARK: - Fixing windows

    private func windowChanged(_ window: AXUIElement) {
        if !pending.contains(where: { CFEqual($0, window) }) { pending.append(window) }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            // Wait until the user lets go so we don't fight a drag or resize.
            if NSEvent.pressedMouseButtons != 0 { return self.scheduleFlush() }
            let windows = self.pending
            self.pending.removeAll()
            let zones = self.zones()
            guard !zones.isEmpty else { return }
            windows.forEach { self.fix($0, zones: zones) }
        }
    }

    private func fix(_ window: AXUIElement, zones: [Zone]) {
        guard string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
              bool(window, kAXMinimizedAttribute) != true,
              bool(window, "AXFullScreen") != true,
              let w = frame(of: window) else { return }
        let center = NSPoint(x: w.midX, y: w.midY)
        guard let z = zones.first(where: { $0.screen.contains(center) }) else { return }

        let a = z.allowed
        var f = w
        switch z.edge {
        case .bottom:
            guard f.minY < a.minY else { return }
            f.origin.y += max(0, min(a.minY - f.minY, a.maxY - f.maxY))
            if f.minY < a.minY { f.size.height -= a.minY - f.minY; f.origin.y = a.minY }
        case .top:
            guard f.maxY > a.maxY else { return }
            f.origin.y -= max(0, min(f.maxY - a.maxY, f.minY - a.minY))
            if f.maxY > a.maxY { f.size.height -= f.maxY - a.maxY }
        case .left:
            guard f.minX < a.minX else { return }
            f.origin.x += max(0, min(a.minX - f.minX, a.maxX - f.maxX))
            if f.minX < a.minX { f.size.width -= a.minX - f.minX; f.origin.x = a.minX }
        case .right:
            guard f.maxX > a.maxX else { return }
            f.origin.x -= max(0, min(f.maxX - a.maxX, f.minX - a.minX))
            if f.maxX > a.maxX { f.size.width -= f.maxX - a.maxX }
        }
        guard f != w, f.width > 50, f.height > 50 else { return }
        setFrame(window, f)
    }

    // MARK: - Accessibility helpers

    /// Accessibility uses top-left origin coordinates; AppKit uses bottom-left.
    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    private func frame(of window: AXUIElement) -> NSRect? {
        var pos = CGPoint.zero, size = CGSize.zero
        guard let p = value(window, kAXPositionAttribute), AXValueGetValue(p, .cgPoint, &pos),
              let s = value(window, kAXSizeAttribute), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return NSRect(x: pos.x, y: primaryHeight - pos.y - size.height, width: size.width, height: size.height)
    }

    private func setFrame(_ window: AXUIElement, _ f: NSRect) {
        var pos = CGPoint(x: f.minX, y: primaryHeight - f.maxY)
        var size = f.size
        // Position first so a shrinking window keeps its top edge where we put it.
        if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) }
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
    }

    private func value(_ e: AXUIElement, _ attr: String) -> AXValue? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    private func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(e, attr as CFString, &v)
        return v as? String
    }

    private func bool(_ e: AXUIElement, _ attr: String) -> Bool? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(e, attr as CFString, &v)
        return v as? Bool
    }
}

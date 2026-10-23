import AppKit
import ApplicationServices

/// Private but long-stable: the window server's ID for an Accessibility
/// window, needed to take its picture. Used by most window managers.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func axWindowID(_ element: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    return _AXUIElementGetWindow(element, &id) == .success ? id : nil
}

/// Keeps track of minimized windows so the docks can show them as tiles and
/// bring them back, like the macOS Dock. Needs Accessibility permission;
/// without it there are no tiles and clicking an app just reopens it.
final class MinimizedWindows {
    static let shared = MinimizedWindows()

    struct Window {
        let id: Int
        let pid: pid_t
        let title: String
        /// Where it was before it was minimized, in AppKit screen coordinates.
        let frame: NSRect?
        /// The window server's ID, for its preview picture.
        let windowID: CGWindowID?
        fileprivate let element: AXUIElement

        /// The display it was minimized from, if it can tell.
        var screen: NSScreen? {
            guard let f = frame else { return nil }
            return NSScreen.screens.max { $0.frame.intersection(f).area < $1.frame.intersection(f).area }
                .flatMap { $0.frame.intersects(f) ? $0 : nil }
        }
    }

    /// In the order they were minimized, oldest first.
    private(set) var windows: [Window] = []
    var onChange: (() -> Void)?

    private var observers: [pid_t: AXObserver] = [:]
    private var nextID = 1
    private var timer: Timer?

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.observe(app)
                self?.rescan(app.processIdentifier)
            }
        }
        // Picks up permission being granted, and anything the notifications missed.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.rescanAll() }
        rescanAll()
    }

    func windows(of app: NSRunningApplication) -> [Window] {
        windows.filter { $0.pid == app.processIdentifier }
    }

    func window(id: Int) -> Window? { windows.first { $0.id == id } }

    /// When every window of the app is minimized, brings back the first one.
    /// Returns false if it didn't, so the caller can just open the app.
    func restoreIfAllMinimized(_ app: NSRunningApplication) -> Bool {
        let all = standardWindows(app.processIdentifier)
        guard !all.isEmpty, all.allSatisfy(isMinimized) else { return false }
        restore(element: all[0], pid: app.processIdentifier)
        return true
    }

    func restore(_ w: Window) { restore(element: w.element, pid: w.pid) }

    private func restore(element: AXUIElement, pid: pid_t) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
        rescan(pid)
    }

    // MARK: - Tracking

    private func rescanAll() {
        guard AXIsProcessTrusted() else {
            if !windows.isEmpty { windows = []; onChange?() }
            return
        }
        let apps = NSWorkspace.shared.runningApplications.filter(isTracked)
        apps.forEach(observe)
        let pids = Set(apps.map(\.processIdentifier))
        for pid in Array(observers.keys) where !pids.contains(pid) { stopObserving(pid) }
        let before = windows.map(\.id)
        windows.removeAll { !pids.contains($0.pid) }
        for pid in pids { update(pid, notify: false) }
        if windows.map(\.id) != before { onChange?() }
    }

    fileprivate func rescan(_ pid: pid_t) {
        update(pid, notify: true)
        // Minimizing animates; check again once it's done.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.update(pid, notify: true) }
    }

    /// Keeps the windows still minimized in their place and adds new ones at the end.
    private func update(_ pid: pid_t, notify: Bool) {
        let running = NSRunningApplication(processIdentifier: pid).map(isTracked) ?? false
        let found = running && AXIsProcessTrusted() ? standardWindows(pid).filter(isMinimized) : []
        let before = windows.map(\.id)
        windows.removeAll { w in w.pid == pid && !found.contains { CFEqual($0, w.element) } }
        for e in found where !windows.contains(where: { $0.pid == pid && CFEqual($0.element, e) }) {
            let title = attr(e, kAXTitleAttribute) as? String ?? ""
            windows.append(Window(id: nextID, pid: pid, title: title.isEmpty ? "Untitled" : title,
                                  frame: frame(of: e), windowID: axWindowID(e), element: e))
            nextID += 1
        }
        if notify, windows.map(\.id) != before { onChange?() }
    }

    private func isTracked(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != getpid() && !app.isTerminated
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard AXIsProcessTrusted(), isTracked(app), observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, _ in
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            MinimizedWindows.shared.rescan(pid)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        for n in [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, appElement, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func stopObserving(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    // MARK: - Accessibility helpers

    private func standardWindows(_ pid: pid_t) -> [AXUIElement] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        // Don't let a hung app stall the docks.
        AXUIElementSetMessagingTimeout(app, 0.3)
        let all = attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return all.filter { attr($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole as String }
    }

    /// A minimized window still reports the frame it had on screen.
    private func frame(of e: AXUIElement) -> NSRect? {
        var pos = CGPoint.zero, size = CGSize.zero
        guard let p = attr(e, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              AXValueGetValue(p as! AXValue, .cgPoint, &pos),
              let s = attr(e, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID(),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        // Accessibility uses top-left origin coordinates; AppKit uses bottom-left.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: pos.x, y: top - pos.y - size.height, width: size.width, height: size.height)
    }

    private func isMinimized(_ e: AXUIElement) -> Bool { attr(e, kAXMinimizedAttribute) as? Bool == true }

    private func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(e, name as CFString, &v)
        return v
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

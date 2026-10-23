import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Pictures of minimized windows for their dock tiles, like the macOS Dock.
/// Needs Screen Recording permission. macOS doesn't promise a picture of a
/// window once it's minimized, so the window in front is also snapshotted
/// every few seconds while it's visible, and a minimized window's tile uses
/// its last snapshot. Snapshots stay in memory. Without any picture the
/// tile keeps showing the app's icon.
final class WindowPreviews: ObservableObject {
    static let shared = WindowPreviews()

    var onChange: (() -> Void)?
    /// Why the last minimized window has no picture, shown in Settings.
    @Published private(set) var problem: String?

    private var images: [Int: NSImage] = [:]
    private var capturing: Set<Int> = []
    private var failed: Set<Int> = []
    private var asked = false
    /// Recent snapshots of windows while they were on screen, newest last.
    private var recent: [(id: CGWindowID, image: NSImage)] = []
    private var snapshotting = false
    private var timer: Timer?

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            // Let the app's window come forward first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.snapshotFrontWindow() }
        }
    }

    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// Matches the setting. Asks for permission once per launch when it's on.
    func sync() {
        guard ConfigStore.shared.windowPreviews else {
            images.removeAll()
            failed.removeAll()
            recent.removeAll()
            timer?.invalidate()
            timer = nil
            problem = nil
            return
        }
        if !Self.isAllowed, !asked {
            asked = true
            CGRequestScreenCaptureAccess()
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.snapshotFrontWindow() }
        }
    }

    /// The window's picture if there is one yet; starts capturing it if not.
    func image(for w: MinimizedWindows.Window) -> NSImage? {
        guard ConfigStore.shared.windowPreviews, Self.isAllowed else { return nil }
        if let img = images[w.id] { return img }
        // How it looked just before it was minimized is the most reliable picture.
        if let id = w.windowID, let img = recent.last(where: { $0.id == id })?.image {
            images[w.id] = img
            problem = nil
            return img
        }
        capture(w)
        return nil
    }

    func cached(_ id: Int) -> NSImage? { images[id] }

    /// Drops pictures of windows that aren't minimized any more.
    func keep(_ ids: Set<Int>) {
        images = images.filter { ids.contains($0.key) }
        failed.formIntersection(ids)
    }

    private func capture(_ w: MinimizedWindows.Window) {
        guard !capturing.contains(w.id), !failed.contains(w.id) else { return }
        guard let windowID = w.windowID else {
            failed.insert(w.id)
            problem = "Couldn't identify \"\(w.title)\" to take its picture."
            return
        }
        capturing.insert(w.id)
        let id = w.id, title = w.title
        Task {
            var img: NSImage?, error: Error?
            do { img = try await Self.snapshot(windowID) } catch let e { error = e }
            let captured = img, failure = error
            DispatchQueue.main.async {
                self.capturing.remove(id)
                // Fall back to how it looked before it was minimized.
                if let image = captured ?? self.recent.last(where: { $0.id == windowID })?.image {
                    self.images[id] = image
                    self.problem = nil
                    self.onChange?()
                } else {
                    self.failed.insert(id)
                    self.problem = failure.map { "Couldn't take a picture of \"\(title)\": \($0.localizedDescription)" }
                        ?? "macOS didn't provide a picture of \"\(title)\", and it wasn't in front long enough to take one before it was minimized."
                }
            }
        }
    }

    /// Snapshots the window in front, so it has a picture if it's minimized later.
    private func snapshotFrontWindow() {
        guard ConfigStore.shared.windowPreviews, Self.isAllowed, AXIsProcessTrusted(), !snapshotting,
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let window = value as! AXUIElement
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        guard minimized as? Bool != true, let windowID = axWindowID(window) else { return }
        snapshotting = true
        Task {
            let img = try? await Self.snapshot(windowID)
            DispatchQueue.main.async {
                self.snapshotting = false
                guard let img else { return }
                self.recent.removeAll { $0.id == windowID }
                self.recent.append((windowID, img))
                if self.recent.count > 30 { self.recent.removeFirst() }
            }
        }
    }

    private static func snapshot(_ windowID: CGWindowID) async throws -> NSImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }),
              window.frame.width > 0, window.frame.height > 0 else { return nil }
        let config = SCStreamConfiguration()
        // Tiles are small; 512 pixels on the long side is plenty on Retina.
        let scale = min(1, 512 / max(window.frame.width, window.frame.height))
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        return isBlank(image) ? nil : NSImage(cgImage: image, size: .zero)
    }

    /// Fully transparent or fully black, which is what an unavailable window looks like.
    private static func isBlank(_ image: CGImage) -> Bool {
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        var allClear = true, allBlack = true
        for i in stride(from: 0, to: px.count, by: 4) {
            if px[i + 3] >= 8 { allClear = false }
            if px[i] >= 8 || px[i + 1] >= 8 || px[i + 2] >= 8 { allBlack = false }
        }
        return allClear || allBlack
    }
}

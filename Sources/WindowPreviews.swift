import AppKit
import ScreenCaptureKit

/// Pictures of minimized windows for their dock tiles, like the macOS Dock.
/// Needs Screen Recording permission. macOS doesn't promise a picture of a
/// window once it's minimized, so a capture that comes back empty is
/// dropped and the tile keeps showing the app's icon.
final class WindowPreviews {
    static let shared = WindowPreviews()

    var onChange: (() -> Void)?

    private var images: [Int: NSImage] = [:]
    private var capturing: Set<Int> = []
    private var failed: Set<Int> = []
    private var asked = false

    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// Matches the setting. Asks for permission once per launch when it's on.
    func sync() {
        guard ConfigStore.shared.windowPreviews else {
            images.removeAll()
            failed.removeAll()
            return
        }
        if !Self.isAllowed, !asked {
            asked = true
            CGRequestScreenCaptureAccess()
        }
    }

    /// The window's picture if there is one yet; starts capturing it if not.
    func image(for w: MinimizedWindows.Window) -> NSImage? {
        guard ConfigStore.shared.windowPreviews, Self.isAllowed else { return nil }
        if let img = images[w.id] { return img }
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
        guard let windowID = w.windowID, !capturing.contains(w.id), !failed.contains(w.id) else { return }
        capturing.insert(w.id)
        let id = w.id
        Task {
            let img = try? await Self.snapshot(windowID)
            DispatchQueue.main.async {
                self.capturing.remove(id)
                if let img {
                    self.images[id] = img
                    self.onChange?()
                } else {
                    self.failed.insert(id)
                }
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

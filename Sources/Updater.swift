import AppKit

/// Checks GitHub Releases for a newer MultiDock and installs it in place,
/// without asking when "Install updates automatically" is on.
/// Each release carries MultiDock.zip (the app) and MultiDock.dmg (for new installs).
final class Updater {
    static let shared = Updater()

    static let repo = "lc-camdengoff/MultiDock"
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    struct Release {
        let version: String
        let notes: String
        let zipURL: URL
        let pageURL: URL
    }

    private(set) var available: Release?
    private(set) var isInstalling = false
    /// Set while quitting to relaunch into a new version.
    private(set) var isRelaunching = false
    private var timer: Timer?

    func start() {
        check(userInitiated: false)
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.check(userInitiated: false)
        }
    }

    func check(userInitiated: Bool) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, error in
            let release = data.flatMap(Self.parse)
            DispatchQueue.main.async {
                self.available = release.flatMap { Self.isNewer($0.version) ? $0 : nil }
                if let r = self.available, !userInitiated, ConfigStore.shared.autoUpdate, !self.isInstalling {
                    self.install(r, silently: true)
                } else if let r = self.available {
                    // Only nag once per version unless asked.
                    let key = "notifiedVersion"
                    if userInitiated || UserDefaults.standard.string(forKey: key) != r.version {
                        UserDefaults.standard.set(r.version, forKey: key)
                        self.offer(r)
                    }
                } else if userInitiated {
                    self.alert(error == nil ? "You're up to date" : "Couldn't check for updates",
                               error?.localizedDescription ?? "MultiDock \(Self.currentVersion) is the latest version.")
                }
            }
        }.resume()
    }

    private static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { $0["name"] as? String == "MultiDock.zip" }),
              let zipURL = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: json["body"] as? String ?? "", zipURL: zipURL, pageURL: page)
    }

    private static func isNewer(_ v: String) -> Bool {
        v.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    // MARK: - UI

    private func offerOnce(_ r: Release) {
        let key = "notifiedVersion"
        guard UserDefaults.standard.string(forKey: key) != r.version else { return }
        UserDefaults.standard.set(r.version, forKey: key)
        offer(r)
    }

    /// The version this copy was updated from, if it was just updated. Read once.
    static func takeUpdatedFromVersion() -> String? {
        let d = UserDefaults.standard
        defer { d.removeObject(forKey: "updatedFromVersion") }
        return d.string(forKey: "updatedFromVersion")
    }

    func offer(_ r: Release) {
        let a = NSAlert()
        a.messageText = "MultiDock \(r.version) is available"
        a.informativeText = "You have \(Self.currentVersion).\n\n\(r.notes)".trimmingCharacters(in: .whitespacesAndNewlines)
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { install(r) }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }

    // MARK: - Install

    /// Silent installs never show errors; if one can't finish, the user is
    /// offered the update the normal way instead (once per version).
    private func install(_ r: Release, silently: Bool = false) {
        let appURL = Bundle.main.bundleURL
        // Running from the DMG or somewhere read-only: send them to the download page.
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path),
              !appURL.path.hasPrefix("/Volumes/") else {
            if silently { offerOnce(r) } else { NSWorkspace.shared.open(r.pageURL) }
            return
        }
        isInstalling = true
        URLSession.shared.downloadTask(with: r.zipURL) { download, _, error in
            // URLSession deletes the download when this handler returns, so keep a copy.
            let file = download.flatMap { d -> URL? in
                let keep = FileManager.default.temporaryDirectory.appendingPathComponent("MultiDock-\(UUID().uuidString).zip")
                return (try? FileManager.default.moveItem(at: d, to: keep)) == nil ? nil : keep
            }
            DispatchQueue.main.async {
                defer { self.isInstalling = false }
                guard let file else {
                    // A silent download that fails just tries again at the next check.
                    if !silently {
                        self.alert("Update failed", error?.localizedDescription ?? "The download didn't finish.")
                    }
                    return
                }
                defer { try? FileManager.default.removeItem(at: file) }
                do {
                    try self.replaceApp(at: appURL, withZip: file, expecting: r.version)
                    UserDefaults.standard.set(Self.currentVersion, forKey: "updatedFromVersion")
                    self.relaunch(appURL)
                } catch {
                    if silently { return self.offerOnce(r) }
                    self.alert("Update failed", "\(error.localizedDescription)\n\nYou can download it manually from GitHub instead.")
                    NSWorkspace.shared.open(r.pageURL)
                }
            }
        }.resume()
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
    }

    private func replaceApp(at appURL: URL, withZip zip: URL, expecting version: String) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MultiDockUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let newApp = work.appendingPathComponent("MultiDock.app")
        guard let bundle = Bundle(url: newApp),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw UpdateError(errorDescription: "The downloaded file isn't the expected MultiDock version.")
        }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        _ = try fm.replaceItemAt(appURL, withItemAt: newApp)
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw UpdateError(errorDescription: "\(tool) failed (\(p.terminationStatus)).")
        }
    }

    private func relaunch(_ appURL: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", appURL.path]
        try? p.run()
        isRelaunching = true
        NSApp.terminate(nil)
    }
}

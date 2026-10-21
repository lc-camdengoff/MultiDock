import AppKit

/// Hides the real macOS Dock by turning on its auto-hide with a delay so long
/// it never pops up, then restarting it. The user's own Dock settings are
/// saved first and put back when hiding is turned off or MultiDock quits.
enum SystemDock {
    private static let domain = "com.apple.dock" as CFString
    private static let d = UserDefaults.standard
    /// Set while the Dock is hidden by us, so a crash can be undone on next launch.
    private static let hiddenKey = "systemDockHiddenByUs"

    static var isHiddenByUs: Bool { d.bool(forKey: hiddenKey) }

    /// Makes the real Dock match the setting. Cheap to call repeatedly.
    static func sync() {
        if ConfigStore.shared.hideSystemDock { hide() } else { restore() }
    }

    static func hide() {
        guard !isHiddenByUs else { return }
        CFPreferencesAppSynchronize(domain)
        d.set(value("autohide") as? Bool ?? false, forKey: "savedDockAutohide")
        if let delay = value("autohide-delay") as? Double {
            d.set(delay, forKey: "savedDockAutohideDelay")
        } else {
            d.removeObject(forKey: "savedDockAutohideDelay")
        }
        set("autohide", true)
        set("autohide-delay", 1000.0)
        d.set(true, forKey: hiddenKey)
        restartDock()
    }

    /// Puts the user's Dock settings back. Pass `restart: false` when the Mac
    /// is logging out or shutting down and the Dock is going away anyway.
    static func restore(restart: Bool = true) {
        guard isHiddenByUs else { return }
        set("autohide", d.bool(forKey: "savedDockAutohide"))
        set("autohide-delay", d.object(forKey: "savedDockAutohideDelay") as? Double)
        d.set(false, forKey: hiddenKey)
        if restart { restartDock() }
    }

    private static func value(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    private static func set(_ key: String, _ value: Any?) {
        CFPreferencesSetAppValue(key as CFString, value.map { $0 as CFPropertyList }, domain)
        CFPreferencesAppSynchronize(domain)
    }

    private static func restartDock() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
    }
}

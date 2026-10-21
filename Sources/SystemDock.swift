import AppKit

/// Hides the real macOS Dock by turning on its auto-hide with a delay so long
/// it never pops up, then restarting it. Minimized windows go into their
/// app's icon instead of the hidden Dock. The user's own Dock settings are
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

    /// The Dock settings changed while it's hidden.
    private static let overrides: [String: Any] = [
        "autohide": true,
        "autohide-delay": 1000.0,
        "minimize-to-application": true,
    ]

    /// Settings already changed. Applies any added in a newer MultiDock.
    static func hide() {
        CFPreferencesAppSynchronize(domain)
        var keys = savedKeys, values = savedValues
        for (key, new) in overrides.sorted(by: { $0.key < $1.key }) where !keys.contains(key) {
            if let old = value(key) { values[key] = old }
            keys.append(key)
            set(key, new)
        }
        guard keys.count != savedKeys.count || !isHiddenByUs else { return }
        d.set(keys, forKey: "savedDockKeys")
        d.set(values, forKey: "savedDockValues")
        d.set(true, forKey: hiddenKey)
        restartDock()
    }

    /// Which Dock settings we changed, and the user's own values for them
    /// (missing = it wasn't set). Older versions saved just two of them.
    private static var savedKeys: [String] {
        d.stringArray(forKey: "savedDockKeys") ?? (isHiddenByUs ? ["autohide", "autohide-delay"] : [])
    }

    private static var savedValues: [String: Any] {
        if let v = d.dictionary(forKey: "savedDockValues") { return v }
        var v: [String: Any] = ["autohide": d.bool(forKey: "savedDockAutohide")]
        if let delay = d.object(forKey: "savedDockAutohideDelay") { v["autohide-delay"] = delay }
        return v
    }

    /// Puts the user's Dock settings back. Pass `restart: false` when the Mac
    /// is logging out or shutting down and the Dock is going away anyway.
    static func restore(restart: Bool = true) {
        guard isHiddenByUs else { return }
        let values = savedValues
        for key in savedKeys { set(key, values[key]) }
        for key in ["savedDockKeys", "savedDockValues", "savedDockAutohide", "savedDockAutohideDelay"] {
            d.removeObject(forKey: key)
        }
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

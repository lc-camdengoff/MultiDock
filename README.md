# MultiDock

A dock on every monitor. Each display gets its own position (bottom, left, right or top, centered or in a corner) and its own apps.

macOS only puts the Dock on one screen. MultiDock fixes that, for free.

## Install

1. **[Download MultiDock.dmg](https://github.com/lc-camdengoff/MultiDock/releases/latest/download/MultiDock.dmg)**
2. Open it and drag **MultiDock** into **Applications**.
3. Double-click MultiDock in Applications. macOS will say it "could not verify" it, because it's not from the App Store. Click **Done**.
4. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to MultiDock.

You only do step 4 once. After that, MultiDock updates itself.

Requires macOS 14 Sonoma or newer. Works on Apple Silicon and Intel Macs.

## Using it

- MultiDock lives in the menu bar (the little dock icon). Open **Settings** from there.
- Click a display in Settings, then click where its dock should go.
- On the display with the macOS Dock, turn on **Hide the macOS Dock** to use a MultiDock dock there instead (also in the menu bar menu). Your Dock comes back when you turn it off or quit MultiDock.
- Each display can mirror your normal Dock or have its own **Custom** list of apps and folders.
- Right-click any icon for Hide, Quit, **Remove from This Dock** and more. Right-click a running app and choose **Keep in This Dock** to add it.
- Drop an app or folder onto an empty part of a dock to add it.

## Updates

MultiDock checks this repo's [Releases](https://github.com/lc-camdengoff/MultiDock/releases) every few hours and offers to install new versions. You can also use **Check for Updates…** in the menu bar.

## Development

```bash
./build.sh                         # build/MultiDock.app
./package.sh                       # dist/MultiDock.dmg + dist/MultiDock.zip
./release.sh 1.1 "What changed"    # bump version, tag, push, publish a GitHub release
```

Building only needs the Xcode command line tools. There's no Xcode project; `build.sh` calls `swiftc` directly.

| File | What it does |
| --- | --- |
| `Sources/AppDelegate.swift` | One dock window per display, auto-hide, menu bar menu |
| `Sources/DockView.swift` | Drawing, magnification, clicks, right-click menus, drag and drop |
| `Sources/DockModel.swift` | Reads the real Dock's items and the running apps |
| `Sources/Config.swift` | Per-display settings |
| `Sources/SystemDock.swift` | Hides and restores the real macOS Dock |
| `Sources/SettingsView.swift` | The Settings window |
| `Sources/Updater.swift` | Checks GitHub Releases and installs updates |
| `tools/make_icon.swift` | Draws the app icon |

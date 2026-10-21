// Draws MultiDock's app icon: two little screens, each with its own dock.
// Usage: swift tools/make_icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.98, alpha: 1),
           ending: NSColor(calibratedRed: 0.45, green: 0.20, blue: 0.85, alpha: 1))!.draw(in: bg, angle: -90)

func screen(_ r: NSRect, dock: (NSRect) -> NSRect) {
    let s = NSBezierPath(roundedRect: r, xRadius: 28, yRadius: 28)
    NSColor.white.withAlphaComponent(0.92).setFill()
    s.fill()
    NSColor(calibratedWhite: 0.15, alpha: 0.85).setFill()
    NSBezierPath(roundedRect: dock(r), xRadius: 14, yRadius: 14).fill()
}

// Left screen: dock along the bottom. Right screen: dock on the side.
screen(NSRect(x: 165, y: 410, width: 360, height: 270)) { r in
    NSRect(x: r.midX - 100, y: r.minY + 22, width: 200, height: 40)
}
screen(NSRect(x: 560, y: 335, width: 300, height: 420)) { r in
    NSRect(x: r.maxX - 62, y: r.midY - 110, width: 40, height: 220)
}

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

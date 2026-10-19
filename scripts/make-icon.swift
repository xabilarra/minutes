// Renders Resources/AppIcon.icns: a macOS-style rounded square with a waveform and a record dot.
// Usage: swift scripts/make-icon.swift   (needs iconutil, part of macOS)
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Apple's template: 824/1024 body centered, ~185/1024 corner radius.
    let body = NSRect(x: size * 100 / 1024, y: size * 100 / 1024, width: size * 824 / 1024, height: size * 824 / 1024)
    let squircle = NSBezierPath(roundedRect: body, xRadius: size * 185 / 1024, yRadius: size * 185 / 1024)
    NSGradient(
        starting: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.55, alpha: 1),
        ending: NSColor(calibratedRed: 0.42, green: 0.25, blue: 0.75, alpha: 1)
    )!.draw(in: squircle, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let origin = NSPoint(x: body.midX - tinted.size.width / 2, y: body.midY - tinted.size.height / 2 - size * 0.02)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    let dotSize = size * 0.15
    let dot = NSRect(x: body.maxX - dotSize - size * 0.09, y: body.maxY - dotSize - size * 0.09, width: dotSize, height: dotSize)
    NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.27, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}

let output = root.appending(path: "Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed with status \(iconutil.terminationStatus)") }
print("Wrote \(output.path)")

// Composes docs/images/hero-<lang>.jpg from the app icon and the screenshots made by
// scripts/capture-screenshots.sh. Usage: swift scripts/make-readme-images.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let images = root.appending(path: "docs/images")

let taglines = [
    "en": ["Records your video calls without a bot.", "Transcribes them for your AI agents."],
    "es": ["Graba tus videollamadas sin bots.", "Y las transcribe para tus agentes de IA."],
]

func load(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: images.appending(path: name)) else {
        fatalError("Missing \(name); run scripts/capture-screenshots.sh first.")
    }
    return image
}

/// Pixel size of a bitmap image (NSImage.size is in points).
func pixels(_ image: NSImage) -> NSSize {
    let rep = image.representations.first
    return NSSize(width: rep?.pixelsWide ?? Int(image.size.width), height: rep?.pixelsHigh ?? Int(image.size.height))
}

func draw(_ image: NSImage, x: CGFloat, y: CGFloat, height: CGFloat) {
    let size = pixels(image)
    let width = size.width * height / size.height
    image.draw(
        in: NSRect(x: x, y: y, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1,
        respectFlipped: true, hints: nil)
}

func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
    ]
    NSAttributedString(string: string, attributes: attributes).draw(at: NSPoint(x: x, y: y))
}

let canvas = NSSize(width: 2400, height: 1350)
let icon = NSImage(contentsOf: root.appending(path: "Resources/AppIcon.icns"))!

for (lang, lines) in taglines {
    let window = load("window-\(lang).png")
    let recording = load("pill-recording-\(lang).png")
    let ready = load("pill-ready-\(lang).png")

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    // Top-left origin, like the screenshots' layout.
    context.cgContext.translateBy(x: 0, y: canvas.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    NSGraphicsContext.current = flipped

    // Square corners: the image is a JPEG, and transparent corners would show on GitHub's dark theme.
    let background = NSBezierPath(rect: NSRect(origin: .zero, size: canvas))
    NSGradient(
        starting: NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.33, alpha: 1),
        ending: NSColor(calibratedRed: 0.40, green: 0.24, blue: 0.72, alpha: 1)
    )!.draw(in: background, angle: -35)

    draw(icon, x: 120, y: 190, height: 260)
    text("Minutes", x: 150, y: 470, size: 132, weight: .bold, alpha: 1)
    for (index, line) in lines.enumerated() {
        text(line, x: 156, y: 660 + CGFloat(index) * 66, size: 50, weight: .medium, alpha: 0.86)
    }
    text("macOS · Swift · Groq Whisper · MIT", x: 156, y: 830, size: 34, weight: .regular, alpha: 0.6)

    draw(window, x: 1430, y: 60, height: 1230)
    draw(recording, x: 110, y: 960, height: 150)
    draw(ready, x: 520, y: 1110, height: 150)

    NSGraphicsContext.restoreGraphicsState()
    let output = images.appending(path: "hero-\(lang).jpg")
    try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!.write(to: output)
    print("Wrote \(output.path)")
}

// Small icon for the README header.
let iconRep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: iconRep)
icon.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
NSGraphicsContext.restoreGraphicsState()
try! iconRep.representation(using: .png, properties: [:])!.write(to: images.appending(path: "icon.png"))
print("Wrote icon.png")

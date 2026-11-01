import AppKit

// Regenerate with: swift scripts/GenerateIcon.swift
// All shapes are native vector paths; no downloaded or generated image assets.
let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let iconset = projectRoot.appendingPathComponent(".build/icons/KeyboardLock.iconset")
let output = projectRoot.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

func roundedRect(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawIcon() {
    let navy = color(23, 43, 73)
    let white = color(244, 246, 249)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                            xRadius: 198, yRadius: 198)
    color(23, 43, 73).setFill()
    tile.fill()

    // A restrained highlight keeps the shape legible against a dark Dock.
    color(61, 79, 107).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    roundedRect(NSRect(x: 192, y: 292, width: 640, height: 386), radius: 54,
                fill: color(9, 20, 35))
    roundedRect(NSRect(x: 192, y: 306, width: 640, height: 386), radius: 54, fill: white)

    for row in 0..<3 {
        for column in 0..<7 {
            let x = CGFloat(232 + column * 82)
            let y = CGFloat(460 + row * 68)
            roundedRect(NSRect(x: x, y: y, width: 66, height: 48), radius: 10, fill: navy)
        }
    }
    roundedRect(NSRect(x: 232, y: 364, width: 82, height: 60), radius: 11, fill: navy)
    roundedRect(NSRect(x: 334, y: 364, width: 356, height: 60), radius: 11, fill: navy)
    roundedRect(NSRect(x: 710, y: 364, width: 82, height: 60), radius: 11, fill: navy)

    // The lock is the only secondary motif.
    let badge = NSBezierPath(ovalIn: NSRect(x: 636, y: 612, width: 224, height: 224))
    navy.setStroke()
    badge.lineWidth = 18
    badge.stroke()
    white.setFill()
    badge.fill()
    let shackle = NSBezierPath()
    shackle.move(to: NSPoint(x: 714, y: 728))
    shackle.line(to: NSPoint(x: 714, y: 754))
    shackle.curve(to: NSPoint(x: 782, y: 754),
                  controlPoint1: NSPoint(x: 714, y: 800),
                  controlPoint2: NSPoint(x: 782, y: 800))
    shackle.line(to: NSPoint(x: 782, y: 728))
    shackle.lineWidth = 17
    shackle.lineCapStyle = .round
    navy.setStroke()
    shackle.stroke()
    roundedRect(NSRect(x: 696, y: 664, width: 104, height: 80), radius: 15, fill: navy)
    white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 740, y: 701, width: 16, height: 16)).fill()
    roundedRect(NSRect(x: 744, y: 684, width: 8, height: 24), radius: 3, fill: white)
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                                      pixelsHigh: pixels, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(points)x\(points)\(suffix).png"
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil could not create the app icon.")
}
let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
print("Created \(output.path) (\(bytes) bytes)")

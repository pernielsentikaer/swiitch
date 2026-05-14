#!/usr/bin/env swift
// Render the app icon at every macOS app-icon size, into AppIcon.appiconset.
//
// Renders via NSBitmapImageRep at *pixel* dimensions — NSImage(size:) + lockFocus()
// would honor the display's backing scale (2× on Retina), producing PNGs that are
// twice the intended size and that actool would warn about + the Dock would refuse.
//
// Run from repo root:
//   swift Scripts/generate_icon.swift

import AppKit

let outputDir = "Swiitch/Resources/Assets.xcassets/AppIcon.appiconset"
let sizes: [(name: String, pixels: Int)] = [
    // (filename without extension, exact pixel dimension)
    ("icon_16x16",      16),
    ("icon_16x16@2x",   32),
    ("icon_32x32",      32),
    ("icon_32x32@2x",   64),
    ("icon_128x128",   128),
    ("icon_128x128@2x", 256),
    ("icon_256x256",   256),
    ("icon_256x256@2x", 512),
    ("icon_512x512",   512),
    ("icon_512x512@2x", 1024)
]

func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let dim = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    )!
    // Pin the rep to its pixel size — without this the rep is treated as 1pt = 1px
    // automatically, which is what we want, but explicit is clearer.
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: dim, height: dim)

    // Apple's squircle corner radius ≈ side × 0.2237.
    let cornerRadius = dim * 0.2237
    NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()

    // Diagonal gradient blue → violet.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.31, green: 0.42, blue: 0.95, alpha: 1.0),
        NSColor(srgbRed: 0.55, green: 0.30, blue: 0.85, alpha: 1.0)
    ])!
    gradient.draw(in: rect, angle: -45)

    // SF Symbol centered at ~55% of the canvas, white, semibold.
    let symbolPointSize = dim * 0.55
    let cfg = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "rectangle.stack.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let symbolSize = symbol.size
        let origin = NSPoint(
            x: (dim - symbolSize.width) / 2,
            y: (dim - symbolSize.height) / 2
        )
        symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func savePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Failed to encode \(path)\n".data(using: .utf8)!)
        return
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path) — \(rep.pixelsWide)×\(rep.pixelsHigh) (\(data.count) bytes)")
    } catch {
        FileHandle.standardError.write("Failed to write \(path): \(error)\n".data(using: .utf8)!)
    }
}

let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for (name, pixels) in sizes {
    let rep = renderIcon(pixels: pixels)
    savePNG(rep, to: "\(outputDir)/\(name).png")
}

let contents: [String: Any] = [
    "info": ["author": "xcode", "version": 1],
    "images": [
        ["idiom": "mac", "scale": "1x", "size": "16x16",   "filename": "icon_16x16.png"],
        ["idiom": "mac", "scale": "2x", "size": "16x16",   "filename": "icon_16x16@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "32x32",   "filename": "icon_32x32.png"],
        ["idiom": "mac", "scale": "2x", "size": "32x32",   "filename": "icon_32x32@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "128x128", "filename": "icon_128x128.png"],
        ["idiom": "mac", "scale": "2x", "size": "128x128", "filename": "icon_128x128@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "256x256", "filename": "icon_256x256.png"],
        ["idiom": "mac", "scale": "2x", "size": "256x256", "filename": "icon_256x256@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "512x512", "filename": "icon_512x512.png"],
        ["idiom": "mac", "scale": "2x", "size": "512x512", "filename": "icon_512x512@2x.png"]
    ]
]

let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: "\(outputDir)/Contents.json"))
print("Wrote \(outputDir)/Contents.json")

import AppKit

// Run from the repository root: swift Scripts/GenerateAppIcon.swift [source.png]
// The Dock icon source is independent of the transparent sidebar logo.

let assets = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Acento/Assets.xcassets")
let icons = assets.appendingPathComponent("AppIcon.appiconset")
let retainedSource = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Scripts/AppIconSource.png")
let source = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? retainedSource
let original = try Data(contentsOf: source)
guard let image = NSImage(data: original) else { fatalError("Cannot decode the source logo") }
try original.write(to: retainedSource, options: .atomic)

for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = size * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    context.imageInterpolation = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
    shadow.shadowOffset = NSSize(width: 0, height: -9)
    shadow.shadowBlurRadius = 18
    shadow.set()
    NSColor.white.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    tile.addClip()
    image.draw(in: NSRect(x: 100, y: 100, width: 824, height: 824),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: icons.appendingPathComponent(filename))
}

print("Generated ten app icon PNGs using the retained Dock icon source.")

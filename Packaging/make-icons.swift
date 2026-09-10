import AppKit

// Rasterises the SVG sources in Packaging/Icons with AppKit alone, so building
// the app needs no third-party tool.
//
//   swift Packaging/make-icons.swift icns   <AppIcon.svg> <out.icns>
//   swift Packaging/make-icons.swift readme <icons dir>   <out dir>

func fail(_ message: String) -> Never {
    fputs("make-icons: \(message)\n", stderr)
    exit(1)
}

func load(_ path: String) -> NSImage {
    guard let image = NSImage(contentsOf: URL(fileURLWithPath: path)) else { fail("cannot load \(path)") }
    return image
}

func png(_ image: NSImage, size: Int, tile: NSColor? = nil) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    if let tile {
        tile.setFill()
        NSBezierPath(roundedRect: canvas, xRadius: CGFloat(size) / 6, yRadius: CGFloat(size) / 6).fill()
    }
    image.draw(in: canvas, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, to path: String) {
    do { try data.write(to: URL(fileURLWithPath: path)) } catch { fail("cannot write \(path): \(error)") }
}

func makeICNS(source: String, output: String) {
    let image = load(source)
    let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BeQuiet-\(getpid()).iconset")
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        write(png(image, size: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png").path)
        write(png(image, size: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png").path)
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
    try! iconutil.run()
    iconutil.waitUntilExit()
    try? FileManager.default.removeItem(at: iconset)
    guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }
}

/// The README shows the same three glyphs the app builds in `MenuBarIcon`:
/// pause bars present, faded, or absent. The SVG keeps them in `<g id="pause">`.
func makeReadmeImages(iconsDir: String, outputDir: String) {
    try! FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    write(png(load("\(iconsDir)/AppIcon.svg"), size: 256), to: "\(outputDir)/app-icon.png")

    let svg = try! String(contentsOfFile: "\(iconsDir)/MenuBarIcon.svg", encoding: .utf8)
    guard svg.contains(#"<g id="pause">"#) else { fail("MenuBarIcon.svg has no <g id=\"pause\"> group") }
    let variants = [
        "listening": svg.replacingOccurrences(of: #"<g id="pause">[\s\S]*?</g>"#, with: "", options: .regularExpression),
        "armed": svg.replacingOccurrences(of: #"<g id="pause">"#, with: #"<g id="pause" fill-opacity=".45">"#),
        "paused": svg,
    ]
    let tile = NSColor(calibratedWhite: 0.96, alpha: 1)
    for (name, markup) in variants {
        guard let image = NSImage(data: Data(markup.utf8)) else { fail("variant \(name) did not parse") }
        write(png(image, size: 72, tile: tile), to: "\(outputDir)/menubar-\(name).png")
    }
}

let arguments = CommandLine.arguments.dropFirst()
switch (arguments.first, arguments.count) {
case ("icns", 3): makeICNS(source: arguments[2], output: arguments[3])
case ("readme", 3): makeReadmeImages(iconsDir: arguments[2], outputDir: arguments[3])
default: fail("usage: make-icons.swift icns <AppIcon.svg> <out.icns> | readme <icons dir> <out dir>")
}

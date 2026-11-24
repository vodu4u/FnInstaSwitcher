// Renders InstantFn's app icon (blue "fn" on clean white, full-bleed so macOS applies its own icon shape) and builds AppIcon.icns.
// Usage: swift tools/make-icon.swift   (writes InstantFn/AppIcon.icns and build/icon/AppIcon-1024.png)
// Everything is drawn with plain CoreGraphics paths: no SF Symbols, no external images.
import AppKit

let S: CGFloat = 1024

func gradient(_ colors: [NSColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3),
               colors: colors.map(\.cgColor) as CFArray, locations: locs)!
}

func render() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Full-bleed white face. macOS 26 applies its own icon mask to full-bleed artwork;
    // pre-rounded artwork with transparent margins gets put inside a gray frame instead.
    ctx.drawLinearGradient(gradient([NSColor(white: 1.0, alpha: 1), NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)], [0, 1]),
                           start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

    // "fn" in blue: text used as a clip mask, filled with a system-blue gradient.
    let font = NSFont.systemFont(ofSize: 540, weight: .semibold)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "fn", attributes: [.font: font, .kern: -8]))
    let glyphs = CTLineGetImageBounds(line, ctx)
    let origin = CGPoint(x: S/2 - glyphs.midX, y: S/2 - glyphs.midY)
    ctx.saveGState()
    ctx.textPosition = origin
    ctx.setTextDrawingMode(.clip)
    CTLineDraw(line, ctx)
    ctx.drawLinearGradient(gradient([NSColor(srgbRed: 0.20, green: 0.56, blue: 1.00, alpha: 1),
                                     NSColor(srgbRed: 0.00, green: 0.40, blue: 0.95, alpha: 1)], [0, 1]),
                           start: CGPoint(x: 0, y: origin.y + glyphs.maxY), end: CGPoint(x: 0, y: origin.y + glyphs.minY), options: [])
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let outDir = root.appendingPathComponent("build/icon"), iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = render()
try master.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("AppIcon-1024.png"))

let source = NSImage(size: NSSize(width: S, height: S)); source.addRepresentation(master)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current!.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("InstantFn/AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote InstantFn/AppIcon.icns" : "iconutil failed")

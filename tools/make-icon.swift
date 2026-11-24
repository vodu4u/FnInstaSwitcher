// Renders InstantFn's app icon (an Apple-style "fn 🌐" keycap) and builds AppIcon.icns.
// Usage: swift tools/make-icon.swift   (writes InstantFn/AppIcon.icns and build/icon/AppIcon-1024.png)
// Everything is drawn with plain CoreGraphics paths: no SF Symbols, no external images.
import AppKit

let S: CGFloat = 1024

/// Apple-like "squircle" (superellipse), used for the icon body and the keycap.
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

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

    // Body: macOS icon grid, 824×824 centered, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = squircle(body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(bodyPath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    ctx.drawLinearGradient(gradient([NSColor(srgbRed: 0.33, green: 0.62, blue: 1.00, alpha: 1),
                                     NSColor(srgbRed: 0.16, green: 0.36, blue: 0.94, alpha: 1),
                                     NSColor(srgbRed: 0.24, green: 0.18, blue: 0.78, alpha: 1)], [0, 0.55, 1]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    // Gentle top highlight.
    ctx.drawRadialGradient(gradient([NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)], [0, 1]),
                           startCenter: CGPoint(x: S/2, y: body.maxY + 40), startRadius: 0,
                           endCenter: CGPoint(x: S/2, y: body.maxY + 40), endRadius: 560, options: [])
    ctx.restoreGState()

    // Keycap: cast shadow, side wall, then the top face.
    let cap = CGRect(x: 262, y: 250, width: 500, height: 500)
    let capPath = squircle(cap, n: 4.2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 46, color: NSColor(srgbRed: 0.05, green: 0.05, blue: 0.3, alpha: 0.55).cgColor)
    ctx.addPath(squircle(cap.offsetBy(dx: 0, dy: -18), n: 4.2))
    ctx.setFillColor(NSColor(srgbRed: 0.80, green: 0.82, blue: 0.88, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(capPath); ctx.clip()
    ctx.drawLinearGradient(gradient([NSColor(white: 1.0, alpha: 1), NSColor(srgbRed: 0.93, green: 0.94, blue: 0.97, alpha: 1)], [0, 1]),
                           start: CGPoint(x: 0, y: cap.maxY), end: CGPoint(x: 0, y: cap.minY), options: [])
    ctx.restoreGState()
    ctx.addPath(capPath); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(3); ctx.strokePath()

    let ink = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.21, alpha: 1)

    // "fn" label, top-right like on Apple keyboards.
    let font = NSFont.systemFont(ofSize: 150, weight: .medium)
    let label = NSAttributedString(string: "fn", attributes: [.font: font, .foregroundColor: ink, .kern: -2])
    let ls = label.size()
    label.draw(at: CGPoint(x: cap.maxX - 64 - ls.width, y: cap.maxY - 52 - ls.height))

    // Globe, bottom-left, drawn from circles and arcs.
    let gc = CGPoint(x: cap.minX + 140, y: cap.minY + 140), gr: CGFloat = 78
    ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(11); ctx.setLineCap(.round)
    ctx.addEllipse(in: CGRect(x: gc.x - gr, y: gc.y - gr, width: 2*gr, height: 2*gr)); ctx.strokePath()
    ctx.addEllipse(in: CGRect(x: gc.x - gr*0.42, y: gc.y - gr, width: gr*0.84, height: 2*gr)); ctx.strokePath()
    ctx.move(to: CGPoint(x: gc.x, y: gc.y - gr)); ctx.addLine(to: CGPoint(x: gc.x, y: gc.y + gr)); ctx.strokePath()
    ctx.move(to: CGPoint(x: gc.x - gr, y: gc.y)); ctx.addLine(to: CGPoint(x: gc.x + gr, y: gc.y)); ctx.strokePath()
    for dy in [-0.55, 0.55] as [CGFloat] {
        let y = gc.y + gr * dy, hw = gr * sqrt(1 - dy*dy)
        ctx.move(to: CGPoint(x: gc.x - hw, y: y)); ctx.addLine(to: CGPoint(x: gc.x + hw, y: y)); ctx.strokePath()
    }

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

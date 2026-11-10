// Generates the app icon: a white SF Symbol hard drive on a black macOS-style squircle.
// Usage: swift scripts/make-icon.swift [dark|light] OUTPUT_DIR
// Writes OUTPUT_DIR/AppIcon.iconset (all sizes) and OUTPUT_DIR/AppIcon-1024.png.
import AppKit

let args = CommandLine.arguments
let style = args.count > 1 ? args[1] : "dark"
let outDir = args.count > 2 ? args[2] : "Resources"
let dark = style != "light"

/// macOS "continuous corner" squircle approximated with a superellipse (n = 5).
func squircle(in r: CGRect, n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.line(to: CGPoint(x: x, y: y))
    }
    path.close()
    return path
}

func render(size px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = CGFloat(px) / 1024
    ctx.scaleBy(x: k, y: k)

    // Apple's macOS icon grid: 824×824 shape centered on a 1024 canvas.
    let shape = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = squircle(in: shape)

    // Soft drop shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    (dark ? NSColor.black : NSColor.white).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Subtle vertical gradient for depth.
    let top = dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 1.0, alpha: 1)
    let bottom = dark ? NSColor(white: 0.04, alpha: 1) : NSColor(white: 0.86, alpha: 1)
    NSGradient(starting: bottom, ending: top)!.draw(in: path, angle: 90)

    // Hairline inner edge, like Apple's icons.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.10)).setStroke()
    path.lineWidth = 6
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The drive glyph (same symbol as the menu bar icon).
    let ink = dark ? NSColor.white : NSColor(white: 0.08, alpha: 1)
    let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
    if let sym = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = sym.size
        let scale = 560 / max(s.width, s.height)
        let w = s.width * scale, h = s.height * scale
        sym.draw(in: CGRect(x: 512 - w / 2, y: 512 - h / 2 - 8, width: w, height: h))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = "\(outDir)/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
try! render(size: 1024).write(to: URL(fileURLWithPath: "\(outDir)/AppIcon-1024.png"))
print("Wrote \(iconset) and \(outDir)/AppIcon-1024.png (\(style))")

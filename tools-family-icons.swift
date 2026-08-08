import AppKit

// Icon dance, round two: measure the glyph's real alpha bounding box and
// seat it with even margins — the SF symbol's own padding made the space
// around the speakers uneven. Speakers may only grow, never shrink.

let out = CommandLine.arguments[1]

let tan = NSColor(srgbRed: 0.85, green: 0.64, blue: 0.32, alpha: 1)
let tanDetail = NSColor(srgbRed: 0.36, green: 0.26, blue: 0.12, alpha: 1)
let white = NSColor.white
let grayDetail = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.42, alpha: 1)

func speakerSymbol(size: CGFloat, body: NSColor, detail: NSColor) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [body, detail]))
    guard let sym = NSImage(systemSymbolName: "hifispeaker.2.fill",
                            accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { fatalError("no symbol") }
    return sym
}

func bitmap(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)   // 1 point = 1 pixel, no retina trap
    return rep
}

func render(px: Int, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = bitmap(px: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}

/// The opaque bounding box of an image, in its own point space.
func alphaBBox(_ img: NSImage) -> CGRect {
    let px = 512
    let rep = render(px: px) {
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                 from: .zero, operation: .sourceOver, fraction: 1)
    }
    var minX = px, minY = px, maxX = -1, maxY = -1
    for y in 0..<px {
        for x in 0..<px {
            if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.04 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    // rep y is flipped vs drawing coords; box is symmetric enough that we
    // convert: drawing-space minY = px - 1 - maxY.
    let scaleX = img.size.width / CGFloat(px)
    let scaleY = img.size.height / CGFloat(px)
    return CGRect(x: CGFloat(minX) * scaleX,
                  y: CGFloat(px - 1 - maxY) * scaleY,
                  width: CGFloat(maxX - minX + 1) * scaleX,
                  height: CGFloat(maxY - minY + 1) * scaleY)
}

/// Draw the glyph so its bbox is centred in the art rect with the tightest
/// current margin on the LARGEST dimension — growth only.
func placeGlyph(body: NSColor, detail: NSColor, art: CGRect) {
    let base = speakerSymbol(size: art.width * 0.52, body: body, detail: detail)
    let box = alphaBBox(base)
    // Margins as drawn today (image centred in art).
    let imgOrigin = CGPoint(x: art.midX - base.size.width / 2,
                            y: art.midY - base.size.height / 2)
    let l = imgOrigin.x + box.minX - art.minX
    let r = art.maxX - (imgOrigin.x + box.maxX)
    let b = imgOrigin.y + box.minY - art.minY
    let t = art.maxY - (imgOrigin.y + box.maxY)
    let m = min(l, r, t, b)
    let maxDim = max(box.width, box.height)
    let s = (min(art.width, art.height) - 2 * m) / maxDim
    let newSize = NSSize(width: base.size.width * s, height: base.size.height * s)
    let boxMid = CGPoint(x: box.midX * s, y: box.midY * s)
    let origin = CGPoint(x: art.midX - boxMid.x, y: art.midY - boxMid.y)
    base.draw(in: NSRect(origin: origin, size: newSize),
              from: .zero, operation: .sourceOver, fraction: 1)
}

let canvas: CGFloat = 1024
let fullArt = CGRect(x: 0, y: 0, width: canvas, height: canvas)

// 1. SoNew iOS: black square, tan.
writePNG(render(px: 1024) {
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    placeGlyph(body: tan, detail: tanDetail, art: fullArt)
}, "\(out)/sonew-ios-1024.png")

// 2. KEF iOS: near-black gradient, white.
writePNG(render(px: 1024) {
    NSGradient(colors: [
        NSColor(srgbRed: 0.105, green: 0.105, blue: 0.11, alpha: 1),
        NSColor(srgbRed: 0.02, green: 0.02, blue: 0.022, alpha: 1),
    ])!.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: -90)
    placeGlyph(body: white, detail: grayDetail, art: fullArt)
}, "\(out)/kef-ios-1024.png")

// 3-5. The Mac squircles: SoNew tan, KEF Control white, KEF Audio white.
let inset: CGFloat = 100
let artSize = canvas - inset * 2
let squircleArt = CGRect(x: inset, y: inset, width: artSize, height: artSize)

func macMaster(body: NSColor, detail: NSColor) -> NSBitmapImageRep {
    render(px: 1024) {
        let rect = NSRect(x: inset, y: inset, width: artSize, height: artSize)
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: artSize * 0.224, yRadius: artSize * 0.224)
        NSGraphicsContext.current?.cgContext.saveGState()
        path.addClip()
        NSGradient(colors: [
            NSColor(srgbRed: 0.26, green: 0.26, blue: 0.28, alpha: 1),
            NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
        ])!.draw(in: rect, angle: -90)
        NSGraphicsContext.current?.cgContext.restoreGState()
        placeGlyph(body: body, detail: detail, art: squircleArt)
    }
}

let variants: [(px: Int, name: String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

func writeIconset(_ master: NSBitmapImageRep, dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    guard let cg = master.cgImage else { fatalError("no cg") }
    let masterImg = NSImage(cgImage: cg, size: NSSize(width: 1024, height: 1024))
    for v in variants {
        writePNG(render(px: v.px) {
            masterImg.draw(in: NSRect(x: 0, y: 0, width: v.px, height: v.px),
                           from: .zero, operation: .copy, fraction: 1)
        }, "\(dir)/\(v.name)")
    }
}

writeIconset(macMaster(body: tan, detail: tanDetail), dir: "\(out)/sonew-mac.iconset")
writeIconset(macMaster(body: white, detail: grayDetail), dir: "\(out)/kef-mac.iconset")
print("klaar")

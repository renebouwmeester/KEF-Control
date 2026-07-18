import AppKit

// Builds an .iconset from the same SF Symbol the menu bar uses, so the Dock
// icon and the status item read as the same mark.
//
//   swift make_icon.swift <out.iconset> [symbolName]

let outDir = CommandLine.arguments[1]
let symbolName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "hifispeaker.2.fill"

/// macOS icon grid: art sits inside the 1024 canvas with a margin, and the
/// squircle's corner radius is ~22.4% of the art's width.
let canvas: CGFloat = 1024
let inset: CGFloat = 100                 // transparent margin all round
let artSize = canvas - inset * 2
let corner = artSize * 0.224

func drawIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: canvas, height: canvas))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }
    ctx.setShouldAntialias(true)

    // Rounded-rect body with a soft top-to-bottom gradient, matching the dark
    // panel the app itself draws.
    let rect = NSRect(x: inset, y: inset, width: artSize, height: artSize)
    let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    ctx.saveGState()
    path.addClip()
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.26, green: 0.26, blue: 0.28, alpha: 1),
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
    ])!
    grad.draw(in: rect, angle: -90)
    ctx.restoreGState()

    // The glyph, rendered white and centred at ~52% of the art width.
    let cfg = NSImage.SymbolConfiguration(pointSize: artSize * 0.52, weight: .regular)
    guard let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { fatalError("no symbol \(symbolName)") }

    let tinted = NSImage(size: sym.size)
    tinted.lockFocus()
    NSColor.white.set()
    NSRect(origin: .zero, size: sym.size).fill(using: .sourceOver)
    sym.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
    tinted.unlockFocus()

    let s = tinted.size
    tinted.draw(in: NSRect(x: (canvas - s.width) / 2, y: (canvas - s.height) / 2,
                           width: s.width, height: s.height))
    img.unlockFocus()
    return img
}

let master = drawIcon()
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

/// iconutil expects exactly these names.
let variants: [(px: Int, name: String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for v in variants {
    let target = NSImage(size: NSSize(width: v.px, height: v.px))
    target.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: v.px, height: v.px),
                from: NSRect(origin: .zero, size: master.size),
                operation: .copy, fraction: 1)
    target.unlockFocus()
    guard let tiff = target.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: URL(fileURLWithPath: "\(outDir)/\(v.name)"))
}
print("wrote \(variants.count) sizes to \(outDir)")

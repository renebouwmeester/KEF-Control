// Shared constants and the platform seam. Everything in Sources/Core compiles
// without AppKit or Carbon; the few genuinely platform-bound pieces (image
// type, artwork tinting, glyph loading) live behind the conditionals here so
// an iOS shell only has to fill in the #else branches.
import SwiftUI

#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// Presets row collapse/expand timing, shared by the SwiftUI row animation and
/// the panel's own height ramp so the window edge tracks the content exactly.
/// `defaults write <bundle-id> AnimDuration 2.0` slows it down for inspection
/// (and tuning); anything <= 0 or unset uses the default.
enum PanelAnim {
    static let duration: Double = {
        let d = UserDefaults.standard.double(forKey: "AnimDuration")
        return d > 0 ? d : 0.22
    }()
}

/// The panel window is a fixed-size, fully transparent canvas: it never
/// resizes, so SwiftUI owns every pixel of the card's motion. The canvas is
/// deliberately taller than any state's content; the surplus is transparent and
/// clicks pass straight through it.
enum PanelMetrics {
    static let width: CGFloat = 300
    static let cornerRadius: CGFloat = 12
    /// Room around the card for the SwiftUI shadow to render into.
    static let shadowMargin: CGFloat = 22
    static let canvasHeight: CGFloat = 820
}

// Hardcoded accent (#98A8D9): the system accent resolves differently per macOS
// version (26 gives a harder blue), so pin the macOS 27 dark-mode value.
extension Color {
    static let appAccent = Color(red: 0.5961, green: 0.6588, blue: 0.8510)
}

/// Bundled template PNGs for inputs SF Symbols doesn't cover — Bluetooth's
/// rune is a trademark, so there is no system symbol for it. isTemplate
/// makes AppKit tint it from its alpha channel, exactly like a symbol.
func templateGlyph(named name: String, size: CGSize) -> PlatformImage? {
    guard let path = Bundle.main.path(forResource: name, ofType: "png") else { return nil }
    #if canImport(AppKit)
    guard let img = NSImage(contentsOfFile: path) else { return nil }
    img.isTemplate = true
    img.size = size
    return img
    #else
    // UIImage has no settable point size; bake the wanted size in via the
    // scale factor instead (the view draws the image at pixels ÷ scale).
    guard let ui = UIImage(contentsOfFile: path), let cg = ui.cgImage else { return nil }
    return UIImage(cgImage: cg, scale: ui.size.width * ui.scale / size.width,
                   orientation: .up).withRenderingMode(.alwaysTemplate)
    #endif
}

/// Dominant hue of the artwork, darkened to a panel-background level.
/// Returns nil for effectively monochrome images.
func dominantDarkTint(from image: PlatformImage) -> Color? {
    #if canImport(AppKit)
    let size = 24
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    // histogram over 12 hue buckets, colorful pixels only
    var buckets = [(count: Int, r: CGFloat, g: CGFloat, b: CGFloat)](
        repeating: (0, 0, 0, 0), count: 12)
    for y in 0..<size {
        for x in 0..<size {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            guard c.saturationComponent > 0.2,
                  c.brightnessComponent > 0.15, c.brightnessComponent < 0.95
            else { continue }
            let bucket = min(11, Int(c.hueComponent * 12))
            buckets[bucket].count += 1
            buckets[bucket].r += c.redComponent
            buckets[bucket].g += c.greenComponent
            buckets[bucket].b += c.blueComponent
        }
    }
    guard let best = buckets.max(by: { $0.count < $1.count }),
          best.count >= 20 else { return nil }  // < ~3% colorful: treat as mono

    let n = CGFloat(best.count)
    let avg = NSColor(red: best.r / n, green: best.g / n, blue: best.b / n, alpha: 1)
    return Color(nsColor: NSColor(
        hue: avg.hueComponent,
        saturation: min(avg.saturationComponent, 0.55),
        brightness: 0.17,
        alpha: 1
    ))
    #else
    // Same histogram as the AppKit branch, but via CoreGraphics: downsample
    // into an sRGB bitmap and convert pixels to HSB by hand (UIColor's
    // getHue is per-instance and would allocate 576 of them).
    let size = 24
    guard let cg = image.cgImage,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let buf = ctx.data else { return nil }
    let px = buf.bindMemory(to: UInt8.self, capacity: size * size * 4)

    // histogram over 12 hue buckets, colorful pixels only
    var buckets = [(count: Int, r: Double, g: Double, b: Double)](
        repeating: (0, 0, 0, 0), count: 12)
    for i in 0..<(size * size) {
        let r = Double(px[i * 4]) / 255
        let g = Double(px[i * 4 + 1]) / 255
        let b = Double(px[i * 4 + 2]) / 255
        let (h, s, v) = rgbToHSB(r: r, g: g, b: b)
        guard s > 0.2, v > 0.15, v < 0.95 else { continue }
        let bucket = min(11, Int(h * 12))
        buckets[bucket].count += 1
        buckets[bucket].r += r
        buckets[bucket].g += g
        buckets[bucket].b += b
    }
    guard let best = buckets.max(by: { $0.count < $1.count }),
          best.count >= 20 else { return nil }  // < ~3% colorful: treat as mono

    let n = Double(best.count)
    let (h, s, _) = rgbToHSB(r: best.r / n, g: best.g / n, b: best.b / n)
    return Color(hue: h, saturation: min(s, 0.55), brightness: 0.17)
    #endif
}

#if !canImport(AppKit)
private func rgbToHSB(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
    let mx = Swift.max(r, g, b), mn = Swift.min(r, g, b), d = mx - mn
    guard d > 0 else { return (0, 0, mx) }
    var h: Double
    if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
    else if mx == g { h = (b - r) / d + 2 }
    else { h = (r - g) / d + 4 }
    h /= 6
    if h < 0 { h += 1 }
    return (h, mx == 0 ? 0 : d / mx, mx)
}
#endif

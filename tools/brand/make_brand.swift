// Builds the OM Drop icon set and brand assets from Brand/source/logo-mark-source.webp.
//
//   swift tools/brand/make_brand.swift
//
// Outputs:
//   App/Shared/Assets.xcassets/AppIcon.appiconset   iOS (light, dark, tinted) + macOS sizes
//   App/Shared/Assets.xcassets/LogoMark.imageset     template glyph used inside the app
//   Brand/*.png                                       marks, lockups, icons, palette

import AppKit
import CoreText
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Brand/source/logo-mark-source.webp")
let brand = root.appendingPathComponent("Brand")
let assets = root.appendingPathComponent("App/Shared/Assets.xcassets")

// Palette (from the brand board)
func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let ink = rgb(0x000000), graphite = rgb(0x4A4A4A), silver = rgb(0xC9C9C9), paper = rgb(0xF5F5F5), white = rgb(0xFFFFFF)

// MARK: Glyph mask

/// Dark pixels of the source become the glyph. Returns a grayscale mask (white = glyph), cropped.
func glyphMask() -> CGImage {
    guard let img = NSImage(contentsOf: source)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("cannot read \(source.path)")
    }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(white)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    // Clean levels: <=70 solid glyph, >=200 empty (drops the soft grey shading).
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
        for x in 0..<w {
            let v = Int(px[y * w + x])
            let a = v <= 70 ? 255 : v >= 200 ? 0 : (200 - v) * 255 / 130
            px[y * w + x] = UInt8(a)
            if a > 40 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    let full = ctx.makeImage()!
    // CGContext rows are top-down in memory; makeImage keeps that orientation.
    let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    return full.cropping(to: crop)!
}

let mask = glyphMask()
let aspect = CGFloat(mask.width) / CGFloat(mask.height)
print("glyph \(mask.width)x\(mask.height)")

// MARK: Drawing helpers

func render(_ w: Int, _ h: Int, opaque: Bool = false, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    draw(ctx)
    return ctx.makeImage()!
}

/// Paint the glyph in `color`, fitted (keeping proportions) into `rect`.
func drawGlyph(_ ctx: CGContext, in rect: CGRect, color: CGColor) {
    var r = rect
    if rect.width / rect.height > aspect {
        r.size.width = rect.height * aspect
        r.origin.x = rect.midX - r.width / 2
    } else {
        r.size.height = rect.width / aspect
        r.origin.y = rect.midY - r.height / 2
    }
    ctx.saveGState()
    ctx.clip(to: r, mask: mask)
    ctx.setFillColor(color)
    ctx.fill(r)
    ctx.restoreGState()
}

func save(_ img: CGImage, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func squircle(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
}

func gradient(_ ctx: CGContext, _ top: CGColor, _ bottom: CGColor, _ rect: CGRect) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
}

// MARK: App icons

let glyphWidth: CGFloat = 0.70  // of the icon width

/// iOS icons are full-bleed squares; the system applies the corner mask.
func iosIcon(_ style: String) -> CGImage {
    render(1024, 1024, opaque: true) { c in
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let glyph = full.insetBy(dx: 1024 * (1 - glyphWidth) / 2, dy: 1024 * (1 - glyphWidth) / 2)
        switch style {
        case "light":
            gradient(c, white, rgb(0xECECEC), full)
            drawGlyph(c, in: glyph, color: ink)
        case "dark":
            gradient(c, rgb(0x2A2A2A), ink, full)
            drawGlyph(c, in: glyph, color: paper)
        default:  // tinted: grayscale on black, the system adds the tint
            c.setFillColor(ink)
            c.fill(full)
            drawGlyph(c, in: glyph, color: white)
        }
    }
}

/// macOS icons carry their own rounded shape inside the standard 1024 grid (824 body).
func macIcon(_ size: Int) -> CGImage {
    render(size, size) { c in
        let s = CGFloat(size)
        let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 20 / 1024,
                    color: CGColor(gray: 0, alpha: 0.35))
        c.addPath(squircle(body))
        c.setFillColor(ink)
        c.fillPath()
        c.restoreGState()
        c.saveGState()
        c.addPath(squircle(body))
        c.clip()
        gradient(c, rgb(0x2C2C2C), ink, body)
        c.restoreGState()
        let g = body.insetBy(dx: body.width * 0.15, dy: body.width * 0.15)
        drawGlyph(c, in: g, color: paper)
    }
}

let iconset = assets.appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.removeItem(at: iconset)
var images: [[String: Any]] = []
for style in ["light", "dark", "tinted"] {
    let name = "ios-\(style).png"
    save(iosIcon(style), iconset.appendingPathComponent(name))
    var entry: [String: Any] = ["filename": name, "idiom": "universal", "platform": "ios", "size": "1024x1024"]
    if style != "light" { entry["appearances"] = [["appearance": "luminosity", "value": style]] }
    images.append(entry)
}
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = "mac-\(pt)@\(scale)x.png"
        save(macIcon(pt * scale), iconset.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)"])
    }
}
func writeJSON(_ obj: Any, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}
writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], iconset.appendingPathComponent("Contents.json"))
writeJSON(["info": ["author": "xcode", "version": 1]], assets.appendingPathComponent("Contents.json"))

// In-app logo (template image: tinted by SwiftUI's foreground style)
let logoSet = assets.appendingPathComponent("LogoMark.imageset")
try? FileManager.default.removeItem(at: logoSet)
let markW = 600, markH = Int(600 / aspect)
save(render(markW, markH) { drawGlyph($0, in: CGRect(x: 0, y: 0, width: markW, height: markH), color: ink) },
     logoSet.appendingPathComponent("logo-mark.png"))
writeJSON(["images": [["filename": "logo-mark.png", "idiom": "universal"]],
           "info": ["author": "xcode", "version": 1],
           "properties": ["template-rendering-intent": "template", "preserves-vector-representation": false]],
          logoSet.appendingPathComponent("Contents.json"))

// Accent colour: ink in light mode, paper in dark mode (monochrome brand)
let accent = assets.appendingPathComponent("AccentColor.colorset")
func comp(_ hex: String) -> [String: Any] {
    ["color": ["color-space": "srgb", "components": ["red": "0x" + hex.prefix(2), "green": "0x" + hex.dropFirst(2).prefix(2),
                                                     "blue": "0x" + hex.suffix(2), "alpha": "1.000"]], "idiom": "universal"]
}
var dark = comp("F5F5F5")
dark["appearances"] = [["appearance": "luminosity", "value": "dark"]]
writeJSON(["colors": [comp("1C1C1E"), dark], "info": ["author": "xcode", "version": 1]], accent.appendingPathComponent("Contents.json"))

// MARK: Brand files

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont { NSFont.systemFont(ofSize: size, weight: weight) as CTFont }

func line(_ parts: [(String, CTFont)], color: CGColor, kern: CGFloat = 0) -> CTLine {
    let s = NSMutableAttributedString()
    for (text, f) in parts {
        s.append(NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: NSColor(cgColor: color)!, .kern: kern]))
    }
    return CTLineCreateWithAttributedString(s)
}

func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

func wordmark(_ size: CGFloat, color: CGColor) -> CTLine {
    line([("OM", font(size, .heavy)), (" Drop", font(size, .regular))], color: color, kern: -size * 0.01)
}

for (variant, fg, bg) in [("black", ink, nil as CGColor?), ("white", paper, nil), ("on-dark", paper, ink as CGColor?)] {
    // Mark
    if bg == nil {
        save(render(2048, Int(2048 / aspect)) { drawGlyph($0, in: CGRect(x: 0, y: 0, width: 2048, height: 2048 / aspect), color: fg) },
             brand.appendingPathComponent("logo-mark-\(variant).png"))
    }
    // Stacked lockup: mark above "OM Drop"
    let W = 1600, H = 1400
    save(render(W, H, opaque: bg != nil) { c in
        if let bg { c.setFillColor(bg); c.fill(CGRect(x: 0, y: 0, width: W, height: H)) }
        drawGlyph(c, in: CGRect(x: 400, y: 560, width: 800, height: 720), color: fg)
        let word = wordmark(250, color: fg)
        c.textPosition = CGPoint(x: (CGFloat(W) - width(word)) / 2, y: 260)
        CTLineDraw(word, c)
        let tag = line([("SHOOT · CONNECT · IMPORT", font(54, .medium))], color: bg == nil ? fg : silver, kern: 14)
        c.textPosition = CGPoint(x: (CGFloat(W) - width(tag)) / 2, y: 130)
        CTLineDraw(tag, c)
    }, brand.appendingPathComponent("lockup-stacked-\(variant).png"))
    // Horizontal lockup: mark left of "OM Drop"
    save(render(2400, 700, opaque: bg != nil) { c in
        if let bg { c.setFillColor(bg); c.fill(CGRect(x: 0, y: 0, width: 2400, height: 700)) }
        drawGlyph(c, in: CGRect(x: 120, y: 120, width: 560, height: 460), color: fg)
        let word = wordmark(300, color: fg)
        c.textPosition = CGPoint(x: 760, y: 245)
        CTLineDraw(word, c)
    }, brand.appendingPathComponent("lockup-horizontal-\(variant).png"))
}

save(iosIcon("light"), brand.appendingPathComponent("app-icon-light.png"))
save(iosIcon("dark"), brand.appendingPathComponent("app-icon-dark.png"))
save(macIcon(1024), brand.appendingPathComponent("app-icon-macos.png"))

// Palette swatches
let swatches: [(String, UInt32, String)] = [("Ink", 0x000000, "#000000"), ("Graphite", 0x4A4A4A, "#4A4A4A"),
                                            ("Silver", 0xC9C9C9, "#C9C9C9"), ("Paper", 0xF5F5F5, "#F5F5F5")]
save(render(1600, 520, opaque: true) { c in
    c.setFillColor(white); c.fill(CGRect(x: 0, y: 0, width: 1600, height: 520))
    for (i, s) in swatches.enumerated() {
        let r = CGRect(x: 80 + i * 370, y: 170, width: 330, height: 280)
        c.addPath(CGPath(roundedRect: r, cornerWidth: 40, cornerHeight: 40, transform: nil))
        c.setFillColor(rgb(s.1)); c.fillPath()
        c.addPath(CGPath(roundedRect: r, cornerWidth: 40, cornerHeight: 40, transform: nil))
        c.setStrokeColor(rgb(0xE0E0E0)); c.setLineWidth(3); c.strokePath()
        let name = line([(s.0, font(44, .semibold))], color: ink)
        c.textPosition = CGPoint(x: r.minX + 4, y: 100); CTLineDraw(name, c)
        let hex = line([(s.2, font(36, .regular))], color: graphite)
        c.textPosition = CGPoint(x: r.minX + 4, y: 50); CTLineDraw(hex, c)
    }
}, brand.appendingPathComponent("palette.png"))

print("done")

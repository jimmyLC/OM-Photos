// Builds the OM Photos icon set and brand assets from Brand/source/logo-mark-source.webp.
//
//   swift tools/brand/make_brand.swift
//
// Outputs:
//   App/Shared/Assets.xcassets/AppIcon.appiconset   iOS (light, dark, tinted) + macOS sizes
//   App/Shared/Assets.xcassets/LogoMark.imageset    the mark used inside the app (light and dark)
//   Brand/*.png                                      marks, lockups, icons, palette

import AppKit
import CoreText
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Brand/source/logo-mark-source.webp")
let brand = root.appendingPathComponent("Brand")
let assets = root.appendingPathComponent("App/Shared/Assets.xcassets")
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// Palette (from the brand board)
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let black = rgb(0x000000), darkGray = rgb(0x333333), silver = rgb(0xC0C0C0), lightGray = rgb(0xE5E5E5), white = rgb(0xFFFFFF)

// MARK: Cut the camera out of its white background

struct Pixels {
    let w: Int, h: Int
    var data: [UInt8]  // RGBA, premultiplied, top row first

    func image() -> CGImage {
        var copy = data
        return copy.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    func luminance(_ i: Int) -> Int { (Int(data[i * 4]) * 299 + Int(data[i * 4 + 1]) * 587 + Int(data[i * 4 + 2]) * 114) / 1000 }

    mutating func set(_ i: Int, _ r: Int, _ g: Int, _ b: Int, _ a: Int) {
        data[i * 4] = UInt8(r * a / 255); data[i * 4 + 1] = UInt8(g * a / 255)
        data[i * 4 + 2] = UInt8(b * a / 255); data[i * 4 + 3] = UInt8(a)
    }
}

func loadSource() -> Pixels {
    guard let img = NSImage(contentsOf: source)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("cannot read \(source.path)")
    }
    let w = img.width, h = img.height
    var data = [UInt8](repeating: 255, count: w * h * 4)
    data.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return Pixels(w: w, h: h, data: data)
}

/// Flood fill the white around the camera (the black outline keeps the fill outside),
/// soften the outline's edge, and crop to what is left.
func cutout() -> Pixels {
    var p = loadSource()
    let w = p.w, h = p.h
    var outside = [Bool](repeating: false, count: w * h)
    var stack: [Int] = []
    func visit(_ i: Int) {
        if !outside[i], p.luminance(i) >= 225 { outside[i] = true; stack.append(i) }
    }
    for x in 0..<w { visit(x); visit((h - 1) * w + x) }
    for y in 0..<h { visit(y * w); visit(y * w + w - 1) }
    while let i = stack.popLast() {
        let x = i % w, y = i / w
        if x > 0 { visit(i - 1) }
        if x < w - 1 { visit(i + 1) }
        if y > 0 { visit(i - w) }
        if y < h - 1 { visit(i + w) }
    }
    // Anti-aliased pixels next to the background become partly transparent outline.
    var edge: [(Int, Int)] = []
    for y in 2..<(h - 2) {
        for x in 2..<(w - 2) {
            let i = y * w + x
            guard !outside[i], p.luminance(i) > 40 else { continue }
            let near = [-1, 1, -w, w, -2, 2, -2 * w, 2 * w].contains { outside[i + $0] }
            if near { edge.append((i, min(255, max(0, (255 - p.luminance(i)) * 255 / 235)))) }
        }
    }
    for (i, a) in edge { p.set(i, 20, 20, 20, a) }
    var minX = w, minY = h, maxX = 0, maxY = 0
    for i in 0..<(w * h) {
        if outside[i] { p.set(i, 0, 0, 0, 0); continue }
        if p.data[i * 4 + 3] > 60 {
            minX = min(minX, i % w); maxX = max(maxX, i % w); minY = min(minY, i / w); maxY = max(maxY, i / w)
        }
    }
    var out = Pixels(w: maxX - minX + 1, h: maxY - minY + 1, data: [])
    for y in minY...maxY {
        out.data.append(contentsOf: p.data[(y * w + minX) * 4..<(y * w + maxX + 1) * 4])
    }
    return out
}

let colorPixels = cutout()
let mark = colorPixels.image()
let aspect = CGFloat(mark.width) / CGFloat(mark.height)
print("mark \(mark.width)x\(mark.height)")

let grayMark: CGImage = {
    var p = colorPixels
    for i in 0..<(p.w * p.h) {
        let l = UInt8(p.luminance(i))
        p.data[i * 4] = l; p.data[i * 4 + 1] = l; p.data[i * 4 + 2] = l
    }
    return p.image()
}()

/// White = opaque; used to paint the silhouette or the one-colour version.
func mask(_ value: (Pixels, Int) -> Int) -> CGImage {
    let p = colorPixels
    var gray = [UInt8](repeating: 0, count: p.w * p.h)
    for i in 0..<(p.w * p.h) { gray[i] = UInt8(value(p, i)) }
    return gray.withUnsafeMutableBytes { buffer in
        CGContext(data: buffer.baseAddress, width: p.w, height: p.h, bitsPerComponent: 8, bytesPerRow: p.w,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()!
    }
}
let silhouette = mask { p, i in Int(p.data[i * 4 + 3]) }
/// Dark parts only, for the one-colour mark.
let inkMask = mask { p, i in
    let a = Int(p.data[i * 4 + 3])
    guard a > 0 else { return 0 }
    let l = p.luminance(i) * 255 / a  // undo premultiplication
    return a * min(255, max(0, (170 - l) * 255 / 70)) / 255
}

// MARK: Drawing helpers

func render(_ w: Int, _ h: Int, opaque: Bool = false, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    draw(ctx)
    return ctx.makeImage()!
}

/// `rect` fitted to the mark's proportions.
func fitted(_ rect: CGRect) -> CGRect {
    var r = rect
    if rect.width / rect.height > aspect {
        r.size.width = rect.height * aspect
        r.origin.x = rect.midX - r.width / 2
    } else {
        r.size.height = rect.width / aspect
        r.origin.y = rect.midY - r.height / 2
    }
    return r
}

func fill(_ ctx: CGContext, _ maskImage: CGImage, in r: CGRect, color: CGColor) {
    ctx.saveGState()
    ctx.clip(to: r, mask: maskImage)
    ctx.setFillColor(color)
    ctx.fill(r)
    ctx.restoreGState()
}

/// The full-colour mark; `rim` adds a light edge so the black outline shows on dark backgrounds.
func drawMark(_ ctx: CGContext, in rect: CGRect, image: CGImage = mark, rim: CGColor? = nil) {
    let r = fitted(rect)
    if let rim {
        let radius = r.width * 0.014
        for step in 0..<48 {
            let angle = CGFloat(step) / 48 * 2 * .pi
            fill(ctx, silhouette, in: r.offsetBy(dx: cos(angle) * radius, dy: sin(angle) * radius), color: rim)
        }
    }
    ctx.draw(image, in: r)
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
    let g = CGGradient(colorsSpace: sRGB, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
}

// MARK: App icons

let markWidth: CGFloat = 0.78  // of the icon width

/// iOS icons are full-bleed squares; the system applies the corner mask.
func iosIcon(_ style: String) -> CGImage {
    render(1024, 1024, opaque: true) { c in
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let box = full.insetBy(dx: 1024 * (1 - markWidth) / 2, dy: 1024 * (1 - markWidth) / 2)
        switch style {
        case "light":
            gradient(c, white, lightGray, full)
            drawMark(c, in: box)
        case "dark":
            gradient(c, darkGray, black, full)
            drawMark(c, in: box, rim: silver)
        default:  // tinted: grayscale on black, the system adds the tint
            c.setFillColor(black)
            c.fill(full)
            drawMark(c, in: box, image: grayMark, rim: silver)
        }
    }
}

/// macOS icons carry their own rounded shape inside the standard 1024 grid (824 body).
func macIcon(_ size: Int) -> CGImage {
    render(size, size) { c in
        let s = CGFloat(size)
        let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 22 / 1024, color: CGColor(gray: 0, alpha: 0.35))
        c.addPath(squircle(body))
        c.setFillColor(white)
        c.fillPath()
        c.restoreGState()
        c.saveGState()
        c.addPath(squircle(body))
        c.clip()
        gradient(c, white, lightGray, body)
        c.restoreGState()
        drawMark(c, in: body.insetBy(dx: body.width * (1 - 0.80) / 2, dy: body.width * (1 - 0.80) / 2))
    }
}

func writeJSON(_ obj: Any, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}
let info: [String: Any] = ["author": "xcode", "version": 1]

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
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "mac-\(pt)@\(scale)x.png"
        save(macIcon(pt * scale), iconset.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)"])
    }
}
writeJSON(["images": images, "info": info], iconset.appendingPathComponent("Contents.json"))
writeJSON(["info": info], assets.appendingPathComponent("Contents.json"))

// In-app logo: the colour mark, with a light rim in dark mode
func markImage(width: Int, rim: CGColor?, pad: CGFloat = 0.02) -> CGImage {
    let h = Int(CGFloat(width) / aspect)
    return render(width, h) { drawMark($0, in: CGRect(x: 0, y: 0, width: width, height: h)
        .insetBy(dx: CGFloat(width) * pad, dy: CGFloat(h) * pad), rim: rim) }
}
let logoSet = assets.appendingPathComponent("LogoMark.imageset")
try? FileManager.default.removeItem(at: logoSet)
save(markImage(width: 720, rim: nil), logoSet.appendingPathComponent("logo-light.png"))
save(markImage(width: 720, rim: silver), logoSet.appendingPathComponent("logo-dark.png"))
writeJSON(["images": [["filename": "logo-light.png", "idiom": "universal"],
                      ["filename": "logo-dark.png", "idiom": "universal",
                       "appearances": [["appearance": "luminosity", "value": "dark"]]]],
           "info": info, "properties": ["template-rendering-intent": "original"]],
          logoSet.appendingPathComponent("Contents.json"))

// Accent colour: monochrome brand (black in light mode, light gray in dark mode)
func color(_ hex: String) -> [String: Any] {
    ["color": ["color-space": "srgb", "components": ["red": "0x" + hex.prefix(2), "green": "0x" + hex.dropFirst(2).prefix(2),
                                                     "blue": "0x" + hex.suffix(2), "alpha": "1.000"]], "idiom": "universal"]
}
var darkAccent = color("E5E5E5")
darkAccent["appearances"] = [["appearance": "luminosity", "value": "dark"]]
writeJSON(["colors": [color("000000"), darkAccent], "info": info],
          assets.appendingPathComponent("AccentColor.colorset/Contents.json"))

// MARK: Brand files

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont { NSFont.systemFont(ofSize: size, weight: weight) as CTFont }

func line(_ text: String, _ f: CTFont, _ color: CGColor, kern: CGFloat = 0) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(
        string: text, attributes: [.font: f, .foregroundColor: NSColor(cgColor: color)!, .kern: kern]))
}

func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

func wordmark(_ size: CGFloat, _ color: CGColor) -> CTLine { line("OM Photos", font(size, .bold), color, kern: -size * 0.015) }

for file in (try? FileManager.default.contentsOfDirectory(at: brand, includingPropertiesForKeys: nil)) ?? []
where file.pathExtension == "png" { try? FileManager.default.removeItem(at: file) }

enum Variant: String, CaseIterable {
    case primary, black, reversed
}

func drawVariant(_ c: CGContext, _ v: Variant, in rect: CGRect) {
    switch v {
    case .primary: drawMark(c, in: rect)
    case .black: fill(c, inkMask, in: fitted(rect), color: black)
    case .reversed: drawMark(c, in: rect, rim: silver)
    }
}

for v in Variant.allCases {
    let background: CGColor? = v == .reversed ? black : nil
    let text = v == .reversed ? white : black
    let markH = Int(2048 / aspect)
    save(render(2048, markH, opaque: background != nil) { c in
        if let background { c.setFillColor(background); c.fill(CGRect(x: 0, y: 0, width: 2048, height: markH)) }
        drawVariant(c, v, in: CGRect(x: 0, y: 0, width: 2048, height: markH).insetBy(dx: 40, dy: 40))
    }, brand.appendingPathComponent("logo-mark-\(v.rawValue).png"))
    // Stacked: mark above the name and the line from the brand board
    save(render(1600, 1400, opaque: background != nil) { c in
        if let background { c.setFillColor(background); c.fill(CGRect(x: 0, y: 0, width: 1600, height: 1400)) }
        drawVariant(c, v, in: CGRect(x: 350, y: 540, width: 900, height: 760))
        let word = wordmark(230, text)
        c.textPosition = CGPoint(x: (1600 - width(word)) / 2, y: 250)
        CTLineDraw(word, c)
        let tag = line("The simplest way to bring photos from your camera.", font(52, .medium),
                       v == .reversed ? silver : darkGray)
        c.textPosition = CGPoint(x: (1600 - width(tag)) / 2, y: 130)
        CTLineDraw(tag, c)
    }, brand.appendingPathComponent("lockup-stacked-\(v.rawValue).png"))
    // Horizontal: mark left of the name
    save(render(2400, 700, opaque: background != nil) { c in
        if let background { c.setFillColor(background); c.fill(CGRect(x: 0, y: 0, width: 2400, height: 700)) }
        drawVariant(c, v, in: CGRect(x: 100, y: 100, width: 720, height: 500))
        let word = wordmark(280, text)
        c.textPosition = CGPoint(x: 900, y: 255)
        CTLineDraw(word, c)
    }, brand.appendingPathComponent("lockup-horizontal-\(v.rawValue).png"))
}

save(iosIcon("light"), brand.appendingPathComponent("app-icon-light.png"))
save(iosIcon("dark"), brand.appendingPathComponent("app-icon-dark.png"))
save(macIcon(1024), brand.appendingPathComponent("app-icon-macos.png"))

// Palette swatches
let swatches: [(String, UInt32, String)] = [("Black", 0x000000, "#000000"), ("Dark Gray", 0x333333, "#333333"),
    ("Silver", 0xC0C0C0, "#C0C0C0"), ("Light Gray", 0xE5E5E5, "#E5E5E5"), ("White", 0xFFFFFF, "#FFFFFF")]
save(render(1930, 520, opaque: true) { c in
    c.setFillColor(white); c.fill(CGRect(x: 0, y: 0, width: 1930, height: 520))
    for (i, s) in swatches.enumerated() {
        let r = CGRect(x: 80 + i * 360, y: 170, width: 330, height: 280)
        c.addPath(CGPath(roundedRect: r, cornerWidth: 40, cornerHeight: 40, transform: nil))
        c.setFillColor(rgb(s.1)); c.fillPath()
        c.addPath(CGPath(roundedRect: r, cornerWidth: 40, cornerHeight: 40, transform: nil))
        c.setStrokeColor(silver); c.setLineWidth(3); c.strokePath()
        c.textPosition = CGPoint(x: r.minX + 4, y: 100); CTLineDraw(line(s.0, font(44, .semibold), black), c)
        c.textPosition = CGPoint(x: r.minX + 4, y: 50); CTLineDraw(line(s.2, font(36, .regular), darkGray), c)
    }
}, brand.appendingPathComponent("palette.png"))

print("done")

// Renders the 1200x630 social images: swift scripts/make-og.swift
import AppKit
import CoreText
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let mark = NSImage(contentsOf: root.appendingPathComponent("../Brand/logo-mark-primary.png"))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
func line(_ s: String, _ size: CGFloat, _ w: NSFont.Weight, _ c: NSColor) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: w), .foregroundColor: c]))
}
for (name, tag, sub) in [("og.png", "相機裡的照片，一鍵帶到 Mac", "OM System · Olympus · Wi-Fi 與 USB-C · 免費"),
                         ("og-en.png", "Your camera’s photos, on your Mac", "OM System · Olympus · Wi-Fi and USB-C · Free")] {
    let ctx = CGContext(data: nil, width: 1200, height: 630, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let g = CGGradient(colorsSpace: nil, colors: [NSColor.white.cgColor, NSColor(white: 0.9, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 630), end: CGPoint(x: 0, y: 0), options: [])
    let mw: CGFloat = 470, mh = mw * CGFloat(mark.height) / CGFloat(mark.width)
    ctx.draw(mark, in: CGRect(x: 60, y: (630 - mh) / 2, width: mw, height: mh))
    ctx.textPosition = CGPoint(x: 580, y: 360); CTLineDraw(line("OM Photos", 92, .bold, .black), ctx)
    ctx.textPosition = CGPoint(x: 584, y: 285); CTLineDraw(line(tag, 38, .semibold, NSColor(white: 0.2, alpha: 1)), ctx)
    ctx.textPosition = CGPoint(x: 586, y: 230); CTLineDraw(line(sub, 24, .regular, NSColor(white: 0.4, alpha: 1)), ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("static/\(name)"))
}
print("og done")

// Original Youra vector geometry. Reproducible raster asset, no external imagery.
// Run: swift tools/render-youra-icon.swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func render(size: Int, background: Bool, destination: String) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Image context unavailable") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    let cg = context.cgContext; cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    if background { cg.setFillColor(NSColor(srgbRed: 0.075, green: 0.086, blue: 0.10, alpha: 1).cgColor); cg.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
    // A balanced, continuous branching mark: one stem, one clear junction,
    // and two measured paths. The cool node is the only brand accent.
    let ivory = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.93, alpha: 1)
    let ice = NSColor(srgbRed: 0.48, green: 0.78, blue: 0.96, alpha: 1)
    cg.setStrokeColor(ivory.cgColor); cg.setLineWidth(64); cg.setLineCap(.round); cg.setLineJoin(.round)
    cg.move(to: CGPoint(x: 512, y: 258)); cg.addLine(to: CGPoint(x: 512, y: 503)); cg.strokePath()
    cg.move(to: CGPoint(x: 512, y: 503)); cg.addLine(to: CGPoint(x: 344, y: 712)); cg.strokePath()
    cg.move(to: CGPoint(x: 512, y: 503)); cg.addLine(to: CGPoint(x: 680, y: 712)); cg.strokePath()
    cg.setFillColor(ice.cgColor); cg.fillEllipse(in: CGRect(x: 488, y: 479, width: 48, height: 48))
    let target = root.appendingPathComponent(destination)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG unavailable") }
    try png.write(to: target)
}
try render(size: 1024, background: true, destination: "apps/ios/OuraApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
try render(size: 512, background: false, destination: "apps/ios/OuraApp/Assets.xcassets/StrictlyHealthMark.imageset/strictlyhealth-mark.png")

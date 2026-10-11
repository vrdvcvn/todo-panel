#!/usr/bin/env swift
//
// Generates Resources/todo.icns.
//
// Kept as a script rather than a checked-in binary blob so the icon is
// reviewable, editable and reproducible. Run it directly:
//
//     swift Tools/make-icon.swift
//
// `build-app.sh` uses the committed .icns if present and otherwise regenerates
// it.
//
// Design: a dark squircle with a single green checkmark — the one shape that
// stays legible down to 16pt, where anything resembling a list turns to mush.

import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources")
let iconset = outputDirectory.appendingPathComponent("todo.iconset")

let background = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.067, alpha: 1)
let accent = NSColor(srgbRed: 0.30, green: 0.85, blue: 0.52, alpha: 1)
let border = NSColor(srgbRed: 0.20, green: 0.21, blue: 0.25, alpha: 1)

func drawIcon(size: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    rep.size = NSSize(width: size, height: size)

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let inset = size * 0.06
    let box = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = size * 0.2237 // matches the macOS squircle proportion

    let plate = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
    background.setFill()
    plate.fill()
    border.setStroke()
    plate.lineWidth = max(1, size * 0.012)
    plate.stroke()

    // Checkmark, in unit coordinates then scaled.
    let points = [
        NSPoint(x: 0.255, y: 0.520),
        NSPoint(x: 0.435, y: 0.305),
        NSPoint(x: 0.760, y: 0.690),
    ].map { NSPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) }

    let check = NSBezierPath()
    check.move(to: points[0])
    check.line(to: points[1])
    check.line(to: points[2])
    check.lineWidth = size * 0.098
    check.lineCapStyle = .round
    check.lineJoinStyle = .round

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = size * 0.06
    shadow.shadowColor = accent
    shadow.shadowOffset = .zero
    shadow.set()
    accent.setStroke()
    check.stroke()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let variants: [(name: String, pixels: Int, scale: Int)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 32, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 64, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 256, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 512, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 1024, 2),
]

do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    for variant in variants {
        guard let data = drawIcon(size: CGFloat(variant.pixels)) else {
            FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
            exit(1)
        }
        try data.write(to: iconset.appendingPathComponent(variant.name))
    }

    print("wrote \(variants.count) images to \(iconset.path)")
} catch {
    FileHandle.standardError.write(Data("icon generation failed: \(error)\n".utf8))
    exit(1)
}
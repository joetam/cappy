#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: render-dmg-background.swift <output.png>\n".utf8))
    exit(1)
}

let canvasSize = NSSize(width: 720, height: 480)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasSize.width),
        pixelsHigh: Int(canvasSize.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ),
    let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
else {
    FileHandle.standardError.write(Data("Could not create the DMG background bitmap.\n".utf8))
    exit(1)
}

func color(_ red: Int, _ green: Int, _ blue: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat(red) / 255,
        green: CGFloat(green) / 255,
        blue: CGFloat(blue) / 255,
        alpha: alpha
    )
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext

let background = NSGradient(
    starting: color(255, 255, 255),
    ending: color(246, 248, 246)
)!
background.draw(in: NSRect(origin: .zero, size: canvasSize), angle: -72)

// Finder places Cappy.app and the Applications alias on either side. A loose,
// slightly curved arrow is the only instruction the installer needs.
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 307, y: 231))
arrow.curve(
    to: NSPoint(x: 413, y: 233),
    controlPoint1: NSPoint(x: 337, y: 245),
    controlPoint2: NSPoint(x: 382, y: 218)
)
arrow.move(to: NSPoint(x: 396, y: 247))
arrow.curve(
    to: NSPoint(x: 413, y: 233),
    controlPoint1: NSPoint(x: 403, y: 243),
    controlPoint2: NSPoint(x: 408, y: 238)
)
arrow.curve(
    to: NSPoint(x: 394, y: 220),
    controlPoint1: NSPoint(x: 407, y: 228),
    controlPoint2: NSPoint(x: 401, y: 224)
)
arrow.lineWidth = 3.25
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
color(54, 75, 61, alpha: 0.78).setStroke()
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [.compressionFactor: 1]) else {
    FileHandle.standardError.write(Data("Could not render the DMG background.\n".utf8))
    exit(1)
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
print(outputURL.path)

#!/usr/bin/env swift

import AppKit
import AVFoundation
import CoreVideo
import Foundation

private let arguments = CommandLine.arguments
guard (4...5).contains(arguments.count) else {
    FileHandle.standardError.write(
        Data(
            "usage: render-launch-video.swift <preview.png> <wallpaper.png> <output.mp4> [stills-directory]\n"
                .utf8
        )
    )
    exit(2)
}

private func loadCGImage(at url: URL, description: String) -> CGImage {
    guard let image = NSImage(contentsOf: url),
        let data = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: data),
        let cgImage = bitmap.cgImage
    else {
        FileHandle.standardError.write(Data("could not read \(description)\n".utf8))
        exit(2)
    }
    return cgImage
}

let previewURL = URL(fileURLWithPath: arguments[1])
let wallpaperURL = URL(fileURLWithPath: arguments[2])
let outputURL = URL(fileURLWithPath: arguments[3])
let stillsURL = arguments.count == 5 ? URL(fileURLWithPath: arguments[4], isDirectory: true) : nil
let previewImage = loadCGImage(at: previewURL, description: "preview image")
let wallpaperImage = loadCGImage(at: wallpaperURL, description: "wallpaper image")

let frameWidth = 1_920
let frameHeight = 1_080
let framesPerSecond: Int32 = 30
let duration = 11.5
let frameCount = Int(duration * Double(framesPerSecond))

try? FileManager.default.removeItem(at: outputURL)
if let stillsURL {
    try? FileManager.default.removeItem(at: stillsURL)
    try FileManager.default.createDirectory(at: stillsURL, withIntermediateDirectories: true)
}

let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
let videoInput = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: frameWidth,
        AVVideoHeightKey: frameHeight,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 9_000_000,
            AVVideoExpectedSourceFrameRateKey: framesPerSecond,
            AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
    ]
)
videoInput.expectsMediaDataInRealTime = false

let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: videoInput,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: frameWidth,
        kCVPixelBufferHeightKey as String: frameHeight,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
)
guard writer.canAdd(videoInput) else { fatalError("could not add video input") }
writer.add(videoInput)
guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
writer.startSession(atSourceTime: .zero)

func clamp(_ value: Double, _ minimum: Double = 0, _ maximum: Double = 1) -> Double {
    min(max(value, minimum), maximum)
}

func phase(_ time: Double, start: Double, duration: Double) -> Double {
    clamp((time - start) / duration)
}

func smoothstep(_ value: Double) -> Double {
    let value = clamp(value)
    return value * value * (3 - 2 * value)
}

func smootherstep(_ value: Double) -> Double {
    let value = clamp(value)
    return value * value * value * (value * (value * 6 - 15) + 10)
}

func easeOutCubic(_ value: Double) -> Double {
    1 - pow(1 - clamp(value), 3)
}

func easeOutBack(_ value: Double) -> Double {
    let value = clamp(value)
    let c1 = 1.70158
    let c3 = c1 + 1
    return 1 + c3 * pow(value - 1, 3) + c1 * pow(value - 1, 2)
}

func interpolate(_ start: Double, _ end: Double, _ progress: Double) -> Double {
    start + (end - start) * progress
}

func interpolate(_ start: CGPoint, _ end: CGPoint, _ progress: Double) -> CGPoint {
    CGPoint(
        x: interpolate(start.x, end.x, progress),
        y: interpolate(start.y, end.y, progress)
    )
}

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func pixelBuffer() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        nil,
        frameWidth,
        frameHeight,
        kCVPixelFormatType_32BGRA,
        [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ] as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else { fatalError("could not allocate video frame") }
    return buffer
}

func drawText(
    _ text: String,
    at point: CGPoint,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor,
    context: CGContext,
    tracking: CGFloat = 0
) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    (text as NSString).draw(
        at: point,
        withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .kern: tracking,
        ]
    )
    NSGraphicsContext.restoreGraphicsState()
}

func drawAspectFill(_ image: CGImage, in rect: CGRect, context: CGContext) {
    let imageRatio = CGFloat(image.width) / CGFloat(image.height)
    let rectRatio = rect.width / rect.height
    let drawRect: CGRect
    if imageRatio > rectRatio {
        let width = rect.height * imageRatio
        drawRect = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
    } else {
        let height = rect.width / imageRatio
        drawRect = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }
    context.saveGState()
    context.clip(to: rect)
    context.interpolationQuality = .high
    context.draw(image, in: drawRect)
    context.restoreGState()
}

func cgImage(forApplication path: String) -> CGImage? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let icon = NSWorkspace.shared.icon(forFile: path)
    icon.size = NSSize(width: 128, height: 128)
    var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
    return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

let dockIcons: [CGImage] = [
    "/System/Library/CoreServices/Finder.app",
    "/Applications/Safari.app",
    "/System/Applications/Mail.app",
    "/System/Applications/Messages.app",
    "/System/Applications/Notes.app",
    "/System/Applications/Photos.app",
    "/System/Applications/Music.app",
    "/System/Applications/Utilities/Terminal.app",
    "/System/Applications/System Settings.app",
].compactMap(cgImage(forApplication:))

func drawDesktop(context: CGContext) {
    drawAspectFill(
        wallpaperImage,
        in: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight),
        context: context
    )

    // A restrained vignette keeps menu-bar details legible without flattening the wallpaper.
    let colors = [
        CGColor(red: 0.03, green: 0.04, blue: 0.07, alpha: 0),
        CGColor(red: 0.03, green: 0.04, blue: 0.07, alpha: 0.18),
    ] as CFArray
    if let vignette = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors,
        locations: [0.58, 1]
    ) {
        context.drawRadialGradient(
            vignette,
            startCenter: CGPoint(x: 1_050, y: 600),
            startRadius: 250,
            endCenter: CGPoint(x: 960, y: 540),
            endRadius: 1_180,
            options: [.drawsAfterEndLocation]
        )
    }
}

let menuBarHeight = 42.0
let menuBarBottom = Double(frameHeight) - menuBarHeight
let cappyCenter = CGPoint(x: 1_372, y: 1_059)

func drawCappyGauge(at center: CGPoint, color: CGColor, context: CGContext) {
    context.saveGState()
    context.setStrokeColor(color)
    context.setFillColor(color)
    context.setLineCap(.round)
    context.setLineWidth(2.1)
    context.addArc(center: center, radius: 9.2, startAngle: .pi * 0.04, endAngle: .pi * 0.96, clockwise: false)
    context.strokePath()
    context.move(to: CGPoint(x: center.x, y: center.y))
    context.addLine(to: CGPoint(x: center.x + 5.8, y: center.y + 4.2))
    context.strokePath()
    for angle in [0.20, 0.50, 0.80] {
        let radians = Double.pi * angle
        let point = CGPoint(x: center.x + cos(radians) * 7.6, y: center.y + sin(radians) * 7.6)
        context.fillEllipse(in: CGRect(x: point.x - 1.1, y: point.y - 1.1, width: 2.2, height: 2.2))
    }
    context.restoreGState()
}

func drawWiFi(at center: CGPoint, context: CGContext) {
    context.saveGState()
    context.setStrokeColor(CGColor(gray: 0.08, alpha: 0.92))
    context.setFillColor(CGColor(gray: 0.08, alpha: 0.92))
    context.setLineCap(.round)
    for (radius, width) in [(10.0, 1.7), (6.3, 1.8)] {
        context.setLineWidth(width)
        context.addArc(center: center, radius: radius, startAngle: .pi * 0.21, endAngle: .pi * 0.79, clockwise: false)
        context.strokePath()
    }
    context.fillEllipse(in: CGRect(x: center.x - 1.6, y: center.y - 5.2, width: 3.2, height: 3.2))
    context.restoreGState()
}

func drawControlCenter(at center: CGPoint, context: CGContext) {
    context.saveGState()
    context.setStrokeColor(CGColor(gray: 0.08, alpha: 0.92))
    context.setLineWidth(2)
    context.setLineCap(.round)
    for offset in [-4.0, 4.0] {
        context.move(to: CGPoint(x: center.x - 9, y: center.y + offset))
        context.addLine(to: CGPoint(x: center.x + 9, y: center.y + offset))
        context.strokePath()
    }
    context.setFillColor(CGColor(gray: 0.08, alpha: 1))
    context.fillEllipse(in: CGRect(x: center.x - 5.5, y: center.y + 1.5, width: 5, height: 5))
    context.fillEllipse(in: CGRect(x: center.x + 0.5, y: center.y - 6.5, width: 5, height: 5))
    context.restoreGState()
}

func drawBattery(at center: CGPoint, context: CGContext) {
    context.saveGState()
    let shell = CGRect(x: center.x - 12, y: center.y - 6.2, width: 22, height: 12.4)
    context.addPath(roundedPath(shell, radius: 3))
    context.setStrokeColor(CGColor(gray: 0.08, alpha: 0.85))
    context.setLineWidth(1.3)
    context.strokePath()
    context.addPath(roundedPath(shell.insetBy(dx: 2.4, dy: 2.4), radius: 1.4))
    context.setFillColor(CGColor(gray: 0.08, alpha: 0.9))
    context.fillPath()
    context.fill(CGRect(x: shell.maxX + 1.4, y: center.y - 2.2, width: 2, height: 4.4))
    context.restoreGState()
}

func drawMenuBar(hoverProgress: Double, clickProgress: Double, context: CGContext) {
    let rect = CGRect(x: -1_000, y: menuBarBottom, width: 4_000, height: menuBarHeight)
    context.saveGState()
    context.setFillColor(CGColor(red: 0.97, green: 0.955, blue: 0.945, alpha: 0.78))
    context.fill(rect)
    context.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
    context.setLineWidth(0.7)
    context.move(to: CGPoint(x: rect.minX, y: rect.minY))
    context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    context.strokePath()

    drawText("", at: CGPoint(x: 22, y: 1_045), size: 21, weight: .medium, color: .black, context: context)
    drawText("Finder", at: CGPoint(x: 58, y: 1_048), size: 15.5, weight: .semibold, color: .black, context: context)
    drawText("File", at: CGPoint(x: 124, y: 1_048), size: 15.5, color: .black, context: context)
    drawText("Edit", at: CGPoint(x: 163, y: 1_048), size: 15.5, color: .black, context: context)
    drawText("View", at: CGPoint(x: 205, y: 1_048), size: 15.5, color: .black, context: context)
    drawText("Go", at: CGPoint(x: 252, y: 1_048), size: 15.5, color: .black, context: context)
    drawText("Window", at: CGPoint(x: 286, y: 1_048), size: 15.5, color: .black, context: context)
    drawText("Help", at: CGPoint(x: 354, y: 1_048), size: 15.5, color: .black, context: context)

    if hoverProgress > 0 {
        let hoverRect = CGRect(x: cappyCenter.x - 20, y: menuBarBottom + 3, width: 40, height: menuBarHeight - 6)
        context.addPath(roundedPath(hoverRect, radius: 9))
        context.setFillColor(CGColor(gray: 0, alpha: 0.08 * hoverProgress + 0.06 * clickProgress))
        context.fillPath()
    }
    drawCappyGauge(at: cappyCenter, color: CGColor(gray: 0.06, alpha: 0.94), context: context)

    context.setStrokeColor(CGColor(gray: 0.08, alpha: 0.9))
    context.setLineWidth(1.8)
    context.strokeEllipse(in: CGRect(x: 1_412, y: 1_052, width: 12, height: 12))
    context.move(to: CGPoint(x: 1_423, y: 1_051))
    context.addLine(to: CGPoint(x: 1_428, y: 1_046))
    context.strokePath()
    drawControlCenter(at: CGPoint(x: 1_456, y: 1_059), context: context)
    drawWiFi(at: CGPoint(x: 1_498, y: 1_060), context: context)
    drawBattery(at: CGPoint(x: 1_537, y: 1_059), context: context)
    drawText("Thu Aug 6", at: CGPoint(x: 1_570, y: 1_048), size: 14.5, weight: .medium, color: .black, context: context)
    drawText("9:41 AM", at: CGPoint(x: 1_652, y: 1_048), size: 14.5, weight: .medium, color: .black, context: context)
    context.restoreGState()
}

func drawDock(context: CGContext) {
    let iconSize = 64.0
    let spacing = 10.0
    let horizontalPadding = 14.0
    let dockWidth = horizontalPadding * 2 + Double(dockIcons.count) * iconSize + Double(max(0, dockIcons.count - 1)) * spacing
    let dockRect = CGRect(x: (Double(frameWidth) - dockWidth) / 2, y: 18, width: dockWidth, height: 84)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: CGColor(gray: 0, alpha: 0.22))
    context.addPath(roundedPath(dockRect, radius: 22))
    context.setFillColor(CGColor(red: 0.965, green: 0.955, blue: 0.95, alpha: 0.61))
    context.fillPath()
    context.restoreGState()
    context.addPath(roundedPath(dockRect, radius: 22))
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
    context.setLineWidth(1)
    context.strokePath()

    var x = dockRect.minX + horizontalPadding
    for (index, icon) in dockIcons.enumerated() {
        let iconRect = CGRect(x: x, y: dockRect.minY + 11, width: iconSize, height: iconSize)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 5, color: CGColor(gray: 0, alpha: 0.18))
        context.interpolationQuality = .high
        context.draw(icon, in: iconRect)
        context.restoreGState()
        if index == 0 {
            context.setFillColor(CGColor(gray: 0.1, alpha: 0.72))
            context.fillEllipse(in: CGRect(x: iconRect.midX - 2, y: dockRect.minY + 4, width: 4, height: 4))
        }
        x += iconSize + spacing
    }
}

let popoverX = 742.0
let popoverBottom = 145.0
let popoverWidth = 620.0
let popoverHeight = 875.0
let popoverRect = CGRect(x: popoverX, y: popoverBottom, width: popoverWidth, height: popoverHeight)

func drawPopover(
    openProgress: Double,
    scrollProgress: Double,
    scrollIndicatorOpacity: Double,
    context: CGContext
) {
    guard openProgress > 0 else { return }
    let spring = easeOutBack(openProgress)
    let openingScale = interpolate(0.955, 1, spring)
    let anchor = CGPoint(x: cappyCenter.x, y: popoverRect.maxY)

    context.saveGState()
    context.setAlpha(clamp(openProgress * 1.35))
    context.translateBy(x: anchor.x, y: anchor.y)
    context.scaleBy(x: openingScale, y: openingScale)
    context.translateBy(x: -anchor.x, y: -anchor.y)

    let windowPath = roundedPath(popoverRect, radius: 24)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 42, color: CGColor(gray: 0, alpha: 0.3))
    context.addPath(windowPath)
    context.setFillColor(CGColor(red: 0.935, green: 0.925, blue: 0.925, alpha: 0.99))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(windowPath)
    context.clip()

    let fullImageHeight = popoverWidth * Double(previewImage.height) / Double(previewImage.width)
    let headerHeight = popoverWidth * 130 / Double(previewImage.width)
    let footerHeight = popoverWidth * 82 / Double(previewImage.width)
    let contentRect = CGRect(
        x: popoverX,
        y: popoverBottom + footerHeight,
        width: popoverWidth,
        height: popoverHeight - headerHeight - footerHeight
    )
    let maximumScroll = max(0, fullImageHeight - popoverHeight)
    let scrollOffset = maximumScroll * scrollProgress

    context.saveGState()
    context.clip(to: contentRect)
    context.interpolationQuality = .high
    context.draw(
        previewImage,
        in: CGRect(
            x: popoverX,
            y: popoverBottom + popoverHeight - fullImageHeight + scrollOffset,
            width: popoverWidth,
            height: fullImageHeight
        )
    )
    context.restoreGState()

    let headerRect = CGRect(
        x: popoverX,
        y: popoverBottom + popoverHeight - headerHeight,
        width: popoverWidth,
        height: headerHeight
    )
    context.saveGState()
    context.clip(to: headerRect)
    context.draw(
        previewImage,
        in: CGRect(
            x: popoverX,
            y: popoverBottom + popoverHeight - fullImageHeight,
            width: popoverWidth,
            height: fullImageHeight
        )
    )
    context.restoreGState()

    let footerRect = CGRect(x: popoverX, y: popoverBottom, width: popoverWidth, height: footerHeight)
    context.saveGState()
    context.clip(to: footerRect)
    context.draw(
        previewImage,
        in: CGRect(x: popoverX, y: popoverBottom, width: popoverWidth, height: fullImageHeight)
    )
    context.restoreGState()

    if scrollIndicatorOpacity > 0 {
        let trackHeight = contentRect.height - 28
        let thumbHeight = max(62, trackHeight * popoverHeight / fullImageHeight)
        let travel = trackHeight - thumbHeight
        let thumbRect = CGRect(
            x: contentRect.maxX - 8,
            y: contentRect.maxY - 14 - thumbHeight - travel * scrollProgress,
            width: 4,
            height: thumbHeight
        )
        context.addPath(roundedPath(thumbRect, radius: 2))
        context.setFillColor(CGColor(gray: 0.22, alpha: 0.33 * scrollIndicatorOpacity))
        context.fillPath()
    }

    context.restoreGState()
    context.addPath(windowPath)
    context.setStrokeColor(CGColor(gray: 0, alpha: 0.16))
    context.setLineWidth(0.9)
    context.strokePath()
    context.restoreGState()
}

func drawCursor(at point: CGPoint, opacity: Double, pressed: Double, context: CGContext) {
    guard opacity > 0 else { return }
    let path = CGMutablePath()
    path.move(to: point)
    path.addLine(to: CGPoint(x: point.x + 3, y: point.y - 28))
    path.addLine(to: CGPoint(x: point.x + 10, y: point.y - 21))
    path.addLine(to: CGPoint(x: point.x + 17, y: point.y - 33))
    path.addLine(to: CGPoint(x: point.x + 22, y: point.y - 30))
    path.addLine(to: CGPoint(x: point.x + 15, y: point.y - 18))
    path.addLine(to: CGPoint(x: point.x + 25, y: point.y - 18))
    path.closeSubpath()

    context.saveGState()
    context.setAlpha(opacity)
    context.translateBy(x: point.x, y: point.y)
    let scale = interpolate(1, 0.91, pressed)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -point.x, y: -point.y)
    context.setShadow(offset: CGSize(width: 1.5, height: -2), blur: 3, color: CGColor(gray: 0, alpha: 0.3))
    context.addPath(path)
    context.setFillColor(CGColor(gray: 0.055, alpha: 1))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0)
    context.addPath(path)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.96))
    context.setLineWidth(1.35)
    context.strokePath()
    context.restoreGState()
}

func drawLaunchTitle(opacity: Double, context: CGContext) {
    guard opacity > 0 else { return }
    let card = CGRect(x: 72, y: 148, width: 500, height: 166)
    context.saveGState()
    context.setAlpha(opacity)
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: CGColor(gray: 0, alpha: 0.15))
    context.addPath(roundedPath(card, radius: 28))
    context.setFillColor(CGColor(red: 0.96, green: 0.94, blue: 0.93, alpha: 0.73))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0)
    context.addPath(roundedPath(card, radius: 28))
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.44))
    context.setLineWidth(1)
    context.strokePath()
    drawText("CAPPY  ·  FOR macOS", at: CGPoint(x: 106, y: 267), size: 14, weight: .semibold, color: NSColor(white: 0.2, alpha: 0.68), context: context, tracking: 1.4)
    drawText("Know your limits.", at: CGPoint(x: 104, y: 205), size: 43, weight: .bold, color: NSColor(white: 0.08, alpha: 0.94), context: context, tracking: -0.7)
    drawText("Across every coding account.", at: CGPoint(x: 106, y: 170), size: 22, weight: .medium, color: NSColor(white: 0.18, alpha: 0.68), context: context)
    context.restoreGState()
}

func writeStill(context: CGContext, name: String, directory: URL) throws {
    guard let image = context.makeImage() else { return }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
}

let stillMoments: [(time: Double, name: String)] = [
    (0.55, "01-desktop.png"),
    (1.45, "02-camera-move.png"),
    (2.35, "03-menu-bar-zoom.png"),
    (2.65, "04-click.png"),
    (3.05, "05-opening.png"),
    (3.75, "06-app-open.png"),
    (5.40, "07-scroll-start.png"),
    (6.85, "08-account-scroll.png"),
    (8.80, "09-scroll-end.png"),
    (10.45, "10-final.png"),
]
var writtenStills = Set<String>()

for frame in 0..<frameCount {
    while !videoInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    let time = Double(frame) / Double(framesPerSecond)
    let buffer = pixelBuffer()
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: frameWidth,
        height: frameHeight,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        fatalError("could not create video frame context")
    }

    context.setFillColor(CGColor(red: 0.92, green: 0.89, blue: 0.88, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))

    let sceneCenter = CGPoint(x: Double(frameWidth) / 2, y: Double(frameHeight) / 2)
    let menuZoom = smootherstep(phase(time, start: 0.95, duration: 1.42))
    var cameraScale = interpolate(1, 3.35, menuZoom)
    let menuScreenPosition = CGPoint(
        x: interpolate(cappyCenter.x, Double(frameWidth) / 2, menuZoom),
        y: interpolate(cappyCenter.y, 1_002, menuZoom)
    )
    var cameraCenter = CGPoint(
        x: cappyCenter.x - (menuScreenPosition.x - sceneCenter.x) / cameraScale,
        y: cappyCenter.y - (menuScreenPosition.y - sceneCenter.y) / cameraScale
    )

    let appReveal = easeOutCubic(phase(time, start: 2.52, duration: 1.3))
    cameraScale = interpolate(cameraScale, 1.08, appReveal)
    cameraCenter = interpolate(cameraCenter, CGPoint(x: 1_050, y: 575), appReveal)

    let inspectAccounts = smootherstep(phase(time, start: 4.55, duration: 0.9))
    cameraScale = interpolate(cameraScale, 1.28, inspectAccounts)
    cameraCenter = interpolate(cameraCenter, CGPoint(x: 1_052, y: 595), inspectAccounts)

    let finalSettle = smootherstep(phase(time, start: 9.18, duration: 0.9))
    cameraScale = interpolate(cameraScale, 1.12, finalSettle)
    cameraCenter = interpolate(cameraCenter, CGPoint(x: 1_052, y: 565), finalSettle)

    context.saveGState()
    context.translateBy(x: Double(frameWidth) / 2, y: Double(frameHeight) / 2)
    context.scaleBy(x: cameraScale, y: cameraScale)
    context.translateBy(x: -cameraCenter.x, y: -cameraCenter.y)

    drawDesktop(context: context)
    drawDock(context: context)

    let cursorArrival = smootherstep(phase(time, start: 0.55, duration: 1.78))
    let hoverProgress = smoothstep(phase(time, start: 2.08, duration: 0.22))
    let pressIn = easeOutCubic(phase(time, start: 2.36, duration: 0.1))
    let pressOut = smoothstep(phase(time, start: 2.46, duration: 0.16))
    let pressed = pressIn * (1 - pressOut)
    drawMenuBar(hoverProgress: hoverProgress, clickProgress: pressed, context: context)

    if time >= 2.39 && time <= 2.9 {
        let ripple = easeOutCubic(phase(time, start: 2.39, duration: 0.51))
        context.setStrokeColor(CGColor(gray: 0.05, alpha: 0.36 * (1 - ripple)))
        context.setLineWidth(1.6)
        context.strokeEllipse(
            in: CGRect(
                x: cappyCenter.x - 12 - 20 * ripple,
                y: cappyCenter.y - 12 - 20 * ripple,
                width: 24 + 40 * ripple,
                height: 24 + 40 * ripple
            )
        )
    }

    let openProgress = phase(time, start: 2.48, duration: 0.58)
    let scrollProgress = smootherstep(phase(time, start: 5.18, duration: 3.55))
    let scrollVisibleIn = smoothstep(phase(time, start: 4.96, duration: 0.25))
    let scrollVisibleOut = smoothstep(phase(time, start: 8.9, duration: 0.48))
    drawPopover(
        openProgress: openProgress,
        scrollProgress: scrollProgress,
        scrollIndicatorOpacity: scrollVisibleIn * (1 - scrollVisibleOut),
        context: context
    )

    let cursorStart = CGPoint(x: 810, y: 520)
    let cursorAtMenu = CGPoint(x: cappyCenter.x - 2, y: cappyCenter.y + 8)
    let cursorInPanel = CGPoint(x: 1_264, y: 675)
    var cursorPoint = interpolate(cursorStart, cursorAtMenu, cursorArrival)
    let cursorToPanel = smootherstep(phase(time, start: 3.18, duration: 1.25))
    cursorPoint = interpolate(cursorPoint, cursorInPanel, cursorToPanel)
    let scrollGesture = smootherstep(phase(time, start: 5.18, duration: 3.55))
    cursorPoint.y -= 34 * sin(scrollGesture * .pi)
    let cursorOpacity = 1 - smoothstep(phase(time, start: 9.05, duration: 0.55))
    drawCursor(at: cursorPoint, opacity: cursorOpacity, pressed: pressed, context: context)
    context.restoreGState()

    let titleOpacity = smoothstep(phase(time, start: 0.08, duration: 0.36))
        * (1 - smoothstep(phase(time, start: 0.82, duration: 0.58)))
    drawLaunchTitle(opacity: titleOpacity, context: context)

    if let stillsURL {
        for moment in stillMoments where !writtenStills.contains(moment.name) {
            if abs(time - moment.time) <= 0.5 / Double(framesPerSecond) {
                try writeStill(context: context, name: moment.name, directory: stillsURL)
                writtenStills.insert(moment.name)
            }
        }
    }

    let presentationTime = CMTime(value: Int64(frame), timescale: framesPerSecond)
    guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
    }
}

videoInput.markAsFinished()
await writer.finishWriting()
guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
print(outputURL.path)

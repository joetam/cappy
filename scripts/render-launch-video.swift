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
let duration = 9.5
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

func drawSymbol(
    _ name: String,
    at center: CGPoint,
    pointSize: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = NSColor(white: 0.08, alpha: 0.92),
    context: CGContext
) {
    guard let baseImage = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
    let sizeConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    let colorConfiguration = NSImage.SymbolConfiguration(paletteColors: [color])
    let image = baseImage.withSymbolConfiguration(sizeConfiguration.applying(colorConfiguration)) ?? baseImage
    let imageSize = image.size
    let rect = CGRect(
        x: center.x - imageSize.width / 2,
        y: center.y - imageSize.height / 2,
        width: imageSize.width,
        height: imageSize.height
    )
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
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
    let colors =
        [
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

func drawMenuBar(
    hoverProgress: Double,
    clickProgress: Double,
    leftMenuOpacity: Double,
    context: CGContext
) {
    let rect = CGRect(x: -1_000, y: menuBarBottom, width: 4_000, height: menuBarHeight)
    context.saveGState()
    context.setFillColor(CGColor(red: 0.97, green: 0.955, blue: 0.945, alpha: 0.78))
    context.fill(rect)
    context.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
    context.setLineWidth(0.7)
    context.move(to: CGPoint(x: rect.minX, y: rect.minY))
    context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    context.strokePath()

    let leftMenuColor = NSColor.black.withAlphaComponent(leftMenuOpacity)
    drawText(
        "", at: CGPoint(x: 22, y: 1_045), size: 21, weight: .medium, color: leftMenuColor,
        context: context)
    drawText(
        "Finder", at: CGPoint(x: 58, y: 1_048), size: 15.5, weight: .semibold,
        color: leftMenuColor, context: context)
    drawText("File", at: CGPoint(x: 124, y: 1_048), size: 15.5, color: leftMenuColor, context: context)
    drawText("Edit", at: CGPoint(x: 163, y: 1_048), size: 15.5, color: leftMenuColor, context: context)
    drawText("View", at: CGPoint(x: 205, y: 1_048), size: 15.5, color: leftMenuColor, context: context)
    drawText("Go", at: CGPoint(x: 252, y: 1_048), size: 15.5, color: leftMenuColor, context: context)
    drawText("Window", at: CGPoint(x: 286, y: 1_048), size: 15.5, color: leftMenuColor, context: context)
    drawText("Help", at: CGPoint(x: 354, y: 1_048), size: 15.5, color: leftMenuColor, context: context)

    if hoverProgress > 0 {
        let hoverRect = CGRect(x: cappyCenter.x - 17, y: menuBarBottom + 4, width: 34, height: menuBarHeight - 8)
        context.addPath(roundedPath(hoverRect, radius: 9))
        context.setFillColor(CGColor(gray: 0, alpha: 0.08 * hoverProgress + 0.06 * clickProgress))
        context.fillPath()
    }
    drawSymbol(
        "gauge.with.dots.needle.50percent", at: cappyCenter, pointSize: 18, weight: .medium, context: context)
    drawSymbol("magnifyingglass", at: CGPoint(x: 1_415, y: 1_059), pointSize: 17, weight: .medium, context: context)
    drawSymbol("switch.2", at: CGPoint(x: 1_456, y: 1_059), pointSize: 18, weight: .medium, context: context)
    drawSymbol("wifi", at: CGPoint(x: 1_498, y: 1_059), pointSize: 17, weight: .medium, context: context)
    drawSymbol("battery.100percent", at: CGPoint(x: 1_540, y: 1_059), pointSize: 19, context: context)
    drawText("Fri Aug 7", at: CGPoint(x: 1_570, y: 1_048), size: 14.2, weight: .medium, color: .black, context: context)
    drawText("9:41 AM", at: CGPoint(x: 1_652, y: 1_048), size: 14.2, weight: .medium, color: .black, context: context)
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

let popoverX = 1_062.0
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
    let opening = easeOutCubic(openProgress)
    let openingScale = interpolate(0.985, 1, opening)
    let anchor = CGPoint(x: cappyCenter.x, y: popoverRect.maxY)

    context.saveGState()
    context.setAlpha(clamp(openProgress * 1.35))
    context.translateBy(x: anchor.x, y: anchor.y)
    context.scaleBy(x: openingScale, y: openingScale)
    context.translateBy(x: -anchor.x, y: -anchor.y)

    let windowPath = CGMutablePath()
    windowPath.addPath(roundedPath(popoverRect, radius: 24))
    windowPath.move(to: CGPoint(x: cappyCenter.x - 13, y: popoverRect.maxY - 1))
    windowPath.addLine(to: CGPoint(x: cappyCenter.x, y: menuBarBottom + 1))
    windowPath.addLine(to: CGPoint(x: cappyCenter.x + 13, y: popoverRect.maxY - 1))
    windowPath.closeSubpath()
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
    let footerHeight = popoverWidth * 76 / Double(previewImage.width)
    let contentRect = CGRect(
        x: popoverX,
        y: popoverBottom + footerHeight,
        width: popoverWidth,
        height: popoverHeight - footerHeight
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

func writeStill(context: CGContext, name: String, directory: URL) throws {
    guard let image = context.makeImage() else { return }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
}

let stillMoments: [(time: Double, name: String)] = [
    (0.30, "01-desktop.png"),
    (0.85, "02-camera-move.png"),
    (1.48, "03-menu-bar-zoom.png"),
    (1.78, "04-click.png"),
    (2.10, "05-opening.png"),
    (2.75, "06-app-open.png"),
    (3.85, "07-scroll-start.png"),
    (5.15, "08-account-scroll.png"),
    (6.65, "09-scroll-end.png"),
    (8.70, "10-final.png"),
]
var writtenStills = Set<String>()

for frame in 0..<frameCount {
    while !videoInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    let time = Double(frame) / Double(framesPerSecond)
    let buffer = pixelBuffer()
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: frameWidth,
            height: frameHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    else {
        fatalError("could not create video frame context")
    }

    context.setFillColor(CGColor(red: 0.92, green: 0.89, blue: 0.88, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))

    let sceneCenter = CGPoint(x: Double(frameWidth) / 2, y: Double(frameHeight) / 2)
    let menuZoom = smootherstep(phase(time, start: 0.42, duration: 1.05))
    var cameraScale = interpolate(1, 1.85, menuZoom)
    let menuScreenPosition = CGPoint(
        x: interpolate(cappyCenter.x, Double(frameWidth) / 2, menuZoom),
        y: interpolate(cappyCenter.y, 1_006, menuZoom)
    )
    var cameraCenter = CGPoint(
        x: cappyCenter.x - (menuScreenPosition.x - sceneCenter.x) / cameraScale,
        y: cappyCenter.y - (menuScreenPosition.y - sceneCenter.y) / cameraScale
    )

    let appReveal = easeOutCubic(phase(time, start: 1.82, duration: 0.78))
    cameraScale = interpolate(cameraScale, 1, appReveal)
    cameraCenter = interpolate(cameraCenter, sceneCenter, appReveal)

    context.saveGState()
    context.translateBy(x: Double(frameWidth) / 2, y: Double(frameHeight) / 2)
    context.scaleBy(x: cameraScale, y: cameraScale)
    context.translateBy(x: -cameraCenter.x, y: -cameraCenter.y)

    drawDesktop(context: context)
    drawDock(context: context)

    let cursorArrival = smootherstep(phase(time, start: 0.28, duration: 1.28))
    let hoverProgress = smoothstep(phase(time, start: 1.42, duration: 0.18))
    let pressIn = easeOutCubic(phase(time, start: 1.68, duration: 0.08))
    let pressOut = smoothstep(phase(time, start: 1.78, duration: 0.12))
    let pressed = pressIn * (1 - pressOut)
    let hideLeftMenu = smoothstep(phase(time, start: 0.32, duration: 0.28))
    let restoreLeftMenu = smoothstep(phase(time, start: 2.42, duration: 0.22))
    let leftMenuOpacity = 1 - hideLeftMenu * (1 - restoreLeftMenu)
    drawMenuBar(
        hoverProgress: hoverProgress,
        clickProgress: pressed,
        leftMenuOpacity: leftMenuOpacity,
        context: context
    )

    let openProgress = phase(time, start: 1.80, duration: 0.46)
    let scrollProgress = smootherstep(phase(time, start: 3.72, duration: 2.82))
    let scrollVisibleIn = smoothstep(phase(time, start: 3.50, duration: 0.22))
    let scrollVisibleOut = smoothstep(phase(time, start: 6.70, duration: 0.38))
    drawPopover(
        openProgress: openProgress,
        scrollProgress: scrollProgress,
        scrollIndicatorOpacity: scrollVisibleIn * (1 - scrollVisibleOut),
        context: context
    )

    let cursorStart = CGPoint(x: 850, y: 520)
    let cursorAtMenu = CGPoint(x: cappyCenter.x - 2, y: cappyCenter.y + 8)
    let cursorInPanel = CGPoint(x: 1_560, y: 680)
    var cursorPoint = interpolate(cursorStart, cursorAtMenu, cursorArrival)
    let cursorToPanel = smootherstep(phase(time, start: 2.45, duration: 0.85))
    cursorPoint = interpolate(cursorPoint, cursorInPanel, cursorToPanel)
    let scrollGesture = smootherstep(phase(time, start: 3.72, duration: 2.82))
    cursorPoint.y -= 26 * sin(scrollGesture * .pi)
    let cursorOpacity = 1 - smoothstep(phase(time, start: 7.25, duration: 0.45))
    drawCursor(at: cursorPoint, opacity: cursorOpacity, pressed: pressed, context: context)
    context.restoreGState()

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

#!/usr/bin/env swift

import AppKit
import AVFoundation
import CoreVideo
import Foundation

private let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: render-launch-video.swift <preview.png> <output.mp4>\n".utf8))
    exit(2)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
guard let sourceImage = NSImage(contentsOf: sourceURL),
    let sourceData = sourceImage.tiffRepresentation,
    let sourceBitmap = NSBitmapImageRep(data: sourceData),
    let sourceCGImage = sourceBitmap.cgImage
else {
    FileHandle.standardError.write(Data("could not read preview image\n".utf8))
    exit(2)
}

let frameWidth = 1280
let frameHeight = 720
let framesPerSecond: Int32 = 30
let duration = 8.0
let frameCount = Int(duration * Double(framesPerSecond))

try? FileManager.default.removeItem(at: outputURL)
let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
let videoInput = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: frameWidth,
        AVVideoHeightKey: frameHeight,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 3_200_000,
            AVVideoMaxKeyFrameIntervalKey: 60,
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
    ]
)
guard writer.canAdd(videoInput) else { fatalError("could not add video input") }
writer.add(videoInput)
guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
writer.startSession(atSourceTime: .zero)

func smoothstep(_ value: Double) -> Double {
    let clamped = min(max(value, 0), 1)
    return clamped * clamped * (3 - 2 * clamped)
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
    context: CGContext
) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    (text as NSString).draw(
        at: point,
        withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
    )
    NSGraphicsContext.restoreGraphicsState()
}

func drawDesktop(context: CGContext) {
    let colors =
        [
            CGColor(red: 0.78, green: 0.84, blue: 0.91, alpha: 1),
            CGColor(red: 0.48, green: 0.59, blue: 0.72, alpha: 1),
        ] as CFArray
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else {
        return
    }
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: frameHeight),
        end: CGPoint(x: frameWidth, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.11))
    context.fillEllipse(in: CGRect(x: -250, y: -210, width: 960, height: 680))
    context.setFillColor(CGColor(red: 0.18, green: 0.29, blue: 0.43, alpha: 0.08))
    context.fillEllipse(in: CGRect(x: 720, y: 220, width: 920, height: 700))
}

let menuBarHeight = 30.0
let cappyCenter = CGPoint(x: 1112, y: 705)

func drawGauge(at center: CGPoint, context: CGContext) {
    context.saveGState()
    context.setStrokeColor(CGColor(gray: 0.12, alpha: 1))
    context.setLineWidth(1.7)
    context.addArc(center: center, radius: 7, startAngle: 0, endAngle: .pi, clockwise: false)
    context.strokePath()
    context.move(to: CGPoint(x: center.x, y: center.y))
    context.addLine(to: CGPoint(x: center.x + 4.5, y: center.y + 3.5))
    context.strokePath()
    context.setFillColor(CGColor(gray: 0.12, alpha: 1))
    for offset in [-5.5, 0, 5.5] {
        context.fillEllipse(in: CGRect(x: center.x + offset - 1, y: center.y - 5.2, width: 2, height: 2))
    }
    context.restoreGState()
}

func drawMenuBar(clickProgress: Double, context: CGContext) {
    let bar = CGRect(x: -800, y: Double(frameHeight) - menuBarHeight, width: 2880, height: menuBarHeight)
    context.setFillColor(CGColor(red: 0.98, green: 0.985, blue: 0.99, alpha: 0.88))
    context.fill(bar)
    context.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
    context.setLineWidth(0.5)
    context.move(to: CGPoint(x: bar.minX, y: bar.minY))
    context.addLine(to: CGPoint(x: bar.maxX, y: bar.minY))
    context.strokePath()

    drawText("", at: CGPoint(x: 17, y: 696), size: 16, weight: .medium, context: context)
    drawText("Finder", at: CGPoint(x: 44, y: 698), size: 12, weight: .semibold, context: context)

    if clickProgress > 0 {
        let pill = CGPath(
            roundedRect: CGRect(x: 1094, y: 692, width: 36, height: 27),
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )
        context.addPath(pill)
        context.setFillColor(CGColor(gray: 0, alpha: 0.08 * clickProgress))
        context.fillPath()
    }
    drawGauge(at: cappyCenter, context: context)

    context.setStrokeColor(CGColor(gray: 0.15, alpha: 0.9))
    context.setLineWidth(1.4)
    context.addArc(center: CGPoint(x: 1151, y: 704), radius: 6, startAngle: 0.18 * .pi, endAngle: 0.82 * .pi, clockwise: false)
    context.strokePath()
    context.fill(CGRect(x: 1171, y: 700, width: 14, height: 8))
    drawText("9:41", at: CGPoint(x: 1201, y: 698), size: 12, weight: .medium, context: context)
}

let popoverX = 790.0
let popoverBottom = 70.0
let popoverWidth = 390.0
let popoverHeight = 610.0

func drawPopover(openProgress: Double, scrollProgress: Double, context: CGContext) {
    guard openProgress > 0 else { return }
    let openingScale = interpolate(0.94, 1, openProgress)
    let anchor = CGPoint(x: popoverX + popoverWidth - 25, y: popoverBottom + popoverHeight)
    context.saveGState()
    context.setAlpha(openProgress)
    context.translateBy(x: anchor.x, y: anchor.y)
    context.scaleBy(x: openingScale, y: openingScale)
    context.translateBy(x: -anchor.x, y: -anchor.y)

    let windowRect = CGRect(x: popoverX, y: popoverBottom, width: popoverWidth, height: popoverHeight)
    let windowPath = CGPath(roundedRect: windowRect, cornerWidth: 17, cornerHeight: 17, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -13), blur: 28, color: CGColor(gray: 0, alpha: 0.24))
    context.addPath(windowPath)
    context.setFillColor(CGColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(windowPath)
    context.clip()

    let fullImageHeight = popoverWidth * Double(sourceCGImage.height) / Double(sourceCGImage.width)
    let headerHeight = 65.0
    let footerHeight = 61.0
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
    context.draw(
        sourceCGImage,
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
        sourceCGImage,
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
        sourceCGImage,
        in: CGRect(x: popoverX, y: popoverBottom, width: popoverWidth, height: fullImageHeight)
    )
    context.restoreGState()
    context.restoreGState()

    context.addPath(windowPath)
    context.setStrokeColor(CGColor(gray: 0, alpha: 0.14))
    context.setLineWidth(0.7)
    context.strokePath()
    context.restoreGState()
}

func drawCursor(at point: CGPoint, opacity: Double, context: CGContext) {
    guard opacity > 0 else { return }
    let path = CGMutablePath()
    path.move(to: point)
    path.addLine(to: CGPoint(x: point.x + 2, y: point.y - 20))
    path.addLine(to: CGPoint(x: point.x + 7, y: point.y - 15))
    path.addLine(to: CGPoint(x: point.x + 12, y: point.y - 24))
    path.addLine(to: CGPoint(x: point.x + 16, y: point.y - 22))
    path.addLine(to: CGPoint(x: point.x + 11, y: point.y - 13))
    path.addLine(to: CGPoint(x: point.x + 18, y: point.y - 13))
    path.closeSubpath()

    context.saveGState()
    context.setAlpha(opacity)
    context.addPath(path)
    context.setFillColor(CGColor(gray: 0.08, alpha: 1))
    context.fillPath()
    context.addPath(path)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
    context.setLineWidth(1.1)
    context.strokePath()
    context.restoreGState()
}

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
    else { fatalError("could not create video frame context") }

    context.setFillColor(CGColor(red: 0.63, green: 0.7, blue: 0.79, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))

    let zoomIn = smoothstep((time - 0.55) / 1.2)
    let pullBack = smoothstep((time - 1.85) / 0.9)
    let zoomedScale = interpolate(1, 2.75, zoomIn)
    let cameraScale = interpolate(zoomedScale, 1.3, pullBack)
    let sceneCenter = CGPoint(x: Double(frameWidth) / 2, y: Double(frameHeight) / 2)
    let zoomCenter = interpolate(sceneCenter, cappyCenter, zoomIn)
    let cameraCenter = interpolate(zoomCenter, CGPoint(x: 850, y: 375), pullBack)

    context.saveGState()
    context.translateBy(x: Double(frameWidth) / 2, y: Double(frameHeight) / 2)
    context.scaleBy(x: cameraScale, y: cameraScale)
    context.translateBy(x: -cameraCenter.x, y: -cameraCenter.y)

    drawDesktop(context: context)
    let clickProgress = smoothstep((time - 1.6) / 0.2) * (1 - smoothstep((time - 2.1) / 0.25))
    drawMenuBar(clickProgress: clickProgress, context: context)

    if time >= 1.68 && time <= 2.14 {
        let ripple = smoothstep((time - 1.68) / 0.46)
        context.setStrokeColor(CGColor(gray: 0.08, alpha: 0.34 * (1 - ripple)))
        context.setLineWidth(1.2)
        context.strokeEllipse(
            in: CGRect(
                x: cappyCenter.x - 8 - 12 * ripple,
                y: cappyCenter.y - 8 - 12 * ripple,
                width: 16 + 24 * ripple,
                height: 16 + 24 * ripple
            )
        )
    }

    let openProgress = smoothstep((time - 1.82) / 0.55)
    let scrollProgress = smoothstep((time - 3.0) / 4.1)
    drawPopover(openProgress: openProgress, scrollProgress: scrollProgress, context: context)

    let cursorApproach = smoothstep((time - 0.3) / 1.3)
    let cursorAfterClick = smoothstep((time - 1.95) / 0.9)
    let cursorStart = CGPoint(x: 760, y: 430)
    let cursorAtMenu = CGPoint(x: cappyCenter.x - 3, y: cappyCenter.y + 7)
    let cursorInPopover = CGPoint(x: 1105, y: 455)
    var cursorPoint = interpolate(cursorStart, cursorAtMenu, cursorApproach)
    cursorPoint = interpolate(cursorPoint, cursorInPopover, cursorAfterClick)
    let cursorOpacity = 1 - smoothstep((time - 3.2) / 0.6)
    drawCursor(at: cursorPoint, opacity: cursorOpacity, context: context)
    context.restoreGState()

    let presentationTime = CMTime(value: Int64(frame), timescale: framesPerSecond)
    guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
    }
}

videoInput.markAsFinished()
await writer.finishWriting()
guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
print(outputURL.path)

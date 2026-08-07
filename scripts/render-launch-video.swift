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
let duration = 6.5
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
            AVVideoAverageBitRateKey: 3_000_000,
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

    context.setFillColor(CGColor(red: 0.94, green: 0.945, blue: 0.95, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))

    let zoom = smoothstep(time / 1.25)
    let appWidth = 350 + (560 - 350) * zoom
    let appHeight = appWidth * Double(sourceCGImage.height) / Double(sourceCGImage.width)
    let overviewTop = (Double(frameHeight) - appHeight) / 2
    let topPosition = 34.0
    let bottomPosition = Double(frameHeight) - appHeight - 34
    let scroll = smoothstep((time - 1.35) / 4.15)
    let appTop = overviewTop + (topPosition - overviewTop) * zoom + (bottomPosition - topPosition) * scroll
    let opacity = smoothstep(time / 0.35) * (1 - smoothstep((time - 6.15) / 0.35))
    let appRect = CGRect(
        x: (Double(frameWidth) - appWidth) / 2,
        y: Double(frameHeight) - appTop - appHeight,
        width: appWidth,
        height: appHeight
    )

    context.saveGState()
    context.setAlpha(opacity)
    context.setShadow(
        offset: CGSize(width: 0, height: -16),
        blur: 34,
        color: CGColor(gray: 0, alpha: 0.16)
    )
    context.draw(sourceCGImage, in: appRect)
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

#!/usr/bin/swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExtractionError: LocalizedError {
    case usage
    case unreadableImage(String)
    case cannotCreateBitmap
    case emptyMark
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: extract-codex-mark.swift <official-codex-icon.png> <output.png>"
        case .unreadableImage(let path):
            return "Could not read an image from \(path)"
        case .cannotCreateBitmap:
            return "Could not create an RGBA bitmap"
        case .emptyMark:
            return "No foreground mark remained after removing the app-icon tile"
        case .cannotWrite(let path):
            return "Could not write \(path)"
        }
    }
}

struct PixelPoint {
    let x: Int
    let y: Int
}

func extractMark(inputPath: String, outputPath: String) throws {
    let inputURL = URL(fileURLWithPath: inputPath)
    guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw ExtractionError.unreadableImage(inputPath)
    }

    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        throw ExtractionError.cannotCreateBitmap
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    func offset(_ point: PixelPoint) -> Int { (point.y * width + point.x) * 4 }
    func isExteriorTilePixel(_ point: PixelPoint) -> Bool {
        let index = offset(point)
        let alpha = Int(pixels[index + 3])
        if alpha < 8 { return true }

        // The official app icon surrounds the blue Codex mark with a neutral
        // rounded tile and shadow. Flood-filling only neutral pixels from the
        // outside removes that chrome while preserving the isolated white
        // terminal glyph inside the mark.
        let scale = 255.0 / Double(alpha)
        let red = min(255, Int((Double(pixels[index]) * scale).rounded()))
        let green = min(255, Int((Double(pixels[index + 1]) * scale).rounded()))
        let blue = min(255, Int((Double(pixels[index + 2]) * scale).rounded()))
        return max(red, green, blue) - min(red, green, blue) <= 22
    }

    var visited = [Bool](repeating: false, count: width * height)
    var queue: [PixelPoint] = []
    queue.reserveCapacity(width * 4 + height * 4)

    func enqueue(_ point: PixelPoint) {
        let index = point.y * width + point.x
        guard !visited[index], isExteriorTilePixel(point) else { return }
        visited[index] = true
        queue.append(point)
    }

    for x in 0..<width {
        enqueue(PixelPoint(x: x, y: 0))
        enqueue(PixelPoint(x: x, y: height - 1))
    }
    for y in 0..<height {
        enqueue(PixelPoint(x: 0, y: y))
        enqueue(PixelPoint(x: width - 1, y: y))
    }

    var cursor = 0
    while cursor < queue.count {
        let point = queue[cursor]
        cursor += 1
        pixels[offset(point) + 3] = 0
        if point.x > 0 { enqueue(PixelPoint(x: point.x - 1, y: point.y)) }
        if point.x + 1 < width { enqueue(PixelPoint(x: point.x + 1, y: point.y)) }
        if point.y > 0 { enqueue(PixelPoint(x: point.x, y: point.y - 1)) }
        if point.y + 1 < height { enqueue(PixelPoint(x: point.x, y: point.y + 1)) }
    }

    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { throw ExtractionError.emptyMark }

    // Keep enough transparent breathing room for the mark to sit beside other
    // provider logos without requiring provider-specific layout code.
    let padding = max(8, Int(Double(max(maxX - minX, maxY - minY)) * 0.10))
    let cropX = max(0, minX - padding)
    let cropY = max(0, minY - padding)
    let cropMaxX = min(width - 1, maxX + padding)
    let cropMaxY = min(height - 1, maxY + padding)
    let crop = CGRect(x: cropX, y: cropY, width: cropMaxX - cropX + 1, height: cropMaxY - cropY + 1)

    guard let processed = context.makeImage()?.cropping(to: crop) else {
        throw ExtractionError.cannotCreateBitmap
    }
    let outputURL = URL(fileURLWithPath: outputPath)
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw ExtractionError.cannotWrite(outputPath)
    }
    CGImageDestinationAddImage(destination, processed, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ExtractionError.cannotWrite(outputPath)
    }
}

do {
    guard CommandLine.arguments.count == 3 else { throw ExtractionError.usage }
    try extractMark(inputPath: CommandLine.arguments[1], outputPath: CommandLine.arguments[2])
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}

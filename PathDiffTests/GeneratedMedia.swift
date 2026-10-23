//
//  GeneratedMedia.swift
//  PathDiffTests
//
//  Real photo and video files generated on the fly, for tests and mock folders.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A small deterministic random number generator, so generated files are the same every run.
struct SeededRandom {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 11) & 0xFFFFF) / Double(0xFFFFF)
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() * Double(range.upperBound - range.lowerBound))
    }
}

// MARK: - Generated photos

enum Landscape {
    /// A simple stylized landscape: sky gradient, sun, layered mountains and a lake.
    static func render(seed: UInt64, width: Int, height: Int, edited: Bool) -> CGImage {
        var random = SeededRandom(state: seed &* 2654435761 &+ 7)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        let palettes: [[(Double, Double, Double)]] = [
            [(0.98, 0.62, 0.38), (0.55, 0.36, 0.62), (0.16, 0.18, 0.36)],   // dusk
            [(0.62, 0.82, 0.98), (0.36, 0.58, 0.86), (0.18, 0.32, 0.52)],   // clear day
            [(0.99, 0.84, 0.56), (0.92, 0.52, 0.42), (0.30, 0.22, 0.40)],   // golden hour
            [(0.78, 0.86, 0.90), (0.52, 0.64, 0.72), (0.24, 0.32, 0.38)],   // overcast
        ]
        let palette = palettes[Int(seed % UInt64(palettes.count))]
        func color(_ c: (Double, Double, Double), _ alpha: Double = 1) -> CGColor {
            var (r, g, b) = c
            if edited {   // warmer, brighter, a little more contrast
                r = min(1, r * 1.12 + 0.04); g = min(1, g * 1.04 + 0.02); b = max(0, b * 0.9)
            }
            return CGColor(colorSpace: space, components: [r, g, b, alpha])!
        }
        let sky = CGGradient(colorsSpace: space, colors: [color(palette[0]), color(palette[1])] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h * 0.35), end: CGPoint(x: 0, y: h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let sunX = w * (0.2 + random.next() * 0.6), sunY = h * (0.6 + random.next() * 0.2), sunR = h * 0.07
        context.setFillColor(color((1, 0.95, 0.82), 0.9))
        context.fillEllipse(in: CGRect(x: sunX - sunR, y: sunY - sunR, width: sunR * 2, height: sunR * 2))
        for layer in 0..<4 {
            let t = Double(layer) / 3
            let shade = (palette[2].0 * (1 - t * 0.5) + 0.05, palette[2].1 * (1 - t * 0.4) + 0.06, palette[2].2 * (1 - t * 0.3) + 0.08)
            context.setFillColor(color(shade))
            let baseY = h * (0.62 - 0.1 * CGFloat(layer))
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: baseY))
            var x: CGFloat = 0
            while x < w {
                let step = w * CGFloat(0.06 + random.next() * 0.1)
                path.addLine(to: CGPoint(x: x + step / 2, y: baseY + h * CGFloat(0.04 + random.next() * 0.16) / CGFloat(layer + 1)))
                path.addLine(to: CGPoint(x: x + step, y: baseY))
                x += step
            }
            path.addLine(to: CGPoint(x: w, y: 0))
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
        }
        let lake = CGGradient(colorsSpace: space, colors: [color(palette[1], 0.85), color(palette[2], 0.95)] as CFArray, locations: [0, 1])!
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: w, height: h * 0.22))
        context.drawLinearGradient(lake, start: CGPoint(x: 0, y: h * 0.22), end: .zero, options: [])
        context.restoreGState()
        if edited {   // a soft vignette, as from a photo editor
            let vignette = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.28)] as CFArray, locations: [0.55, 1])!
            context.drawRadialGradient(vignette, startCenter: CGPoint(x: w / 2, y: h / 2), startRadius: 0, endCenter: CGPoint(x: w / 2, y: h / 2), endRadius: hypot(w, h) / 2, options: [])
        }
        return context.makeImage()!
    }

    static func writeJPEG(_ image: CGImage, to url: URL, taken: Date, camera: (String, String, String), edited: Bool) throws {
        let type = url.pathExtension.lowercased() == "heic" ? UTType.heic : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: camera.0, kCGImagePropertyTIFFModel: camera.1]
        if edited {
            tiff[kCGImagePropertyTIFFSoftware] = "Adobe Lightroom Classic 13.4 (Macintosh)"
            tiff[kCGImagePropertyTIFFDateTime] = formatter.string(from: taken.addingTimeInterval(86_400 * 40))
        } else {
            tiff[kCGImagePropertyTIFFSoftware] = camera.0 == "Apple" ? "17.1.2" : "ILCE-7M4 v3.01"
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.86,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: formatter.string(from: taken),
                kCGImagePropertyExifLensModel: camera.2,
                kCGImagePropertyExifExposureTime: 1.0 / 250,
                kCGImagePropertyExifFNumber: 5.6,
                kCGImagePropertyExifISOSpeedRatings: [200],
                kCGImagePropertyExifFocalLength: 35.0,
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 63.5321, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 19.5112, kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

// MARK: - Generated video

enum Movie {
    /// A short real movie: the landscape with the sun slowly drifting, with camera metadata.
    static func write(to url: URL, seconds: Int, codec: AVVideoCodecType, width: Int, height: Int, seed: UInt64, taken: Date, edited: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        func item(_ key: String, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = key as NSString
            item.value = value as NSString
            return item
        }
        let iso = ISO8601DateFormatter().string(from: taken)
        writer.metadata = [
            item("com.apple.quicktime.make", "DJI"),
            item("com.apple.quicktime.model", "Mavic 3 Pro"),
            item("com.apple.quicktime.creationdate", iso),
            item("com.apple.quicktime.location.ISO6709", "+63.5321-019.5112+012.000/"),
        ] + (edited ? [item("com.apple.quicktime.software", "Final Cut Pro 11.0")] : [])
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = seconds * 30
        let still = Landscape.render(seed: seed, width: width, height: height, edited: edited)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )!
            // A slow pan across a slightly larger frame.
            let progress = CGFloat(frame) / CGFloat(max(frames - 1, 1))
            context.draw(still, in: CGRect(x: -progress * CGFloat(width) * 0.06, y: 0, width: CGFloat(width) * 1.06, height: CGFloat(height) * 1.06))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

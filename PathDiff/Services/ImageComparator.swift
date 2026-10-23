//
//  ImageComparator.swift
//  PathDiff
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Facts about one image file shown next to the visual comparison.
nonisolated struct ImageInfo: Sendable, Equatable {
    /// The image's size as displayed (EXIF orientation applied), which can be larger than
    /// the decoded `SendableImage` when a very large image was decoded at a reduced size.
    let pixelWidth: Int
    let pixelHeight: Int
    let fileSize: Int64
    let typeName: String
    let hasAlpha: Bool
    let colorModel: String?
}

/// `CGImage` is immutable and thread-safe; this lets it cross concurrency domains.
nonisolated final class SendableImage: @unchecked Sendable {
    let cgImage: CGImage

    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

nonisolated struct ImageComparison: Sendable {
    let left: SendableImage?
    let right: SendableImage?
    let leftInfo: ImageInfo?
    let rightInfo: ImageInfo?
    /// Changed pixels in magenta over a faded copy of the image.
    let differenceMask: SendableImage?
    let changedPixels: Int
    let comparedPixels: Int
    /// Bounding box of the changes, in the comparison canvas (top-left origin, unscaled pixels).
    let changedBounds: CGRect?
    /// The comparison ran on a downscaled copy (very large images).
    let wasDownscaled: Bool

    static let empty = ImageComparison(
        left: nil, right: nil, leftInfo: nil, rightInfo: nil, differenceMask: nil,
        changedPixels: 0, comparedPixels: 0, changedBounds: nil, wasDownscaled: false
    )

    var sizesDiffer: Bool {
        guard let leftInfo, let rightInfo else { return false }
        return leftInfo.pixelWidth != rightInfo.pixelWidth || leftInfo.pixelHeight != rightInfo.pixelHeight
    }

    var changedFraction: Double {
        comparedPixels == 0 ? 0 : Double(changedPixels) / Double(comparedPixels)
    }
}

/// Loads images (including PDF and SVG through AppKit) and computes a pixel difference.
nonisolated enum ImageComparator {
    /// Larger canvases are downscaled before comparing, keeping memory and time bounded.
    static let maximumComparedDimension = 2_048
    /// Per-channel difference (0–255) below which pixels count as unchanged; absorbs
    /// re-encoding noise from lossy formats.
    static let defaultTolerance = 6
    /// Images with more pixels are decoded at a reduced size (about 190 MB per side), so
    /// huge scans, panoramas and RAW files can't exhaust memory. Ordinary photos stay full size.
    static let maximumDecodedPixels = 48_000_000
    /// Longest side PDFs and SVGs are rendered at.
    static let maximumVectorDimension = 8_192

    /// A decoded image with the size it is displayed at (see `ImageInfo.pixelWidth`).
    struct LoadedImage {
        let image: CGImage
        let info: ImageInfo
        var size: CGSize { CGSize(width: info.pixelWidth, height: info.pixelHeight) }
    }

    @concurrent
    static func compare(left: URL?, right: URL?, tolerance: Int = defaultTolerance) async -> ImageComparison {
        // Selecting another file cancels this; stop before the next expensive step.
        let leftImage = left.flatMap(load)
        guard !Task.isCancelled else { return .empty }
        let rightImage = right.flatMap(load)
        guard !Task.isCancelled else { return .empty }
        var mask: CGImage?
        var changed = 0
        var compared = 0
        var bounds: CGRect?
        var downscaled = false
        if let base = leftImage ?? rightImage {
            let result = difference(leftImage, rightImage ?? base, tolerance: tolerance)
            mask = result.mask
            changed = result.changed
            compared = result.compared
            bounds = result.bounds
            downscaled = result.scale < 1
        }
        let decodedSmaller = [leftImage, rightImage].contains { $0.map { $0.image.width < $0.info.pixelWidth } ?? false }
        return ImageComparison(
            left: leftImage.map { SendableImage($0.image) },
            right: rightImage.map { SendableImage($0.image) },
            leftInfo: leftImage?.info,
            rightInfo: rightImage?.info,
            differenceMask: mask.map(SendableImage.init),
            changedPixels: changed,
            comparedPixels: compared,
            changedBounds: bounds,
            wasDownscaled: downscaled || decodedSmaller
        )
    }

    static func load(_ url: URL) -> LoadedImage? {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let type = UTType(filenameExtension: url.pathExtension)
        let typeName = type?.localizedDescription ?? url.pathExtension.uppercased()

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            guard let (image, width, height) = decode(source, properties: properties) else { return nil }
            let info = ImageInfo(
                pixelWidth: width,
                pixelHeight: height,
                fileSize: fileSize,
                typeName: typeName,
                hasAlpha: (properties?[kCGImagePropertyHasAlpha] as? Bool) ?? (image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst),
                colorModel: properties?[kCGImagePropertyColorModel] as? String
            )
            return LoadedImage(image: image, info: info)
        }

        // Vector formats (PDF, SVG): render at 2× their natural size, within a limit.
        guard let vector = NSImage(contentsOf: url), vector.size.width > 0, vector.size.height > 0 else { return nil }
        let renderScale = min(2, Double(maximumVectorDimension) / max(vector.size.width, vector.size.height))
        var rect = CGRect(origin: .zero, size: CGSize(width: vector.size.width * renderScale, height: vector.size.height * renderScale))
        guard let image = vector.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let info = ImageInfo(pixelWidth: image.width, pixelHeight: image.height, fileSize: fileSize, typeName: typeName, hasAlpha: true, colorModel: String(localized: "Vector", comment: "Image color model of a vector (PDF/SVG) image"))
        return LoadedImage(image: image, info: info)
    }

    /// Decodes the first image upright (EXIF orientation applied), reduced in size when it
    /// has more than `maximumDecodedPixels`. Also returns its full upright size.
    private static func decode(_ source: CGImageSource, properties: [CFString: Any]?) -> (CGImage, Int, Int)? {
        guard let rawWidth = properties?[kCGImagePropertyPixelWidth] as? Int,
              let rawHeight = properties?[kCGImagePropertyPixelHeight] as? Int,
              rawWidth > 0, rawHeight > 0
        else {
            // No size in the metadata: decode as stored.
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            return (image, image.width, image.height)
        }
        // Orientations 5–8 rotate by 90°, swapping width and height.
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let (width, height) = (5...8).contains(orientation) ? (rawHeight, rawWidth) : (rawWidth, rawHeight)
        let reduction = min(1, (Double(maximumDecodedPixels) / (Double(width) * Double(height))).squareRoot())
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(Double(max(width, height)) * reduction)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (image, width, height)
    }

    /// Draws both images top-left aligned on a shared canvas and marks differing pixels.
    /// Sizes and bounds are in displayed pixels (`ImageInfo`), whatever size was decoded.
    static func difference(_ left: LoadedImage?, _ right: LoadedImage, tolerance: Int) -> (mask: CGImage?, changed: Int, compared: Int, bounds: CGRect?, scale: Double) {
        let fullWidth = max(left?.info.pixelWidth ?? 0, right.info.pixelWidth)
        let fullHeight = max(left?.info.pixelHeight ?? 0, right.info.pixelHeight)
        guard fullWidth > 0, fullHeight > 0 else { return (nil, 0, 0, nil, 1) }
        let scale = min(1, Double(maximumComparedDimension) / Double(max(fullWidth, fullHeight)))
        let width = max(1, Int(Double(fullWidth) * scale))
        let height = max(1, Int(Double(fullHeight) * scale))

        func render(_ loaded: LoadedImage?) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let loaded else { return pixels }
            let image = loaded.image
            pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return }
                context.interpolationQuality = .high
                let drawWidth = Double(loaded.info.pixelWidth) * scale
                let drawHeight = Double(loaded.info.pixelHeight) * scale
                // Core Graphics' origin is bottom-left; align images at the top-left.
                context.draw(image, in: CGRect(x: 0, y: Double(height) - drawHeight, width: drawWidth, height: drawHeight))
            }
            return pixels
        }

        let leftPixels = render(left)
        let rightPixels = render(right)
        var mask = [UInt8](repeating: 0, count: width * height * 4)
        var changed = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1

        leftPixels.withUnsafeBufferPointer { l in
            rightPixels.withUnsafeBufferPointer { r in
                mask.withUnsafeMutableBufferPointer { m in
                    for y in 0..<height {
                        for x in 0..<width {
                            let i = (y * width + x) * 4
                            let delta = max(
                                abs(Int(l[i]) - Int(r[i])),
                                abs(Int(l[i + 1]) - Int(r[i + 1])),
                                abs(Int(l[i + 2]) - Int(r[i + 2])),
                                abs(Int(l[i + 3]) - Int(r[i + 3]))
                            )
                            if delta > tolerance {
                                changed += 1
                                m[i] = 255; m[i + 1] = 0; m[i + 2] = 200; m[i + 3] = 255
                                minX = min(minX, x); maxX = max(maxX, x)
                                minY = min(minY, y); maxY = max(maxY, y)
                            } else {
                                // Faded grayscale of the image for orientation.
                                let source = left == nil ? r : l
                                let luma = (Int(source[i]) * 30 + Int(source[i + 1]) * 59 + Int(source[i + 2]) * 11) / 100
                                let alpha = Int(source[i + 3]) * 45 / 255
                                let gray = UInt8(min(255, luma))
                                m[i] = UInt8(Int(gray) * alpha / 255)
                                m[i + 1] = UInt8(Int(gray) * alpha / 255)
                                m[i + 2] = UInt8(Int(gray) * alpha / 255)
                                m[i + 3] = UInt8(alpha)
                            }
                        }
                    }
                }
            }
        }

        let image: CGImage? = mask.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        // Pixel rows in the buffer run top-down, matching the top-left aligned drawing.
        let bounds: CGRect? = maxX >= 0
            ? CGRect(x: Double(minX) / scale, y: Double(minY) / scale, width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale)
            : nil
        return (image, changed, width * height, bounds, scale)
    }
}

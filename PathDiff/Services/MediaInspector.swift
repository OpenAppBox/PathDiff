//
//  MediaInspector.swift
//  PathDiff
//

import AVFoundation
import CryptoKit
import Foundation
import ImageIO

/// One fact about a media file, shown next to the same fact for the other side.
nonisolated struct MetadataField: Sendable, Hashable, Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

/// Reads what a photo, video or audio file says about itself: dimensions, capture date,
/// camera, duration, codecs and so on. Only headers are read, never the whole file.
nonisolated enum MediaInspector {
    /// Off the main thread: reading headers can block on slow, network or cloud volumes.
    @concurrent
    static func fields(of url: URL, kind: MediaKind) async -> [MetadataField] {
        switch kind {
        case .image: imageFields(of: url)
        case .video, .audio: await audiovisualFields(of: url)
        }
    }

    // MARK: Images

    /// The EXIF "date taken", as recorded by the camera, or `nil` when there is none.
    static func captureDate(of url: URL) -> String? {
        guard let properties = imageProperties(of: url),
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }
        return exif[kCGImagePropertyExifDateTimeOriginal] as? String
    }

    private static func imageProperties(of url: URL) -> [CFString: Any]? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
    }

    static func imageFields(of url: URL) -> [MetadataField] {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else { return [] }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        var fields: [MetadataField] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { fields.append(MetadataField(label: label, value: value)) }
        }

        if let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            add(String(localized: "Dimensions"), "\(width) × \(height)")
        }
        if let type = CGImageSourceGetType(source) as String? {
            add(String(localized: "Format"), UTType(type)?.localizedDescription ?? type)
        }
        add(String(localized: "Date taken"), exifDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String))
        add(String(localized: "Camera"), joined(tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String))
        add(String(localized: "Lens"), exif[kCGImagePropertyExifLensModel] as? String)
        add(String(localized: "Exposure"), exposure(exif))
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation != 1 {
            add(String(localized: "Orientation"), orientationName(orientation))
        }
        add(String(localized: "Color profile"), properties[kCGImagePropertyProfileName] as? String)
        add(String(localized: "Software"), tiff[kCGImagePropertyTIFFSoftware] as? String)
        add(String(localized: "Last edited"), exifDate(tiff[kCGImagePropertyTIFFDateTime] as? String))
        if let gps, let latitude = gps[kCGImagePropertyGPSLatitude] as? Double, let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            let north = (gps[kCGImagePropertyGPSLatitudeRef] as? String) != "S"
            let east = (gps[kCGImagePropertyGPSLongitudeRef] as? String) != "W"
            add(String(localized: "Location"), coordinates(latitude: north ? latitude : -latitude, longitude: east ? longitude : -longitude))
        }
        return fields
    }

    /// EXIF stores dates as "2023:06:22 23:41:05" in the camera's local time; shown like any
    /// other date, or as written when it can't be read.
    static func exifDate(_ text: String?) -> String? {
        guard let text else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: text) else { return text }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "63.53210° N, 19.51120° W".
    static func coordinates(latitude: Double, longitude: Double) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(5))
        return "\(abs(latitude).formatted(format))° \(latitude < 0 ? "S" : "N"), \(abs(longitude).formatted(format))° \(longitude < 0 ? "W" : "E")"
    }

    /// Videos record their location as ISO 6709, e.g. "+63.5321-019.5112+012.000/".
    static func iso6709(_ text: String) -> String? {
        let numbers = text.matches(of: /[+-]\d+(?:\.\d+)?/).compactMap { Double($0.output) }
        guard numbers.count >= 2 else { return nil }
        return coordinates(latitude: numbers[0], longitude: numbers[1])
    }

    private static func exposure(_ exif: [CFString: Any]) -> String? {
        var parts: [String] = []
        // Bounded, because Int() of an absurd value from a damaged header would trap.
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time >= 1e-6, time < 1e6 {
            parts.append(time < 1 ? "1/\(Int((1 / time).rounded())) s" : "\(time.formatted()) s")
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? Double {
            parts.append("ƒ/\(aperture.formatted(.number.precision(.fractionLength(0...1))))")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
            parts.append("ISO \(iso)")
        }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            parts.append("\(focal.formatted(.number.precision(.fractionLength(0...1)))) mm")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func orientationName(_ value: Int) -> String {
        switch value {
        case 3: String(localized: "Rotated 180°")
        case 6: String(localized: "Rotated 90° clockwise")
        case 8: String(localized: "Rotated 90° counterclockwise")
        case 2, 4, 5, 7: String(localized: "Mirrored")
        default: String(localized: "Normal", comment: "Image orientation")
        }
    }

    private static func joined(_ make: String?, _ model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = model?.trimmingCharacters(in: .whitespaces) ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        // Many cameras repeat the make in the model name ("Canon" / "Canon EOS R6").
        return make.isEmpty || model.localizedCaseInsensitiveContains(make) ? model : "\(make) \(model)"
    }

    // MARK: Video and audio

    static func audiovisualFields(of url: URL) async -> [MetadataField] {
        let asset = AVURLAsset(url: url)
        var fields: [MetadataField] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { fields.append(MetadataField(label: label, value: value)) }
        }
        guard let (duration, tracks, metadata) = try? await asset.load(.duration, .tracks, .metadata) else { return [] }

        if duration.isNumeric, duration.seconds > 0 {
            add(String(localized: "Duration"), formatDuration(duration.seconds))
        }
        for track in tracks where track.mediaType == .video {
            guard let (size, transform, frameRate, formats, dataRate) = try? await track.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions, .estimatedDataRate
            ) else { continue }
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            // A damaged track can report a non-finite size, and Int() of it would trap.
            if rect.width.isFinite, rect.height.isFinite, abs(rect.width) < 1e7, abs(rect.height) < 1e7 {
                add(String(localized: "Resolution"), "\(Int(abs(rect.width).rounded())) × \(Int(abs(rect.height).rounded()))")
            }
            if frameRate > 0 { add(String(localized: "Frame rate"), "\(frameRate.formatted(.number.precision(.fractionLength(0...2)))) fps") }
            add(String(localized: "Video codec"), formats.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) })
            if dataRate > 0 { add(String(localized: "Video bit rate"), bitRate(dataRate)) }
            break
        }
        for track in tracks where track.mediaType == .audio {
            guard let (formats, dataRate) = try? await track.load(.formatDescriptions, .estimatedDataRate),
                  let format = formats.first
            else { continue }
            var parts = [codecName(CMFormatDescriptionGetMediaSubType(format))]
            if let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                if description.mSampleRate > 0 { parts.append("\((description.mSampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz") }
                if description.mChannelsPerFrame > 0 { parts.append(channelName(Int(description.mChannelsPerFrame))) }
            }
            if dataRate > 0 { parts.append(bitRate(dataRate)) }
            add(String(localized: "Audio"), parts.joined(separator: " · "))
            break
        }

        let common = (try? await asset.load(.commonMetadata)) ?? []
        if let creation = try? await asset.load(.creationDate) {
            if let date = try? await creation.load(.dateValue) {
                add(String(localized: "Recorded"), date.formatted(date: .abbreviated, time: .standard))
            } else if let text = try? await creation.load(.stringValue) {
                add(String(localized: "Recorded"), text)
            }
        }
        add(String(localized: "Camera"), joined(
            await stringValue(in: metadata + common, keys: ["com.apple.quicktime.make", AVMetadataKey.commonKeyMake.rawValue]),
            await stringValue(in: metadata + common, keys: ["com.apple.quicktime.model", AVMetadataKey.commonKeyModel.rawValue])
        ))
        add(String(localized: "Title", comment: "Media metadata field: the track or video title"), await stringValue(in: common, keys: [AVMetadataKey.commonKeyTitle.rawValue]))
        add(String(localized: "Artist"), await stringValue(in: common, keys: [AVMetadataKey.commonKeyArtist.rawValue]))
        add(String(localized: "Album"), await stringValue(in: common, keys: [AVMetadataKey.commonKeyAlbumName.rawValue]))
        add(String(localized: "Software"), await stringValue(in: metadata + common, keys: ["com.apple.quicktime.software", AVMetadataKey.commonKeySoftware.rawValue]))
        let location = await stringValue(in: metadata + common, keys: ["com.apple.quicktime.location.ISO6709", AVMetadataKey.commonKeyLocation.rawValue])
        add(String(localized: "Location"), location.map { iso6709($0) ?? $0 })
        return fields
    }

    private static func stringValue(in items: [AVMetadataItem], keys: [String]) async -> String? {
        for item in items {
            let key = item.identifier?.rawValue.components(separatedBy: "/").last ?? item.commonKey?.rawValue
            let commonKey = item.commonKey?.rawValue
            guard keys.contains(where: { $0 == key || $0 == commonKey || item.identifier?.rawValue.hasSuffix($0) == true }) else { continue }
            if let value = try? await item.load(.stringValue), !value.isEmpty { return value }
        }
        return nil
    }

    static func formatDuration(_ seconds: Double) -> String {
        // Clamped (to about 31 years), because Int() of a damaged header's value would trap.
        let total = Int(min(max(seconds, 0), 1e9).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    private static func bitRate(_ bitsPerSecond: Float) -> String {
        bitsPerSecond >= 1_000_000
            ? "\((bitsPerSecond / 1_000_000).formatted(.number.precision(.fractionLength(0...1)))) Mbit/s"
            : "\(Int((bitsPerSecond / 1000).rounded())) kbit/s"
    }

    private static func channelName(_ channels: Int) -> String {
        switch channels {
        case 1: String(localized: "Mono")
        case 2: String(localized: "Stereo")
        case 6: "5.1"
        default: String(localized: "\(channels) channels")
        }
    }

    private static func codecName(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC (H.265)"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
             kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
            return "Apple ProRes"
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatAppleLossless: return "Apple Lossless"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatOpus: return "Opus"
        default:
            let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return text.allSatisfy({ $0.isASCII && !$0.isWhitespace || $0 == " " }) && !text.isEmpty ? text : "\(code)"
        }
    }
}

// MARK: - Checksums

/// A file's SHA-256 and MD5 digests, as lowercase hex.
nonisolated struct FileChecksums: Sendable, Equatable {
    let sha256: String
    let md5: String
}

nonisolated enum ChecksumCalculator {
    /// Streams the file once and computes both digests. `progress` receives the fraction read.
    @concurrent
    static func checksums(of url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> FileChecksums {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Double.init) ?? 0
        var sha = SHA256()
        var md5 = Insecure.MD5()
        var read = 0.0
        var lastReported = 0.0
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            sha.update(data: chunk)
            md5.update(data: chunk)
            read += Double(chunk.count)
            if total > 0, read / total - lastReported >= 0.01 {
                lastReported = read / total
                progress?(lastReported)
            }
        }
        return FileChecksums(sha256: hex(sha.finalize()), md5: hex(md5.finalize()))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

//
//  FileCategory.swift
//  PathDiff
//

import Foundation
import Synchronization
import UniformTypeIdentifiers

/// Photos, videos and audio, which get a visual or playable comparison instead of a text diff.
nonisolated enum MediaKind: String, Sendable, Hashable {
    case image
    case video
    case audio

    /// SVG is excluded: it is text and keeps its text diff (with an optional visual one).
    init?(path: String) {
        guard let type = FileCategory.type(forPath: path) else { return nil }
        if type.conforms(to: .svg) { return nil }
        if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            self = .video
        } else if type.conforms(to: .audio) {
            self = .audio
        } else {
            return nil
        }
    }
}

/// A broad kind of file, for the sidebar's file type filter.
nonisolated enum FileCategory: String, Sendable, Hashable, CaseIterable, Identifiable {
    case images
    case videos
    case audio
    case documents
    case code
    case archives
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .images: String(localized: "Photos & Images")
        case .videos: String(localized: "Videos")
        case .audio: String(localized: "Audio")
        case .documents: String(localized: "Documents")
        case .code: String(localized: "Code & Text")
        case .archives: String(localized: "Archives")
        case .other: String(localized: "Other Files")
        }
    }

    var symbolName: String {
        switch self {
        case .images: "photo"
        case .videos: "film"
        case .audio: "waveform"
        case .documents: "doc.richtext"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .archives: "archivebox"
        case .other: "doc"
        }
    }

    init(path: String) {
        guard let type = Self.type(forPath: path) else {
            self = .other
            return
        }
        if type.conforms(to: .image) {
            self = .images
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            self = .videos
        } else if type.conforms(to: .audio) {
            self = .audio
        } else if type.conforms(to: .archive) || type.conforms(to: .diskImage) {
            self = .archives
        } else if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
                    || type.conforms(to: .rtf) || type.conforms(to: .rtfd) || type.conforms(to: .epub)
                    || Self.documentExtensions.contains((path as NSString).pathExtension.lowercased()) {
            self = .documents
        } else if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
                    || type.conforms(to: .xml) || type.conforms(to: .propertyList) {
            self = .code
        } else {
            self = .other
        }
    }

    /// Word-processing formats without a system type that marks them as documents.
    private static let documentExtensions: Set<String> = ["doc", "docx", "odt", "pages", "numbers", "key", "ods", "odp"]

    private static let typeCache = Mutex<[String: UTType?]>([:])

    /// The file type for a path's extension, cached because filtering visits every node.
    static func type(forPath path: String) -> UTType? {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return nil }
        if let cached = typeCache.withLock({ $0[fileExtension] }) { return cached }
        let type = UTType(filenameExtension: fileExtension)
        typeCache.withLock { $0[fileExtension] = type }
        return type
    }
}

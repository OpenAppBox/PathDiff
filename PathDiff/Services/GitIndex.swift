//
//  GitIndex.swift
//  PathDiff
//

import CryptoKit
import Darwin
import Foundation

/// A read-only view of a git work tree's index (`.git/index`).
///
/// Git records, for every tracked file, the object ID of its contents together with the
/// file's size, modification time and inode at the moment it was staged or checked out.
/// When a file's current `lstat` still matches that record, its contents are known without
/// reading it. Comparing two clones then only needs to read files that are actually
/// different or were touched since the last git operation.
nonisolated struct GitIndex: Sendable {
    struct Entry: Sendable {
        let objectID: [UInt8]
        let modifiedSeconds: UInt32
        let modifiedNanoseconds: UInt32
        let inode: UInt32
        let size: UInt32
    }

    let entries: [String: Entry]
    /// Entries modified at or after this instant are "racily clean" and can't be trusted.
    let indexModifiedSeconds: Int
    let indexModifiedNanoseconds: Int
    /// Settings that change how working files map to stored objects (line-ending
    /// conversion). Two indexes are only comparable when these match.
    let conversionSignature: String

    static func load(root: URL) -> GitIndex? {
        let gitDirectory = root.appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDirectory.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        let indexURL = gitDirectory.appending(path: "index")
        var info = stat()
        guard lstat(indexURL.path(percentEncoded: false), &info) == 0,
              let data = try? Data(contentsOf: indexURL, options: .mappedIfSafe)
        else { return nil }

        let config = (try? String(contentsOf: gitDirectory.appending(path: "config"), encoding: .utf8)) ?? ""
        let hashLength = config.range(of: "objectformat\\s*=\\s*sha256", options: [.regularExpression, .caseInsensitive]) != nil ? 32 : 20
        guard let entries = parse(data, hashLength: hashLength) else { return nil }

        return GitIndex(
            entries: entries,
            indexModifiedSeconds: info.st_mtimespec.tv_sec,
            indexModifiedNanoseconds: info.st_mtimespec.tv_nsec,
            conversionSignature: conversionSignature(root: root, config: config)
        )
    }

    /// The stored object ID for a file, if the file on disk is unchanged since git saw it.
    func cleanObjectID(for relativePath: String, url: URL) -> [UInt8]? {
        guard let entry = entries[relativePath] else { return nil }
        let modified = (Int(entry.modifiedSeconds), Int(entry.modifiedNanoseconds))
        guard modified < (indexModifiedSeconds, indexModifiedNanoseconds) else { return nil }

        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &info) } ?? -1
        }
        guard result == 0, (info.st_mode & S_IFMT) == S_IFREG,
              UInt32(truncatingIfNeeded: info.st_size) == entry.size,
              UInt32(truncatingIfNeeded: info.st_mtimespec.tv_sec) == entry.modifiedSeconds,
              UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec) == entry.modifiedNanoseconds,
              UInt32(truncatingIfNeeded: info.st_ino) == entry.inode
        else { return nil }
        return entry.objectID
    }

    // MARK: Parsing

    /// Parses index versions 2, 3 and 4. Returns `nil` for anything unexpected, in which case
    /// files are simply compared by reading them.
    static func parse(_ data: Data, hashLength: Int) -> [String: Entry]? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [String: Entry]? in
            guard raw.count >= 12, raw[0] == 0x44, raw[1] == 0x49, raw[2] == 0x52, raw[3] == 0x43 else { return nil }   // "DIRC"
            func be32(_ offset: Int) -> UInt32 {
                UInt32(raw[offset]) << 24 | UInt32(raw[offset + 1]) << 16 | UInt32(raw[offset + 2]) << 8 | UInt32(raw[offset + 3])
            }
            func be16(_ offset: Int) -> UInt16 {
                UInt16(raw[offset]) << 8 | UInt16(raw[offset + 1])
            }

            let version = be32(4)
            guard (2...4).contains(version) else { return nil }
            let count = Int(be32(8))
            var entries: [String: Entry] = [:]
            // The header's count isn't trusted for allocation: a damaged file could claim
            // billions of entries. Each entry takes at least 62 bytes.
            entries.reserveCapacity(min(count, raw.count / 62))
            var offset = 12
            var previousPath: [UInt8] = []

            for _ in 0..<count {
                let start = offset
                let fixedLength = 40 + hashLength + 2
                guard offset + fixedLength <= raw.count else { return nil }
                let modifiedSeconds = be32(offset + 8)
                let modifiedNanoseconds = be32(offset + 12)
                let inode = be32(offset + 20)
                let mode = be32(offset + 24)
                let size = be32(offset + 36)
                let objectID = Array(raw[(offset + 40)..<(offset + 40 + hashLength)])
                let flags = be16(offset + 40 + hashLength)
                offset += fixedLength

                var extendedFlags: UInt16 = 0
                if flags & 0x4000 != 0 {
                    guard version >= 3, offset + 2 <= raw.count else { return nil }
                    extendedFlags = be16(offset)
                    offset += 2
                }

                var path: [UInt8]
                if version == 4 {
                    // Prefix-compressed: strip N bytes from the previous path, append the rest.
                    guard offset < raw.count else { return nil }
                    var byte = raw[offset]
                    offset += 1
                    var strip = Int(byte & 0x7F)
                    var continuationBytes = 0
                    while byte & 0x80 != 0 {
                        // Real paths need at most a few bytes here; more means a damaged file
                        // (and the shifts would overflow).
                        continuationBytes += 1
                        guard offset < raw.count, continuationBytes <= 4 else { return nil }
                        byte = raw[offset]
                        offset += 1
                        strip = ((strip + 1) << 7) | Int(byte & 0x7F)
                    }
                    guard (0...previousPath.count).contains(strip), let end = nulIndex(in: raw, from: offset) else { return nil }
                    path = Array(previousPath.dropLast(strip))
                    path.append(contentsOf: raw[offset..<end])
                    offset = end + 1
                } else {
                    guard let end = nulIndex(in: raw, from: offset) else { return nil }
                    path = Array(raw[offset..<end])
                    // Entries are NUL-padded to a multiple of 8 bytes.
                    offset = start + ((end - start + 8) & ~7)
                }
                previousPath = path

                let stage = (flags >> 12) & 0x3
                let assumeValid = flags & 0x8000 != 0
                let skipWorktree = extendedFlags & 0x4000 != 0
                let intentToAdd = extendedFlags & 0x2000 != 0
                let isRegularFile = mode & 0o170000 == 0o100000
                guard stage == 0, !assumeValid, !skipWorktree, !intentToAdd, isRegularFile else { continue }

                entries[String(decoding: path, as: UTF8.self)] = Entry(
                    objectID: objectID,
                    modifiedSeconds: modifiedSeconds,
                    modifiedNanoseconds: modifiedNanoseconds,
                    inode: inode,
                    size: size
                )
            }
            return entries
        }
    }

    private static func nulIndex(in raw: UnsafeRawBufferPointer, from offset: Int) -> Int? {
        var index = offset
        while index < raw.count {
            if raw[index] == 0 { return index }
            index += 1
        }
        return nil
    }

    /// Line-ending settings from the repository config plus the root `.gitattributes` and
    /// `.git/info/attributes`, which control how files are converted on checkout.
    private static func conversionSignature(root: URL, config: String) -> String {
        var settings: [String] = []
        for line in config.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix("autocrlf") || trimmed.hasPrefix("eol") || trimmed.hasPrefix("safecrlf") {
                settings.append(trimmed.replacingOccurrences(of: " ", with: ""))
            }
        }
        for attributes in [root.appending(path: ".gitattributes"), root.appending(path: ".git/info/attributes")] {
            if let data = try? Data(contentsOf: attributes) {
                settings.append(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            } else {
                settings.append("-")
            }
        }
        return settings.joined(separator: "|")
    }
}

/// The git indexes of both trees, when they can be used together.
nonisolated struct GitIndexPair: Sendable {
    let left: GitIndex
    let right: GitIndex

    init?(left: GitIndex?, right: GitIndex?) {
        guard let left, let right, left.conversionSignature == right.conversionSignature else { return nil }
        self.left = left
        self.right = right
    }

    /// `true`/`false` when both files are unchanged since git saw them; `nil` otherwise.
    /// A differing result is only trusted when no text normalization is requested.
    func knownResult(for job: ComparisonJob, options: DiffOptions) -> Bool? {
        guard let leftID = left.cleanObjectID(for: job.relativePath, url: job.leftURL),
              let rightID = right.cleanObjectID(for: job.relativePath, url: job.rightURL)
        else { return nil }
        // Equal IDs with different sizes happen when the same blob is checked out differently,
        // e.g. a Git LFS pointer in one clone and the real file in the other.
        if leftID == rightID { return job.leftMetadata.size == job.rightMetadata.size ? true : nil }
        return options.isTextAware ? nil : false
    }
}

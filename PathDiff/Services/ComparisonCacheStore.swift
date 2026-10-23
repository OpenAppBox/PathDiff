//
//  ComparisonCacheStore.swift
//  PathDiff
//

import CryptoKit
import Foundation
import OSLog

/// One remembered file comparison: both files' stamps and whether their contents matched.
nonisolated struct CachedComparison: Sendable, Equatable {
    let left: FileStamp
    let right: FileStamp
    let isEqual: Bool
}

/// Persists comparison results between launches, one file per folder pair and option set,
/// so reopening a huge comparison only reads files that changed since last time.
///
/// Format (little-endian): magic "PDC1", entry count, then per entry the UTF-8 path, both
/// stamps and a flags byte. Unknown or damaged files are ignored and rebuilt.
nonisolated struct ComparisonCacheStore: Sendable {
    let directory: URL

    /// Most recently used caches kept on disk.
    static let maximumCacheFiles = 24
    private static let magic: UInt32 = 0x3143_4450   // "PDC1"
    private static let logger = Logger(subsystem: "com.openappbox.pathdiff", category: "ComparisonCache")

    /// Inside the app's own caches (the sandbox container when sandboxed).
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: Bundle.main.bundleIdentifier ?? "PathDiff", directoryHint: .isDirectory)
            .appending(path: "ComparisonResults", directoryHint: .isDirectory)
    }

    func fileURL(leftRoot: URL, rightRoot: URL, options: DiffOptions) -> URL {
        var identity = [
            leftRoot.standardizedFileURL.path(percentEncoded: false),
            rightRoot.standardizedFileURL.path(percentEncoded: false),
            "ws=\(options.ignoreWhitespace)",
            "le=\(options.ignoreLineEndings)",
        ]
        // Contents comparisons keep the identity older versions used, so their caches stay valid.
        if options.comparisonMethod != .contents { identity.append("cm=\(options.comparisonMethod.rawValue)") }
        let name = SHA256.hash(data: Data(identity.joined(separator: "\n").utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name + ".pdcache")
    }


    func load(leftRoot: URL, rightRoot: URL, options: DiffOptions) -> [String: CachedComparison] {
        let url = fileURL(leftRoot: leftRoot, rightRoot: rightRoot, options: options)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [:] }
        guard let entries = Self.decode(data) else {
            Self.logger.notice("Discarding unreadable comparison cache \(url.lastPathComponent, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return [:]
        }
        // Mark as recently used so pruning keeps it.
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path(percentEncoded: false))
        return entries
    }

    func save(_ entries: [String: CachedComparison], leftRoot: URL, rightRoot: URL, options: DiffOptions) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = fileURL(leftRoot: leftRoot, rightRoot: rightRoot, options: options)
            try Self.encode(entries).write(to: url, options: .atomic)
            prune()
        } catch {
            Self.logger.error("Couldn’t save comparison cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove(leftRoot: URL, rightRoot: URL) {
        for method in ComparisonMethod.allCases {
            for whitespace in [false, true] {
                for lineEndings in [false, true] {
                    let options = DiffOptions(ignoreWhitespace: whitespace, ignoreLineEndings: lineEndings, comparisonMethod: method)
                    try? FileManager.default.removeItem(at: fileURL(leftRoot: leftRoot, rightRoot: rightRoot, options: options))
                }
            }
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Total size of all cache files, for display in Settings.
    func totalSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func prune() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)),
              files.count > Self.maximumCacheFiles
        else { return }
        let sorted = files.sorted {
            let lhs = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for file in sorted.dropFirst(Self.maximumCacheFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Encoding

    static func encode(_ entries: [String: CachedComparison]) -> Data {
        var data = Data()
        data.reserveCapacity(entries.count * 96)
        append(magic, to: &data)
        append(UInt32(entries.count), to: &data)
        for (path, entry) in entries {
            let bytes = Array(path.utf8)
            append(UInt32(bytes.count), to: &data)
            data.append(contentsOf: bytes)
            append(entry.left, to: &data)
            append(entry.right, to: &data)
            var flags: UInt8 = entry.isEqual ? 1 : 0
            if entry.left.identifier != nil { flags |= 2 }
            if entry.right.identifier != nil { flags |= 4 }
            data.append(flags)
        }
        return data
    }

    static func decode(_ data: Data) -> [String: CachedComparison]? {
        var reader = Reader(data: data)
        guard reader.read(UInt32.self) == magic, let count = reader.read(UInt32.self) else { return nil }
        var entries: [String: CachedComparison] = [:]
        entries.reserveCapacity(min(Int(count), data.count / 32))   // a damaged count must not allocate gigabytes
        for _ in 0..<count {
            guard let length = reader.read(UInt32.self),
                  let path = reader.readString(length: Int(length)),
                  let left = reader.readStamp(),
                  let right = reader.readStamp(),
                  let flags = reader.read(UInt8.self)
            else { return nil }
            entries[path] = CachedComparison(
                left: flags & 2 != 0 ? left : FileStamp(size: left.size, modified: left.modified, identifier: nil),
                right: flags & 4 != 0 ? right : FileStamp(size: right.size, modified: right.modified, identifier: nil),
                isEqual: flags & 1 != 0
            )
        }
        return entries
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ stamp: FileStamp, to data: inout Data) {
        append(stamp.size, to: &data)
        append(stamp.modified.bitPattern, to: &data)
        append(stamp.identifier ?? 0, to: &data)
    }

    private struct Reader {
        let data: Data
        var offset: Int

        init(data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.endIndex else { return nil }
            var value: T = 0
            _ = withUnsafeMutableBytes(of: &value) { buffer in
                data.copyBytes(to: buffer, from: offset..<(offset + size))
            }
            offset += size
            return T(littleEndian: value)
        }

        mutating func readString(length: Int) -> String? {
            guard length >= 0, offset + length <= data.endIndex else { return nil }
            let string = String(decoding: data[offset..<(offset + length)], as: UTF8.self)
            offset += length
            return string
        }

        mutating func readStamp() -> FileStamp? {
            guard let size = read(Int64.self), let modified = read(UInt64.self), let identifier = read(UInt64.self) else { return nil }
            return FileStamp(size: size, modified: Double(bitPattern: modified), identifier: identifier)
        }
    }
}

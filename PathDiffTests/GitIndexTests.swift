//
//  GitIndexTests.swift
//  PathDiffTests
//

import CryptoKit
import Darwin
import Foundation
import Testing

@Suite("Git index")
struct GitIndexTests {
    private struct EntrySpec {
        let path: String
        let objectID: [UInt8]
        let info: stat
    }

    /// Writes an index file the way git does (versions 2 and 4).
    private func indexData(version: UInt32, entries: [EntrySpec]) -> Data {
        var data = Data("DIRC".utf8)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        append32(version)
        append32(UInt32(entries.count))
        var previous: [UInt8] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let start = data.count
            append32(UInt32(truncatingIfNeeded: entry.info.st_ctimespec.tv_sec))
            append32(UInt32(truncatingIfNeeded: entry.info.st_ctimespec.tv_nsec))
            append32(UInt32(truncatingIfNeeded: entry.info.st_mtimespec.tv_sec))
            append32(UInt32(truncatingIfNeeded: entry.info.st_mtimespec.tv_nsec))
            append32(UInt32(truncatingIfNeeded: entry.info.st_dev))
            append32(UInt32(truncatingIfNeeded: entry.info.st_ino))
            append32(0o100644)
            append32(UInt32(entry.info.st_uid))
            append32(UInt32(entry.info.st_gid))
            append32(UInt32(truncatingIfNeeded: entry.info.st_size))
            data.append(contentsOf: entry.objectID)
            let path = Array(entry.path.utf8)
            append16(UInt16(min(path.count, 0xFFF)))
            if version == 4 {
                let common = zip(previous, path).prefix { $0 == $1 }.count
                var strip = previous.count - common
                // git's offset varint
                var bytes: [UInt8] = [UInt8(strip & 0x7F)]
                strip >>= 7
                while strip > 0 {
                    strip -= 1
                    bytes.insert(UInt8(0x80 | (strip & 0x7F)), at: 0)
                    strip >>= 7
                }
                data.append(contentsOf: bytes)
                data.append(contentsOf: path[common...])
                data.append(0)
            } else {
                data.append(contentsOf: path)
                let length = data.count - start
                data.append(contentsOf: [UInt8](repeating: 0, count: ((length + 8) & ~7) - length))
            }
            previous = path
        }
        data.append(contentsOf: [UInt8](repeating: 0, count: 20))   // checksum (not verified)
        return data
    }

    private func makeRepository(version: UInt32) throws -> (FolderFixture, [String: [UInt8]]) {
        let fixture = try FolderFixture()
        let root = fixture.left
        var specs: [EntrySpec] = []
        var objectIDs: [String: [UInt8]] = [:]
        let paths = ["README.md", "src/a.swift", "src/b.swift", "src/nested/deep/c.swift", "zz.txt"]
        for (index, path) in paths.enumerated() {
            let url = try fixture.write(.left, path, "contents \(index)\n")
            var info = stat()
            #expect(lstat(url.path(percentEncoded: false), &info) == 0)
            let objectID = Array(Insecure.SHA1.hash(data: Data("blob \(info.st_size)\0contents \(index)\n".utf8)))
            objectIDs[path] = objectID
            specs.append(EntrySpec(path: path, objectID: objectID, info: info))
        }
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        Thread.sleep(forTimeInterval: 0.01)   // the index must be newer than its entries
        try indexData(version: version, entries: specs).write(to: root.appending(path: ".git/index"))
        return (fixture, objectIDs)
    }

    @Test(arguments: [UInt32(2), UInt32(4)])
    func parsesEntriesAndTrustsUnchangedFiles(version: UInt32) throws {
        let (fixture, objectIDs) = try makeRepository(version: version)
        let index = try #require(GitIndex.load(root: fixture.left))
        #expect(index.entries.count == objectIDs.count)
        for (path, objectID) in objectIDs {
            #expect(index.entries[path]?.objectID == objectID)
            #expect(index.cleanObjectID(for: path, url: fixture.url(.left, path)) == objectID)
        }
        // Rewriting a file changes its stat data, so the index no longer vouches for it.
        try fixture.write(.left, "src/a.swift", "changed!\n")
        #expect(index.cleanObjectID(for: "src/a.swift", url: fixture.url(.left, "src/a.swift")) == nil)
    }

    @Test func requiresAGitDirectory() throws {
        let fixture = try FolderFixture()
        #expect(GitIndex.load(root: fixture.left) == nil)
    }

    @Test func rejectsGarbage() {
        #expect(GitIndex.parse(Data("not an index".utf8), hashLength: 20) == nil)
    }
}

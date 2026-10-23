//
//  TestSupport.swift
//  PathDiffTests
//

import Foundation
import Testing

/// A pair of temporary folders that is deleted when the test ends.
final class FolderFixture {
    let root: URL
    let left: URL
    let right: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "PathDiffTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        left = root.appending(path: "main", directoryHint: .isDirectory)
        right = root.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    }

    deinit {
        // Restore permissions changed by tests so everything can be removed.
        if let enumerator = FileManager.default.enumerator(atPath: root.path(percentEncoded: false)) {
            while let path = enumerator.nextObject() as? String {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: path).path(percentEncoded: false))
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ side: FixtureSide, _ path: String) -> URL {
        (side == .left ? left : right).appending(path: path)
    }

    @discardableResult
    func write(_ side: FixtureSide, _ path: String, _ text: String) throws -> URL {
        let url = url(side, path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func writeBoth(_ path: String, _ text: String) throws {
        try write(.left, path, text)
        try write(.right, path, text)
    }

    func read(_ side: FixtureSide, _ path: String) throws -> String {
        try String(contentsOf: url(side, path), encoding: .utf8)
    }

    func exists(_ side: FixtureSide, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(side, path).path(percentEncoded: false))
    }
}

enum FixtureSide {
    case left
    case right
}

struct TimeoutError: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for \(what)" }
}

/// Polls `condition` on the main actor until it holds.
func waitUntil(_ what: String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline { throw TimeoutError(what: what) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

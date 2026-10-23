//
//  FolderScannerTests.swift
//  PathDiffTests
//

import Darwin
import Foundation
import Testing

@Suite("Folder scanning")
struct FolderScannerTests {
    private let rules = ScanRules(matcher: IgnoreMatcher(patterns: IgnoreMatcher.defaultPatterns), respectsGitIgnore: true)

    private func statuses(_ nodes: [DiffNode]) -> [String: FileStatus] {
        var result: [String: FileStatus] = [:]
        DiffTree.forEachDepthFirst(nodes) { result[$0.id] = $0.status }
        return result
    }

    private func makeMixedFixture() throws -> FolderFixture {
        let fixture = try FolderFixture()
        try fixture.writeBoth("README.md", "hello\n")
        try fixture.write(.left, "src/a.swift", "let a = 1\n")
        try fixture.write(.right, "src/a.swift", "let a = 2\n")
        try fixture.write(.left, "src/only_left.txt", "x")
        try fixture.write(.right, "src/new/added.txt", "y\n")
        try fixture.write(.left, "crlf.txt", "a\r\nb\r\n")
        try fixture.write(.right, "crlf.txt", "a\nb\n")
        try fixture.write(.left, "ws.txt", "a  b\n")
        try fixture.write(.right, "ws.txt", "a b\n")
        try fixture.write(.left, "node_modules/x.js", "1")
        try fixture.write(.right, "node_modules/x.js", "2")
        try fixture.writeBoth(".gitignore", "out/\n")
        try fixture.write(.left, "out/build.js", "1")
        try fixture.write(.left, "mixed", "file")
        try fixture.write(.right, "mixed/inner.txt", "i")
        try FileManager.default.createSymbolicLink(at: fixture.url(.left, "link"), withDestinationURL: URL(fileURLWithPath: "README.md"))
        try FileManager.default.createSymbolicLink(at: fixture.url(.right, "link"), withDestinationURL: URL(fileURLWithPath: "src"))
        return fixture
    }

    @Test func classifiesEveryKindOfItem() async throws {
        let fixture = try makeMixedFixture()
        let outcome = try await FolderScanner(cacheDirectory: nil).scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions())
        let status = statuses(outcome.nodes)
        #expect(status["README.md"] == .identical)
        #expect(status["src/a.swift"] == .modified)
        #expect(status["src/only_left.txt"] == .leftOnly)
        #expect(status["src/new"] == .rightOnly)
        #expect(status["src"] == .modified)
        #expect(status["node_modules"] == .ignored)
        #expect(status["out"] == .ignored, ".gitignore applies")
        #expect(status["crlf.txt"] == .modified)
        #expect(status["mixed"] == .modified)
        #expect(DiffTree.node(at: "mixed", in: outcome.nodes)?.hasKindMismatch == true)
        #expect(status["link"] == .modified)
        #expect(outcome.issues.isEmpty)
    }

    @Test func textOptionsTreatEquivalentFilesAsIdentical() async throws {
        let fixture = try makeMixedFixture()
        let scanner = FolderScanner(cacheDirectory: nil)
        let whitespace = try await scanner.scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions(ignoreWhitespace: true))
        #expect(statuses(whitespace.nodes)["ws.txt"] == .identical)
        #expect(statuses(whitespace.nodes)["crlf.txt"] == .identical)
        let lineEndings = try await scanner.scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions(ignoreLineEndings: true))
        #expect(statuses(lineEndings.nodes)["crlf.txt"] == .identical)
        #expect(statuses(lineEndings.nodes)["ws.txt"] == .modified)
    }

    @Test func partialRefreshMatchesFullRescan() async throws {
        let fixture = try makeMixedFixture()
        let scanner = FolderScanner(cacheDirectory: nil)
        var nodes = try await scanner.scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions()).nodes

        try fixture.write(.right, "src/a.swift", "let a = 1\n")
        try fixture.write(.right, "deep/er/new.txt", "z")
        try FileManager.default.removeItem(at: fixture.url(.left, "src/only_left.txt"))
        for path in ["src/a.swift", "deep/er/new.txt", "src/only_left.txt"] {
            let target = DiffTree.refreshTarget(for: path, in: nodes)
            let result = try await scanner.scanItem(relativePath: target, leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions())
            nodes = DiffTree.replacing(path: target, with: result.node, in: nodes)
        }
        let full = try await scanner.scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions())
        #expect(statuses(nodes) == statuses(full.nodes))
        #expect(DiffSummary(nodes: nodes) == DiffSummary(nodes: full.nodes))
    }

    @Test func reportsUnreadableFolders() async throws {
        let fixture = try makeMixedFixture()
        try fixture.writeBoth("locked/secret.txt", "s")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.url(.left, "locked").path(percentEncoded: false))
        let outcome = try await FolderScanner(cacheDirectory: nil).scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions())
        #expect(outcome.issues.contains { $0.path == "locked" && $0.side == .left })
    }

    @Test func missingRootIsAnError() async throws {
        let fixture = try FolderFixture()
        let missing = fixture.root.appending(path: "does-not-exist")
        await #expect(throws: ScanError.self) {
            _ = try await FolderScanner(cacheDirectory: nil).scan(leftRoot: missing, rightRoot: fixture.right, rules: rules, options: DiffOptions())
        }
    }

    @Test func rememberedResultsSurviveANewScanner() async throws {
        let fixture = try FolderFixture()
        try fixture.writeBoth("same.txt", "abc\n")
        // Results for files modified in the last seconds aren't remembered (see the next test).
        for side in [FixtureSide.left, .right] {
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3600)], ofItemAtPath: fixture.url(side, "same.txt").path(percentEncoded: false))
        }
        let cacheDirectory = fixture.root.appending(path: "cache")
        let first = try await FolderScanner(cacheDirectory: cacheDirectory).scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions())
        #expect(statuses(first.nodes)["same.txt"] == .identical)
        let store = ComparisonCacheStore(directory: cacheDirectory)
        try await waitUntil("cache file") {
            !store.load(leftRoot: fixture.left, rightRoot: fixture.right, options: DiffOptions()).isEmpty
        }

        // Change the contents in place, keeping size, modification date and inode: only a
        // remembered result can still call the files identical.
        let path = fixture.url(.right, "same.txt").path(percentEncoded: false)
        var original = stat()
        #expect(lstat(path, &original) == 0)
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.write(contentsOf: Data("xyz\n".utf8))
        try handle.close()
        var times = [original.st_atimespec, original.st_mtimespec]
        #expect(utimensat(AT_FDCWD, path, &times, 0) == 0)

        let scanner = FolderScanner(cacheDirectory: cacheDirectory)
        let remembered = try await scanner.scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions())
        #expect(statuses(remembered.nodes)["same.txt"] == .identical)

        await scanner.clearCaches(leftRoot: fixture.left, rightRoot: fixture.right)
        let fresh = try await scanner.scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions())
        #expect(statuses(fresh.nodes)["same.txt"] == .modified)
    }

    /// A file can be rewritten within its timestamp's resolution without its stamp changing,
    /// so a result for a file modified moments ago must not be reused.
    @Test func justModifiedFilesAreNotRemembered() async throws {
        let fixture = try FolderFixture()
        try fixture.writeBoth("same.txt", "abc\n")
        let cacheDirectory = fixture.root.appending(path: "cache")
        let scanner = FolderScanner(cacheDirectory: cacheDirectory)
        let first = try await scanner.scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions())
        #expect(statuses(first.nodes)["same.txt"] == .identical)

        // Rewrite in place with the same size and stamp, as a quick second save would.
        let path = fixture.url(.right, "same.txt").path(percentEncoded: false)
        var original = stat()
        #expect(lstat(path, &original) == 0)
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.write(contentsOf: Data("xyz\n".utf8))
        try handle.close()
        var times = [original.st_atimespec, original.st_mtimespec]
        #expect(utimensat(AT_FDCWD, path, &times, 0) == 0)

        let second = try await scanner.scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions())
        #expect(statuses(second.nodes)["same.txt"] == .modified)
    }

    @Test func cacheEncodingRoundTrips() {
        let entries = [
            "a/b.txt": CachedComparison(left: FileStamp(size: 10, modified: 123.456, identifier: 99), right: FileStamp(size: 10, modified: 789.5, identifier: nil), isEqual: true),
            "é/ü.swift": CachedComparison(left: FileStamp(size: 0, modified: 0, identifier: nil), right: FileStamp(size: 5, modified: -1, identifier: 7), isEqual: false),
        ]
        #expect(ComparisonCacheStore.decode(ComparisonCacheStore.encode(entries)) == entries)
        #expect(ComparisonCacheStore.decode(Data("junk".utf8)) == nil)
    }
}

@Suite("Move detection")
struct MoveDetectionTests {
    private let rules = ScanRules(matcher: IgnoreMatcher(patterns: []), respectsGitIgnore: false)

    @Test func detectsFileFolderAndEditedMoves() async throws {
        let fixture = try FolderFixture()
        for index in 0..<4 {
            let text = "module \(index)\n" + String(repeating: "body\n", count: index + 1)
            try fixture.write(.left, "lib/old/m\(index).ts", text)
            try fixture.write(.right, "lib/new/m\(index).ts", text)
        }
        let body = (0..<20).map { "line \($0)\n" }.joined()
        try fixture.write(.left, "a/Widget.swift", body)
        try fixture.write(.right, "b/sub/Widget.swift", body.replacingOccurrences(of: "line 3\n", with: "line three\n"))
        try fixture.write(.left, "docs/guide.md", body)
        try fixture.write(.right, "docs/guide-v2.md", body + "appendix\n")
        try fixture.writeBoth("docs/keep.md", "k")
        try fixture.write(.left, "unrelated.txt", "nothing in common")
        try fixture.write(.right, "other.txt", "completely different")

        let scanner = FolderScanner(cacheDirectory: nil)
        let nodes = try await scanner.scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions()).nodes
        let moves = try await scanner.detectMoves(in: nodes)

        let folder = try #require(moves.byLeftPath["lib/old"])
        #expect(folder.isDirectory && folder.rightPath == "lib/new" && folder.isExact && folder.totalFiles == 4)
        #expect(moves.byLeftPath["lib/old/m2.ts"]?.rightPath == "lib/new/m2.ts")
        #expect(moves.byLeftPath["a/Widget.swift"]?.rightPath == "b/sub/Widget.swift")
        #expect(moves.byLeftPath["a/Widget.swift"]?.isExact == false)
        #expect(moves.byLeftPath["docs/guide.md"]?.rightPath == "docs/guide-v2.md", "renamed and edited in place")
        #expect(moves.byLeftPath["unrelated.txt"] == nil)

        var summary = DiffSummary(nodes: nodes)
        summary.apply(moves)
        #expect(summary.moved == 6 && summary.leftOnly == 1 && summary.rightOnly == 1)

        let mirrored = moves.mirrored()
        #expect(mirrored.byLeftPath["lib/new"]?.rightPath == "lib/old")
    }
}

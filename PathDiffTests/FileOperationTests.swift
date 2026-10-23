//
//  FileOperationTests.swift
//  PathDiffTests
//

import Foundation
import Testing

@Suite("Sync plans and file operations")
struct FileOperationTests {
    private let rules = ScanRules(matcher: IgnoreMatcher(patterns: IgnoreMatcher.defaultPatterns), respectsGitIgnore: false)
    private let service = FileManagerService()

    private func scan(_ fixture: FolderFixture) async throws -> [DiffNode] {
        try await FolderScanner(cacheDirectory: nil).scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions()).nodes
    }

    @Test func folderCopyCopiesOnlyDifferencesAndUndoRestores() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "src/a.swift", "new\n")
        try fixture.write(.right, "src/a.swift", "old\n")
        try fixture.write(.left, "src/only_left.txt", "x")
        try fixture.write(.right, "src/only_right.txt", "keep me")
        try fixture.writeBoth("src/same.txt", "same")
        let nodes = try await scan(fixture)

        let plan = SyncPlanner.plan(for: try #require(DiffTree.node(at: "src", in: nodes)), direction: .leftToRight, leftRoot: fixture.left, rightRoot: fixture.right)
        #expect(plan.fileCount == 2 && plan.directoryCount == 0)
        let snapshots = try #require(try await service.capture(plan.destinationURLs))
        try await service.execute(plan)
        #expect(try fixture.read(.right, "src/a.swift") == "new\n")
        #expect(try fixture.read(.right, "src/only_left.txt") == "x")
        #expect(fixture.exists(.right, "src/only_right.txt"), "nothing is deleted on the destination")

        try await service.restore(snapshots)
        #expect(try fixture.read(.right, "src/a.swift") == "old\n")
        #expect(!fixture.exists(.right, "src/only_left.txt"))
    }

    @Test func copyIntoMissingFoldersCreatesAndUndoRemovesThem() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "deep/er/file.txt", "z")
        let nodes = try await scan(fixture)
        let plan = SyncPlanner.plan(for: try #require(DiffTree.node(at: "deep/er/file.txt", in: nodes)), direction: .leftToRight, leftRoot: fixture.left, rightRoot: fixture.right)
        #expect(plan.refreshPaths == ["deep"])
        #expect(plan.directoryCount == 2)
        let snapshots = try #require(try await service.capture(plan.destinationURLs))
        try await service.execute(plan)
        #expect(try fixture.read(.right, "deep/er/file.txt") == "z")
        try await service.restore(snapshots)
        #expect(!fixture.exists(.right, "deep"))
    }

    @Test func batchPlansSkipItemsInsideSelectedFolders() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "a/one.txt", "1")
        try fixture.write(.left, "a/two.txt", "2")
        try fixture.write(.left, "b.txt", "b")
        let nodes = try await scan(fixture)
        let selection = ["a", "a/one.txt", "b.txt"].compactMap { DiffTree.node(at: $0, in: nodes) }
        let plan = SyncPlanner.plan(for: selection, direction: .leftToRight, leftRoot: fixture.left, rightRoot: fixture.right)
        #expect(plan.fileCount == 3)
        #expect(plan.directoryCount == 1)
        #expect(plan.refreshPaths == ["a", "b.txt"])
    }

    @Test func copyKeepsExecutablePermission() async throws {
        let fixture = try FolderFixture()
        let script = try fixture.write(.left, "run.sh", "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        let nodes = try await scan(fixture)
        try await service.execute(SyncPlanner.plan(for: try #require(DiffTree.node(at: "run.sh", in: nodes)), direction: .leftToRight, leftRoot: fixture.left, rightRoot: fixture.right))
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url(.right, "run.sh").path(percentEncoded: false))
        #expect(attributes[.posixPermissions] as? Int == 0o755)
    }

    @Test func blockWriteRefusesStaleFiles() async throws {
        let fixture = try FolderFixture()
        let url = try fixture.write(.right, "a.txt", "one\ntwo\n")
        let original = TextDocument(text: "one\ntwo\n")
        let updated = TextDocument(text: "one\n2\n")
        try await service.write(updated, to: url, expecting: original)
        #expect(try fixture.read(.right, "a.txt") == "one\n2\n")
        await #expect(throws: FileOperationError.self) {
            try await service.write(updated, to: url, expecting: original)
        }
    }

    @Test func moveCreatesParentsAndRefusesToOverwrite() async throws {
        let fixture = try FolderFixture()
        let source = try fixture.write(.right, "old/name.txt", "n")
        try fixture.write(.right, "taken.txt", "t")
        let created = try await service.moveItem(from: source, to: fixture.url(.right, "new/place/name.txt"))
        #expect(created.map(\.lastPathComponent) == ["new", "place"])
        #expect(try fixture.read(.right, "new/place/name.txt") == "n")
        await #expect(throws: FileOperationError.self) {
            _ = try await service.moveItem(from: fixture.url(.right, "new/place/name.txt"), to: fixture.url(.right, "taken.txt"))
        }
    }
}

@Suite("Reports")
struct ReportTests {
    @Test func csvEscapesFields() {
        let data = ReportData(
            leftRoot: "/a", rightRoot: "/b", generated: .now, summary: DiffSummary(), options: DiffOptions(), respectsGitIgnore: true,
            items: [ReportItem(kind: .modified, path: "a,\"b\".txt", counterpartPath: nil, isDirectory: false, fileCount: 1, isExactMove: false, leftSize: 1, rightSize: 2)]
        )
        let csv = ReportBuilder.render(data, format: .csv)
        #expect(csv == "change,path,counterpart_path,is_folder,file_count,left_size,right_size\nmodified,\"a,\"\"b\"\".txt\",,false,1,1,2\n")
    }
}

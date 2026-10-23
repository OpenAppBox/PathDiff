//
//  StabilityTests.swift
//  PathDiffTests
//

import Darwin
import Foundation
import Testing

/// Regression tests for data-safety and robustness fixes: writes that must refuse rather
/// than destroy, partial failures that stay undoable, and damaged inputs that must not crash.
@Suite("Stability", .serialized)
struct StabilityTests {
    private let rules = ScanRules(matcher: IgnoreMatcher(patterns: IgnoreMatcher.defaultPatterns), respectsGitIgnore: false)
    private let service = FileManagerService()

    private func scan(_ fixture: FolderFixture) async throws -> [DiffNode] {
        try await FolderScanner(cacheDirectory: nil).scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions()).nodes
    }

    @MainActor
    private func makeWindow(_ fixture: FolderFixture) async throws -> (DiffViewModel, SyncHistory, UndoManager) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "PathDiffTests-\(UUID().uuidString)")!)
        settings.watchForChanges = false
        let history = SyncHistory(store: HistoryStore(directory: fixture.root.appending(path: "history")))
        let viewModel = DiffViewModel(settings: settings, scanner: FolderScanner(cacheDirectory: nil), history: history)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        viewModel.undoManager = undoManager
        viewModel.setFolder(fixture.left, for: .left)
        viewModel.setFolder(fixture.right, for: .right)
        try await waitUntil("scan") { viewModel.hasScanned && !viewModel.isScanning && !viewModel.isDetectingMoves }
        return (viewModel, history, undoManager)
    }

    // MARK: Writes that refuse

    /// A folder that appeared where a file was planned must not be deleted to make room.
    @Test func copyNeverReplacesAFolder() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "a.txt", "new\n")
        try fixture.write(.right, "a.txt", "old\n")
        let nodes = try await scan(fixture)
        let plan = SyncPlanner.plan(for: try #require(DiffTree.node(at: "a.txt", in: nodes)), direction: .leftToRight, leftRoot: fixture.left, rightRoot: fixture.right)

        try FileManager.default.removeItem(at: fixture.url(.right, "a.txt"))
        try fixture.write(.right, "a.txt/precious.txt", "keep\n")
        await #expect(throws: FileOperationError.self) { try await service.execute(plan) }
        #expect(try fixture.read(.right, "a.txt/precious.txt") == "keep\n")
    }

    /// A copy planned as a new file doesn't overwrite a file that appeared since.
    @Test func newFileCopyRefusesAFileThatAppeared() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "new.txt", "mine\n")
        let nodes = try await scan(fixture)
        let plan = SyncPlanner.plan(for: try #require(DiffTree.node(at: "new.txt", in: nodes)), direction: .leftToRight, leftRoot: fixture.left, rightRoot: fixture.right)

        try fixture.write(.right, "new.txt", "theirs\n")
        await #expect(throws: FileOperationError.self) { try await service.execute(plan) }
        #expect(try fixture.read(.right, "new.txt") == "theirs\n")
    }

    /// On a case-insensitive volume, "readme.md" → "README.md" finds the file itself at the
    /// destination; it must still be renamed.
    @Test func caseOnlyRenameWorks() async throws {
        let fixture = try FolderFixture()
        let source = try fixture.write(.right, "readme.md", "r\n")
        let caseSensitive = try fixture.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        guard caseSensitive == false else { return }
        _ = try await service.moveItem(from: source, to: fixture.url(.right, "README.md"))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.right.path(percentEncoded: false))
        #expect(names == ["README.md"])
        #expect(try fixture.read(.right, "README.md") == "r\n")
    }

    // MARK: Partial failures

    /// A copy that fails halfway keeps what it did undoable and in the history.
    @Test @MainActor func partiallyFailedCopyCanBeUndone() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "a.txt", "a\n")
        try fixture.write(.left, "b.txt", "b\n")
        let (viewModel, history, undoManager) = try await makeWindow(fixture)
        let nodes = ["a.txt", "b.txt"].compactMap { DiffTree.node(at: $0, in: viewModel.rootNodes) }
        #expect(nodes.count == 2)

        undoManager.beginUndoGrouping()
        viewModel.copy(nodes, direction: .leftToRight)
        try fixture.write(.right, "b.txt", "theirs\n")   // appears after planning: b's copy refuses
        try #require(viewModel.pendingConfirmation).action()
        try await waitUntil("copy") { !viewModel.isPerformingFileOperation && viewModel.alert != nil }
        undoManager.endUndoGrouping()
        #expect(try fixture.read(.right, "a.txt") == "a\n")
        #expect(try fixture.read(.right, "b.txt") == "theirs\n")
        try await waitUntil("history") { history.entries.first?.kind == .copy }

        undoManager.undo()
        try await waitUntil("undo") { !fixture.exists(.right, "a.txt") }
        #expect(try fixture.read(.right, "b.txt") == "theirs\n")
    }

    // MARK: History

    /// Entries written without fields added later still load, and one unreadable entry
    /// doesn't cost the others.
    @Test func historyIndexToleratesOldAndUnknownEntries() async throws {
        let fixture = try FolderFixture()
        let directory = fixture.root.appending(path: "history")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = """
        [
          {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "date": "2026-10-01T10:00:00Z", "kind": "copy",
           "title": "Copy", "leftRoot": "/a", "rightRoot": "/b", "items": []},
          {"id": "7F9619FF-8B86-D011-B42D-00C04FC964FF", "date": "2026-10-02T10:00:00Z", "kind": "somethingNewer",
           "title": "From a newer version", "leftRoot": "/a", "rightRoot": "/b", "items": []}
        ]
        """
        try Data(index.utf8).write(to: directory.appending(path: "index.json"))
        let entries = await HistoryStore(directory: directory).entries()
        #expect(entries.map(\.title) == ["Copy"])
        #expect(entries.first?.state == .applied)
        #expect(entries.first?.hasBackup == false)
    }

    @Test func damagedHistoryIndexIsKeptAside() async throws {
        let fixture = try FolderFixture()
        let directory = fixture.root.appending(path: "history")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: directory.appending(path: "index.json"))
        let entries = await HistoryStore(directory: directory).entries()
        #expect(entries.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(names.contains { $0.hasPrefix("index-damaged-") })
        #expect(!names.contains("index.json"))
    }

    // MARK: Sync planning

    /// A folder that couldn't be read looks empty; its counterpart's contents must not be
    /// planned as extras to trash.
    @Test func syncSkipsWhatCouldNotBeRead() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "secret/.keep", "")
        try fixture.write(.right, "secret/x.txt", "x\n")
        try fixture.write(.right, "secret/.keep", "")
        try fixture.write(.right, "extra.txt", "e\n")
        let nodes = try await scan(fixture)
        var options = BatchSyncOptions()
        options.deleteExtras = true

        let plan = BatchSyncPlanner.plan(scope: nil, tree: nodes, moves: MoveMap(), options: options, leftRoot: fixture.left, rightRoot: fixture.right, unreadable: ["secret"])
        #expect(plan.operations.map(\.path) == ["extra.txt"])
        #expect(plan.skipped.map(\.path) == ["secret/x.txt"])
    }

    // MARK: Editing

    /// Saving an edit in a file with mixed line endings changes only the edited line.
    @Test func mixedLineEndingsSurviveAnEdit() throws {
        let original = try #require(TextDocument.decode(Data("a\r\nb\nc\nd\n".utf8)))
        let edited = original.replacingText("a\nb\nc\nD\n")
        #expect(try edited.encodedData() == Data("a\r\nb\nc\nD\n".utf8))
    }

    // MARK: Damaged and unusual input

    /// An index-v4 path prefix with endless continuation bytes is rejected, not a crash.
    @Test func damagedGitIndexIsRejected() {
        var data = Data("DIRC".utf8)
        data.append(contentsOf: [0, 0, 0, 4, 0, 0, 0, 1])          // version 4, one entry
        data.append(contentsOf: [UInt8](repeating: 0, count: 62))   // stat data, object ID, flags
        data.append(contentsOf: [UInt8](repeating: 0xFF, count: 12)) // path prefix varint
        data.append(contentsOf: Array("a\0".utf8))
        #expect(GitIndex.parse(data, hashLength: 20) == nil)
    }

    /// Named pipes are left out: reading one to compare it would block forever.
    @Test func namedPipesDontHangTheScan() async throws {
        let fixture = try FolderFixture()
        try fixture.writeBoth("file.txt", "f\n")
        for side in [FixtureSide.left, .right] {
            #expect(mkfifo(fixture.url(side, "pipe").path(percentEncoded: false), 0o644) == 0)
        }
        let nodes = try await scan(fixture)
        #expect(DiffTree.node(at: "pipe", in: nodes) == nil)
        #expect(DiffTree.node(at: "file.txt", in: nodes)?.status == .identical)
    }
}

//
//  BatchSyncTests.swift
//  PathDiffTests
//

import Foundation
import SwiftUI
import Testing

@Suite("Batch sync", .serialized)
struct BatchSyncTests {
    private let rules = ScanRules(matcher: IgnoreMatcher(patterns: IgnoreMatcher.defaultPatterns), respectsGitIgnore: false)

    /// Every file under a folder with its contents, to compare whole trees.
    private func contents(of root: URL) -> [String: String] {
        var result: [String: String] = [:]
        let rootPath = root.path(percentEncoded: false)
        for relative in (try? FileManager.default.subpathsOfDirectory(atPath: rootPath)) ?? [] {
            let url = root.appending(path: relative)
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                result[relative + "/"] = ""
            } else {
                result[relative] = (try? String(contentsOf: url, encoding: .utf8)) ?? "<binary>"
            }
        }
        return result
    }

    private func makeFixture() throws -> FolderFixture {
        let fixture = try FolderFixture()
        try fixture.writeBoth("same.txt", "same\n")
        try fixture.write(.left, "modified.txt", "new\n")
        try fixture.write(.right, "modified.txt", "old\n")
        try fixture.write(.left, "missing/deep/file.txt", "m\n")
        try fixture.write(.right, "extra/stuff.txt", "x\n")
        try fixture.write(.right, "extra.log.txt", "y\n")
        for index in 0..<3 {
            let text = "module \(index)\n" + String(repeating: "body\n", count: index + 2)
            try fixture.write(.left, "lib/renamed/m\(index).ts", text)
            try fixture.write(.right, "lib/original/m\(index).ts", text)
        }
        let body = (0..<20).map { "line \($0)\n" }.joined()
        try fixture.write(.left, "a/Widget.swift", body.replacingOccurrences(of: "line 2\n", with: "line two\n"))
        try fixture.write(.right, "b/Widget.swift", body)
        return fixture
    }

    private func scan(_ fixture: FolderFixture) async throws -> (nodes: [DiffNode], moves: MoveMap) {
        let scanner = FolderScanner(cacheDirectory: nil)
        let nodes = try await scanner.scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions()).nodes
        return (nodes, try await scanner.detectMoves(in: nodes))
    }

    @Test func dryRunListsOperationsWithoutTouchingFiles() async throws {
        let fixture = try makeFixture()
        let before = contents(of: fixture.right)
        let (nodes, moves) = try await scan(fixture)
        var options = BatchSyncOptions()
        options.deleteExtras = true
        let plan = BatchSyncPlanner.plan(scope: nil, tree: nodes, moves: moves, options: options, leftRoot: fixture.left, rightRoot: fixture.right)

        let renames = plan.operations(of: .rename)
        #expect(Set(renames.map(\.path)) == ["lib/renamed", "a/Widget.swift"])
        #expect(renames.first { $0.path == "lib/renamed" }?.previousPath == "lib/original")
        let copies = plan.operations(of: .copy).map(\.path)
        #expect(Set(copies) == ["modified.txt", "missing", "a/Widget.swift"], "the edited moved file also gets its new contents")
        #expect(Set(plan.operations(of: .trash).map(\.path)) == ["extra", "extra.log.txt", "b"], "b/ is empty once Widget.swift is renamed out")
        #expect(contents(of: fixture.right) == before, "planning is a dry run")

        let text = BatchSyncPlanner.describe(plan, excluding: [], options: options, leftName: "main", rightName: "other")
        #expect(text.contains("RENAME  lib/original/ → lib/renamed/ (3 files)"))
        #expect(text.contains("TRASH   extra/ (1 files)"))
    }

    @Test func mirrorMakesTreesIdenticalAndRevertRestoresEverything() async throws {
        let fixture = try makeFixture()
        let original = contents(of: fixture.right)
        let (nodes, moves) = try await scan(fixture)
        var options = BatchSyncOptions()
        options.deleteExtras = true
        let plan = BatchSyncPlanner.plan(scope: nil, tree: nodes, moves: moves, options: options, leftRoot: fixture.left, rightRoot: fixture.right)

        let service = FileManagerService()
        let (record, error) = await service.execute(plan, excluding: []) { _ in }
        #expect(error == nil)
        #expect(record.completedOperations == plan.operations.count)
        #expect(contents(of: fixture.right) == contents(of: fixture.left))

        try await service.revert(record)
        #expect(contents(of: fixture.right) == original)
    }

    @Test func excludedOperationsAndScopeAreRespected() async throws {
        let fixture = try makeFixture()
        let (nodes, moves) = try await scan(fixture)
        let missing = try #require(DiffTree.node(at: "missing", in: nodes))
        let plan = BatchSyncPlanner.plan(scope: [missing], tree: nodes, moves: moves, options: BatchSyncOptions(), leftRoot: fixture.left, rightRoot: fixture.right)
        #expect(plan.operations.map(\.path) == ["missing"])

        let everything = BatchSyncPlanner.plan(scope: nil, tree: nodes, moves: moves, options: BatchSyncOptions(), leftRoot: fixture.left, rightRoot: fixture.right)
        let skipped = Set(everything.operations.filter { $0.path != "modified.txt" }.map(\.id))
        _ = await FileManagerService().execute(everything, excluding: skipped) { _ in }
        #expect(try fixture.read(.right, "modified.txt") == "new\n")
        #expect(!fixture.exists(.right, "missing"))
        #expect(fixture.exists(.right, "lib/original/m0.ts"))
    }

    @Test func rightToLeftCopiesTheOtherWay() async throws {
        let fixture = try makeFixture()
        let (nodes, moves) = try await scan(fixture)
        var options = BatchSyncOptions()
        options.direction = .rightToLeft
        options.applyMoves = false
        let plan = BatchSyncPlanner.plan(scope: nil, tree: nodes, moves: moves, options: options, leftRoot: fixture.left, rightRoot: fixture.right)
        #expect(plan.operations(of: .rename).isEmpty)
        #expect(plan.operations(of: .trash).isEmpty, "extras are only trashed when asked")
        _ = await FileManagerService().execute(plan, excluding: []) { _ in }
        #expect(try fixture.read(.left, "modified.txt") == "old\n")
        #expect(try fixture.read(.left, "extra/stuff.txt") == "x\n")
        #expect(fixture.exists(.left, "missing/deep/file.txt"), "nothing is deleted without the mirror option")
    }

    // MARK: Merge both ways

    /// Two backup drives that each have something the other lacks, with edits on both.
    private func makeBackupFixture() throws -> FolderFixture {
        let fixture = try FolderFixture()
        let old = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let new = old.addingTimeInterval(86_400)
        func write(_ side: FixtureSide, _ path: String, _ text: String, _ date: Date) throws {
            try fixture.write(side, path, text)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.url(side, path).path(percentEncoded: false))
        }
        try fixture.writeBoth("Photos/same.jpg", "same")
        try write(.left, "Photos/only-on-a.jpg", "a", old)
        try write(.right, "Videos/2024/only-on-b.mov", "b", old)
        try write(.left, "Photos/edited-on-a.jpg", "edited", new)
        try write(.right, "Photos/edited-on-a.jpg", "original", old)
        try write(.left, "Photos/edited-on-b.jpg", "original", old)
        try write(.right, "Photos/edited-on-b.jpg", "edited", new)
        try write(.left, "Photos/conflict.jpg", "one", old)
        try write(.right, "Photos/conflict.jpg", "two", old.addingTimeInterval(1))
        try write(.left, "Old Album/moved.jpg", "moved contents", old)
        try write(.right, "New Album/moved.jpg", "moved contents", old)
        return fixture
    }

    @Test func mergeFillsBothSidesAndKeepsTheNewerCopy() async throws {
        let fixture = try makeBackupFixture()
        let originalLeft = contents(of: fixture.left)
        let originalRight = contents(of: fixture.right)
        let (nodes, moves) = try await scan(fixture)
        #expect(moves.byLeftPath["Old Album/moved.jpg"] != nil)
        var options = BatchSyncOptions()
        options.mode = .merge
        let plan = BatchSyncPlanner.plan(scope: nil, tree: nodes, moves: moves, options: options, leftRoot: fixture.left, rightRoot: fixture.right)

        #expect(plan.operations(of: .rename).isEmpty)
        #expect(plan.operations(of: .trash).isEmpty, "a merge never deletes")
        let copies = Dictionary(uniqueKeysWithValues: plan.operations(of: .copy).map { ($0.path, $0.destination) })
        #expect(copies["Photos/only-on-a.jpg"] == .right)
        #expect(copies["Videos"] == .left, "a folder missing on one side is copied as a whole")
        #expect(copies["Photos/edited-on-a.jpg"] == .right)
        #expect(copies["Photos/edited-on-b.jpg"] == .left)
        #expect(copies["Photos/conflict.jpg"] == nil)
        #expect(plan.skipped.map(\.path) == ["Photos/conflict.jpg"], "edits made about the same time need a decision")
        #expect(copies.keys.allSatisfy { !$0.contains("Album") }, "moved items stay where they are")

        let text = BatchSyncPlanner.describe(plan, excluding: [], options: options, leftName: "A", rightName: "B")
        #expect(text.hasPrefix("Merge A ⇄ B (dry run)"))
        #expect(text.contains("UPDATE  Photos/edited-on-b.jpg  → A"))

        let (record, error) = await FileManagerService().execute(plan, excluding: []) { _ in }
        #expect(error == nil)
        #expect(try fixture.read(.right, "Photos/only-on-a.jpg") == "a")
        #expect(try fixture.read(.left, "Videos/2024/only-on-b.mov") == "b")
        #expect(try fixture.read(.right, "Photos/edited-on-a.jpg") == "edited")
        #expect(try fixture.read(.left, "Photos/edited-on-b.jpg") == "edited")
        #expect(try fixture.read(.left, "Photos/conflict.jpg") == "one")
        #expect(try fixture.read(.right, "Photos/conflict.jpg") == "two")
        #expect(!fixture.exists(.right, "Old Album/moved.jpg"))

        try await FileManagerService().revert(record)
        #expect(contents(of: fixture.left) == originalLeft)
        #expect(contents(of: fixture.right) == originalRight)
    }

    @Test func mergeOptionsAndScopeNarrowThePlan() async throws {
        let fixture = try makeBackupFixture()
        let (nodes, moves) = try await scan(fixture)
        var options = BatchSyncOptions()
        options.mode = .merge
        options.copyModified = false
        let missingOnly = BatchSyncPlanner.plan(scope: nil, tree: nodes, moves: moves, options: options, leftRoot: fixture.left, rightRoot: fixture.right)
        #expect(missingOnly.operations.allSatisfy { !$0.overwrites })
        #expect(missingOnly.skipped.isEmpty)

        options.copyModified = true
        let photos = try #require(DiffTree.node(at: "Photos", in: nodes))
        let scoped = BatchSyncPlanner.plan(scope: [photos], tree: nodes, moves: moves, options: options, leftRoot: fixture.left, rightRoot: fixture.right)
        #expect(scoped.operations.allSatisfy { $0.path.hasPrefix("Photos/") })
        #expect(Set(scoped.operations.map(\.destination)) == [.left, .right])
    }

    @Test func mergeFromTheWindowIsOneHistoryEntryAndUndoable() async throws {
        let fixture = try makeBackupFixture()
        let originalLeft = contents(of: fixture.left)
        let originalRight = contents(of: fixture.right)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "PathDiffTests-\(UUID().uuidString)")!)
        settings.watchForChanges = false
        let history = SyncHistory(store: HistoryStore(directory: fixture.root.appending(path: "history")))
        let viewModel = DiffViewModel(settings: settings, scanner: FolderScanner(cacheDirectory: nil), history: history)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        viewModel.undoManager = undoManager
        viewModel.setFolder(fixture.left, for: .left)
        viewModel.setFolder(fixture.right, for: .right)
        try await waitUntil("scan") { viewModel.hasScanned && !viewModel.isScanning && !viewModel.isDetectingMoves && viewModel.summary.moved > 0 }

        viewModel.beginBatchSync()
        viewModel.updateBatchSync { $0.options.mode = .merge }
        undoManager.beginUndoGrouping()
        viewModel.runBatchSync()
        try await waitUntil("merge") { viewModel.batchSync == nil && !viewModel.isPerformingFileOperation }
        undoManager.endUndoGrouping()

        let entry = try #require(history.entries.first)
        #expect(entry.title.hasPrefix("Merge "))
        #expect(entry.direction == nil)
        #expect(Set(entry.items.map(\.side)) == [.left, .right])
        try await waitUntil("refresh") { viewModel.summary.modified == 1 && viewModel.summary.leftOnly == 0 && viewModel.summary.rightOnly == 0 }

        undoManager.undo()
        try await waitUntil("undo") {
            !viewModel.isPerformingFileOperation && contents(of: fixture.left) == originalLeft && contents(of: fixture.right) == originalRight
        }
    }

    @Test func syncFromTheWindowCanBeUndone() async throws {
        let fixture = try makeFixture()
        let original = contents(of: fixture.right)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "PathDiffTests-\(UUID().uuidString)")!)
        settings.watchForChanges = false
        let viewModel = DiffViewModel(settings: settings, scanner: FolderScanner(cacheDirectory: nil))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        viewModel.undoManager = undoManager
        viewModel.setFolder(fixture.left, for: .left)
        viewModel.setFolder(fixture.right, for: .right)
        try await waitUntil("scan") { viewModel.hasScanned && !viewModel.isScanning && !viewModel.isDetectingMoves && viewModel.summary.moved > 0 }

        viewModel.beginBatchSync()
        viewModel.updateBatchSync { $0.options.deleteExtras = true }
        #expect(viewModel.batchSync?.scopeIDs == nil)
        undoManager.beginUndoGrouping()
        viewModel.runBatchSync()
        try await waitUntil("sync") { viewModel.batchSync == nil && !viewModel.isPerformingFileOperation }
        undoManager.endUndoGrouping()
        try await waitUntil("refresh") { viewModel.summary.differences == 0 }

        undoManager.undo()
        try await waitUntil("undo") { !viewModel.isPerformingFileOperation && contents(of: fixture.right) == original }
        try await waitUntil("refresh after undo") { viewModel.summary.differences > 0 }
    }
}

@Suite("Sync sheet")
struct BatchSyncSheetTests {
    /// Regression: Cancel cleared the session while the sheet's controls still read their
    /// bindings during the dismissal animation, which force-unwrapped `nil` and crashed.
    @Test func controlsStayReadableAfterCancel() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "a.txt", "1")
        let settings = AppSettings(defaults: UserDefaults(suiteName: "PathDiffTests-\(UUID().uuidString)")!)
        settings.watchForChanges = false
        let viewModel = DiffViewModel(settings: settings, scanner: FolderScanner(cacheDirectory: nil))
        viewModel.setFolder(fixture.left, for: .left)
        viewModel.setFolder(fixture.right, for: .right)
        try await waitUntil("scan") { viewModel.hasScanned && !viewModel.isScanning }

        viewModel.beginBatchSync()
        let session = try #require(viewModel.batchSync)
        let direction = BatchSyncSheet.sessionBinding(viewModel, \.options.direction, fallback: session)
        let mirror = BatchSyncSheet.sessionBinding(viewModel, \.options.deleteExtras, fallback: session)
        direction.wrappedValue = .rightToLeft
        #expect(viewModel.batchSync?.options.direction == .rightToLeft)

        viewModel.cancelBatchSync()
        #expect(viewModel.batchSync == nil)
        #expect(direction.wrappedValue == .leftToRight, "falls back to the last shown value instead of crashing")
        #expect(mirror.wrappedValue == false)
        mirror.wrappedValue = true   // writes after dismissal are ignored
        #expect(viewModel.batchSync == nil)
    }
}

@Suite("Unified layout")
struct UnifiedLayoutTests {
    @Test func listsRemovedLinesBeforeAddedLines() {
        let diff = DiffEngine.makeTextDiff(
            left: TextDocument(text: "a\nb\nc\nd\n"),
            right: TextDocument(text: "a\nB\nC\nd\n"),
            options: DiffOptions()
        )
        let items = DiffViewModel.unifiedItems(from: (0..<diff.lines.count).map(DiffDisplayItem.line), diff: diff)
        let rendered = items.map { item -> String in
            guard case .unified(let row, let part) = item else { return "fold" }
            let line = diff.lines[row]
            switch part {
            case .context: return " " + (line.leftContent ?? "")
            case .removed: return "-" + (line.leftContent ?? "")
            case .added: return "+" + (line.rightContent ?? "")
            }
        }
        #expect(rendered == [" a", "-b", "-c", "+B", "+C", " d"])
        #expect(Set(items.map(\.id)).count == items.count)
    }
}

//
//  HistoryAndEditingTests.swift
//  PathDiffTests
//

import AppKit
import Foundation
import Testing

/// A comparison window wired to a private history store in the fixture folder.
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

private func contents(of root: URL) -> [String: String] {
    var result: [String: String] = [:]
    for relative in (try? FileManager.default.subpathsOfDirectory(atPath: root.path(percentEncoded: false))) ?? [] {
        let url = root.appending(path: relative)
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            result[relative + "/"] = ""
        } else {
            result[relative] = (try? String(contentsOf: url, encoding: .utf8)) ?? "<binary>"
        }
    }
    return result
}

@Suite("Sync history", .serialized)
struct SyncHistoryTests {
    @Test func copyIsRecordedPersistedAndRevertedAfterRelaunch() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "a.txt", "new\n")
        try fixture.write(.right, "a.txt", "old\n")
        try fixture.write(.left, "b.txt", "added\n")
        let (viewModel, history, _) = try await makeWindow(fixture)

        let nodes = ["a.txt", "b.txt"].compactMap { DiffTree.node(at: $0, in: viewModel.rootNodes) }
        viewModel.copy(nodes, direction: .leftToRight)
        try #require(viewModel.pendingConfirmation).action()
        try await waitUntil("copy") { !viewModel.isPerformingFileOperation && viewModel.summary.differences == 0 }
        await history.flush()

        let entry = try #require(history.entries.first)
        #expect(entry.kind == .copy && entry.direction == .leftToRight && entry.hasBackup)
        #expect(Set(entry.items.map { "\($0.action.rawValue) \($0.path)" }) == ["updated a.txt", "added b.txt"])

        // A new store instance (as after relaunch) reads the same history and can revert it.
        let relaunched = SyncHistory(store: HistoryStore(directory: fixture.root.appending(path: "history")))
        await relaunched.reload()
        let stored = try #require(relaunched.entries.first { $0.id == entry.id })
        let preview = try await relaunched.previewRevert(stored)
        #expect(preview.changedSince.isEmpty)
        try await relaunched.revert(stored)
        #expect(try fixture.read(.right, "a.txt") == "old\n")
        #expect(!fixture.exists(.right, "b.txt"))
        #expect(relaunched.entries.first?.kind == .revert)
        #expect(relaunched.entries.first { $0.id == entry.id }?.state == .reverted)

        // The revert itself can be reverted.
        let revertEntry = try #require(relaunched.entries.first)
        await relaunched.flush()
        try await relaunched.revert(relaunched.entries.first { $0.id == revertEntry.id }!)
        #expect(try fixture.read(.right, "a.txt") == "new\n")
        #expect(try fixture.read(.right, "b.txt") == "added\n")
    }

    @Test func revertPreviewListsFilesChangedSince() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "a.txt", "new\n")
        try fixture.write(.right, "a.txt", "old\n")
        let (viewModel, history, _) = try await makeWindow(fixture)
        viewModel.copy(try #require(DiffTree.node(at: "a.txt", in: viewModel.rootNodes)), direction: .leftToRight)
        try await waitUntil("copy") { !viewModel.isPerformingFileOperation && viewModel.summary.differences == 0 }
        await history.flush()

        try fixture.write(.right, "a.txt", "edited later, longer\n")
        let preview = try await history.previewRevert(try #require(history.entries.first))
        #expect(preview.changedSince == ["other/a.txt"])
    }

    @Test func undoAndRedoUpdateTheEntry() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "a.txt", "new\n")
        try fixture.write(.right, "a.txt", "old\n")
        let (viewModel, history, undoManager) = try await makeWindow(fixture)
        undoManager.beginUndoGrouping()
        viewModel.copy(try #require(DiffTree.node(at: "a.txt", in: viewModel.rootNodes)), direction: .leftToRight)
        try await waitUntil("copy") { !viewModel.isPerformingFileOperation && viewModel.summary.differences == 0 }
        undoManager.endUndoGrouping()
        let id = try #require(history.entries.first?.id)

        undoManager.undo()
        try await waitUntil("undo") { history.entries.first { $0.id == id }?.state == .undone }
        #expect(try fixture.read(.right, "a.txt") == "old\n")
        #expect(history.entries.first { $0.id == id }?.canRevert == false)
        undoManager.redo()
        try await waitUntil("redo") { history.entries.first { $0.id == id }?.state == .applied }
    }

    @Test func mirrorSyncWithRenamesAndTrashRevertsFromHistory() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "modified.txt", "new\n")
        try fixture.write(.right, "modified.txt", "old\n")
        try fixture.write(.right, "extra/stuff.txt", "x\n")
        for index in 0..<3 {
            let text = "module \(index)\n" + String(repeating: "body\n", count: index + 2)
            try fixture.write(.left, "lib/renamed/m\(index).ts", text)
            try fixture.write(.right, "lib/original/m\(index).ts", text)
        }
        let original = contents(of: fixture.right)
        let (viewModel, history, _) = try await makeWindow(fixture)
        try await waitUntil("moves") { viewModel.summary.moved > 0 }

        viewModel.beginBatchSync()
        viewModel.updateBatchSync { $0.options.deleteExtras = true }
        viewModel.runBatchSync()
        try await waitUntil("sync") { viewModel.batchSync == nil && !viewModel.isPerformingFileOperation }
        #expect(contents(of: fixture.right) == contents(of: fixture.left))
        await history.flush()

        let entry = try #require(history.entries.first)
        #expect(entry.kind == .sync && entry.hasBackup)
        #expect(Set(entry.items.map(\.action)) == [.renamed, .updated, .trashed])
        try await history.revert(entry)
        #expect(contents(of: fixture.right) == original, "renames, updates and trashed items are all restored")
    }

    @Test func trashIsUndoableAndRecorded() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.right, "junk/a.txt", "a\n")
        try fixture.write(.right, "junk/sub/b.txt", "b\n")
        let (viewModel, history, undoManager) = try await makeWindow(fixture)
        undoManager.beginUndoGrouping()
        viewModel.moveToTrash(try #require(DiffTree.node(at: "junk", in: viewModel.rootNodes)), side: .right)
        try #require(viewModel.pendingConfirmation).action()
        try await waitUntil("trash") { !viewModel.isPerformingFileOperation && !fixture.exists(.right, "junk") }
        undoManager.endUndoGrouping()
        #expect(history.entries.first?.kind == .trash)
        #expect(history.entries.first?.items.first?.action == .trashed)

        undoManager.undo()
        try await waitUntil("undo trash") { fixture.exists(.right, "junk/sub/b.txt") }
        #expect(try fixture.read(.right, "junk/a.txt") == "a\n")
    }
}

@Suite("Editing in the diff view", .serialized)
struct EditingTests {
    @Test func editorTextKeepsLineEndingsEncodingAndBOM() throws {
        let original = try #require(TextDocument.decode(Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb\r\n".utf8)))
        #expect(original.editorText == "a\nb\n")
        let edited = original.replacingText("a\nB\nc")
        #expect(try edited.encodedData() == Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nB\r\nc".utf8))
    }

    @Test func editAnalyzeAndSave() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "code.swift", "let a = 1\r\nlet b = 2\r\n")
        try fixture.write(.right, "code.swift", "let a = 1\r\nlet b = 3\r\n")
        let (viewModel, history, _) = try await makeWindow(fixture)
        viewModel.select(nodeID: "code.swift")
        try await waitUntil("diff") { viewModel.textDiff != nil }

        viewModel.beginEditing()
        let session = try #require(viewModel.editSession)
        #expect(session.rightText == "let a = 1\nlet b = 3\n")
        try await waitUntil("analysis") { viewModel.editSession?.analysis.changeCount == 1 }
        #expect(viewModel.editSession?.analysis.rightChangedLines == [1])
        #expect(viewModel.editSession?.analysis.rightSyntax != nil)

        viewModel.updateEditedText("let a = 1\nlet b = 2\n", side: .right)
        #expect(viewModel.editSession?.isDirty == true)
        try await waitUntil("analysis after edit") { viewModel.editSession?.analysis.changeCount == 0 }

        viewModel.saveEdits()
        try await waitUntil("save") { viewModel.editSession?.isDirty == false && !viewModel.isPerformingFileOperation }
        #expect(try fixture.read(.right, "code.swift") == "let a = 1\r\nlet b = 2\r\n", "line endings are kept")
        #expect(history.entries.first?.kind == .edit)
        try await waitUntil("tree refresh") { viewModel.summary.differences == 0 }
    }

    @Test func saveRefusesExternalChangesUntilConfirmed() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "a.txt", "one\n")
        try fixture.write(.right, "a.txt", "two\n")
        let (viewModel, _, _) = try await makeWindow(fixture)
        viewModel.select(nodeID: "a.txt")
        try await waitUntil("diff") { viewModel.textDiff != nil }
        viewModel.beginEditing()
        viewModel.updateEditedText("mine\n", side: .right)

        try fixture.write(.right, "a.txt", "someone else\n")
        viewModel.saveEdits()
        try await waitUntil("conflict") { viewModel.pendingConfirmation != nil && viewModel.editSession?.isSaving == false }
        #expect(try fixture.read(.right, "a.txt") == "someone else\n", "nothing written yet")

        try #require(viewModel.pendingConfirmation).action()
        try await waitUntil("forced save") { viewModel.editSession?.isDirty == false }
        #expect(try fixture.read(.right, "a.txt") == "mine\n")
    }

    @Test func leavingWithUnsavedEditsAsks() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "a.txt", "1\n")
        try fixture.write(.right, "a.txt", "2\n")
        try fixture.write(.left, "b.txt", "x\n")
        let (viewModel, _, _) = try await makeWindow(fixture)
        viewModel.select(nodeID: "a.txt")
        try await waitUntil("diff") { viewModel.textDiff != nil }
        viewModel.beginEditing()
        viewModel.updateEditedText("changed\n", side: .left)

        viewModel.select(nodeID: "b.txt")
        #expect(viewModel.selectedNode?.id == "a.txt", "selection waits for a decision")
        let request = try #require(viewModel.editGuard)
        #expect(DiffViewModel.hasUnsavedEdits)

        request.onDiscard()
        #expect(viewModel.editSession == nil)
        #expect(viewModel.selectedNode?.id == "b.txt")
        #expect(try fixture.read(.left, "a.txt") == "1\n", "discarding writes nothing")
    }
}

@Suite("Settings")
struct SettingsTests {
    @Test func appearanceDefaultsToSystemAndPersists() {
        let defaults = UserDefaults(suiteName: "PathDiffTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.appearance == .system)
        #expect(AppAppearance.system.nsAppearance == nil)
        #expect(AppAppearance.dark.nsAppearance?.name == .darkAqua)
        defaults.set(AppAppearance.light.rawValue, forKey: "appearance")
        #expect(AppSettings(defaults: defaults).appearance == .light)
    }

    @Test func newDefaultIgnorePatternsReachCustomizedLists() {
        let defaults = UserDefaults(suiteName: "PathDiffTests-\(UUID().uuidString)")!
        #expect(AppSettings(defaults: defaults).ignorePatterns.contains(".claude"), "fresh installs get the defaults")

        let customized = UserDefaults(suiteName: "PathDiffTests-\(UUID().uuidString)")!
        customized.set(["node_modules", "my-own"], forKey: "ignorePatterns")
        let migrated = AppSettings(defaults: customized).ignorePatterns
        #expect(migrated == ["node_modules", "my-own", ".claude", ".trae", "npm-cache"] + IgnoreMatcher.patternsAddedInRevision[3]!)

        // Removing one afterwards sticks: the migration only runs once.
        customized.set(["node_modules", "my-own", ".claude"], forKey: "ignorePatterns")
        #expect(AppSettings(defaults: customized).ignorePatterns == ["node_modules", "my-own", ".claude"])
    }

    @Test func newPatternsAreIgnored() {
        let matcher = IgnoreMatcher(patterns: IgnoreMatcher.defaultPatterns)
        for name in [".claude", ".trae", "npm-cache"] {
            #expect(matcher.isIgnored(name: name, relativePath: "project/\(name)", isDirectory: true))
        }
    }
}

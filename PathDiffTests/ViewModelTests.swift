//
//  ViewModelTests.swift
//  PathDiffTests
//

import AppKit
import Foundation
import Testing

@Suite("Comparison window behavior", .serialized)
struct ViewModelTests {
    /// A view model with private settings, no file watching and no persisted cache.
    private func makeViewModel(watching: Bool = false) -> (DiffViewModel, UndoManager) {
        let defaults = UserDefaults(suiteName: "PathDiffTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.watchForChanges = watching
        let viewModel = DiffViewModel(settings: settings, scanner: FolderScanner(cacheDirectory: nil))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        viewModel.undoManager = undoManager
        return (viewModel, undoManager)
    }

    private func open(_ fixture: FolderFixture, in viewModel: DiffViewModel) async throws {
        viewModel.setFolder(fixture.left, for: .left)
        viewModel.setFolder(fixture.right, for: .right)
        try await waitUntil("scan") { viewModel.hasScanned && !viewModel.isScanning }
        try await waitUntil("move detection") { !viewModel.isDetectingMoves }
    }

    private func sections(_ viewModel: DiffViewModel) -> [ChangeKind: [String]] {
        Dictionary(uniqueKeysWithValues: viewModel.changeSections.map { ($0.kind, $0.rows.map(\.id)) })
    }

    private func makeRepositoryLikeFixture() throws -> FolderFixture {
        let fixture = try FolderFixture()
        try fixture.writeBoth(".gitignore", "out/\n")
        try fixture.writeBoth("README.md", "same\n")
        try fixture.write(.left, "out/a.js", "1")
        try fixture.write(.right, "out/b.js", "2")
        try fixture.write(.left, "src/app.swift", "let a = 1\n")
        try fixture.write(.right, "src/app.swift", "let a = 2\n")
        try fixture.write(.left, "src/missing.swift", "gone\n")
        for index in 0..<5 { try fixture.write(.right, "extra/deep/f\(index).txt", "x\(index)\n") }
        for index in 0..<4 {
            let text = "content of \(index)\n" + String(repeating: "line\n", count: index + 1)
            try fixture.write(.left, "lib/old/m\(index).ts", text)
            try fixture.write(.right, "lib/new/m\(index).ts", text)
        }
        let body = (0..<20).map { "line \($0)\n" }.joined()
        try fixture.write(.left, "a/Widget.swift", body)
        try fixture.write(.right, "b/Widget.swift", body.replacingOccurrences(of: "line 3\n", with: "line three\n"))
        return fixture
    }

    @Test func groupsChangesAndCollapsesOneSidedFolders() async throws {
        let fixture = try makeRepositoryLikeFixture()
        let (viewModel, _) = makeViewModel()
        try await open(fixture, in: viewModel)
        try await waitUntil("moves") { viewModel.summary.moved == 5 }

        #expect(viewModel.summary.modified == 1 && viewModel.summary.leftOnly == 1 && viewModel.summary.rightOnly == 5)
        let grouped = sections(viewModel)
        #expect(grouped[.modified] == ["src/app.swift"])
        #expect(grouped[.moved] == ["a", "lib/old"])
        #expect(grouped[.leftOnly] == ["src/missing.swift"])
        #expect(grouped[.rightOnly] == ["extra"])
        #expect(viewModel.changeSections.first { $0.kind == .rightOnly }?.rows.first?.fileCount == 5)
    }

    @Test func filtersAndSearch() async throws {
        let fixture = try makeRepositoryLikeFixture()
        let (viewModel, _) = makeViewModel()
        try await open(fixture, in: viewModel)
        try await waitUntil("moves") { viewModel.summary.moved == 5 }

        viewModel.kindFilter = [.rightOnly]
        #expect(viewModel.changeSections.map(\.kind) == [.rightOnly])
        #expect(viewModel.sidebarRows.map(\.id) == ["extra"], "one-sided folders stay collapsed")
        viewModel.toggleKindFilter(.rightOnly)
        #expect(!viewModel.isKindFilterActive)

        viewModel.searchText = "f3"
        try await waitUntil("search") { sections(viewModel) == [.rightOnly: ["extra/deep/f3.txt"]] }
        viewModel.searchText = "widget"
        try await waitUntil("search") { sections(viewModel) == [.moved: ["a/Widget.swift"]] }
    }

    @Test func movedFileIsComparedWithItsCounterpart() async throws {
        let fixture = try makeRepositoryLikeFixture()
        let (viewModel, _) = makeViewModel()
        try await open(fixture, in: viewModel)
        try await waitUntil("moves") { viewModel.summary.moved == 5 }

        viewModel.select(nodeID: "a/Widget.swift")
        try await waitUntil("diff") { viewModel.textDiff != nil }
        #expect(viewModel.activeDiffNode?.rightURL?.lastPathComponent == "Widget.swift")
        #expect(viewModel.activeDiffNode?.rightURL?.deletingLastPathComponent().lastPathComponent == "b")
        #expect(viewModel.textDiff?.hunks.count == 1)
    }

    @Test func applyMoveUndoAndRedo() async throws {
        let fixture = try makeRepositoryLikeFixture()
        let (viewModel, undoManager) = makeViewModel()
        try await open(fixture, in: viewModel)
        try await waitUntil("moves") { viewModel.summary.moved == 5 }
        let folderMove = try #require(viewModel.moves.byLeftPath["lib/old"])

        undoManager.beginUndoGrouping()
        viewModel.applyMove(folderMove, on: .right)
        try await waitUntil("move applied") {
            !viewModel.isPerformingFileOperation && DiffTree.node(at: "lib/old", in: viewModel.rootNodes)?.status == .identical
        }
        undoManager.endUndoGrouping()
        #expect(fixture.exists(.right, "lib/old/m0.ts") && !fixture.exists(.right, "lib/new"))

        undoManager.undo()
        try await waitUntil("undo") { DiffTree.node(at: "lib/new", in: viewModel.rootNodes)?.status == .rightOnly }
        #expect(!fixture.exists(.right, "lib/old"), "the folder created by the move is removed again")

        undoManager.redo()
        try await waitUntil("redo") { DiffTree.node(at: "lib/old", in: viewModel.rootNodes)?.status == .identical }
    }

    @Test func batchCopyAndUndo() async throws {
        let fixture = try makeRepositoryLikeFixture()
        let (viewModel, undoManager) = makeViewModel()
        try await open(fixture, in: viewModel)

        viewModel.select(ids: ["src/missing.swift", "src/app.swift"])
        #expect(viewModel.selectedNode == nil && viewModel.selectedNodes.count == 2)
        undoManager.beginUndoGrouping()
        viewModel.copySelection(direction: .leftToRight)
        let confirmation = try #require(viewModel.pendingConfirmation)
        confirmation.action()
        try await waitUntil("copy") {
            !viewModel.isPerformingFileOperation
                && DiffTree.node(at: "src/app.swift", in: viewModel.rootNodes)?.status == .identical
                && DiffTree.node(at: "src/missing.swift", in: viewModel.rootNodes)?.status == .identical
        }
        undoManager.endUndoGrouping()

        undoManager.undo()
        try await waitUntil("undo") {
            DiffTree.node(at: "src/app.swift", in: viewModel.rootNodes)?.status == .modified
                && DiffTree.node(at: "src/missing.swift", in: viewModel.rootNodes)?.status == .leftOnly
        }
        #expect(try fixture.read(.right, "src/app.swift") == "let a = 2\n")
    }

    @Test func blockSyncWritesOneChange() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "file.txt", "a\nb\nc\nd\n")
        try fixture.write(.right, "file.txt", "a\nB\nc\nD\n")
        let (viewModel, _) = makeViewModel()
        try await open(fixture, in: viewModel)
        viewModel.select(nodeID: "file.txt")
        try await waitUntil("diff") { viewModel.textDiff?.hunks.count == 2 }

        viewModel.applyHunk(at: 0, direction: .leftToRight)
        try await waitUntil("hunk applied") { viewModel.textDiff?.hunks.count == 1 }
        #expect(try fixture.read(.right, "file.txt") == "a\nb\nc\nD\n")
    }

    @Test func liveUpdatesFromOutsideChanges() async throws {
        let fixture = try makeRepositoryLikeFixture()
        let (viewModel, _) = makeViewModel(watching: true)
        try await open(fixture, in: viewModel)

        try fixture.write(.right, "extra2/new.txt", "hi\n")
        try await waitUntil("new folder appears") { sections(viewModel)[.rightOnly]?.contains("extra2") == true }
        try fixture.write(.left, "out/churn.js", "x")
        try await Task.sleep(for: .milliseconds(800))
        #expect(DiffTree.node(at: "out", in: viewModel.rootNodes)?.status == .ignored)
    }

    @Test func swapMirrorsResults() async throws {
        let fixture = try makeRepositoryLikeFixture()
        let (viewModel, _) = makeViewModel()
        try await open(fixture, in: viewModel)
        try await waitUntil("moves") { viewModel.summary.moved == 5 }

        viewModel.swapFolders()
        let grouped = sections(viewModel)
        #expect(grouped[.moved] == ["b", "lib/new"])
        #expect(grouped[.leftOnly] == ["extra"])
        #expect(grouped[.rightOnly] == ["src/missing.swift"])
    }

    @Test func suggestsInnerFoldersOfExtractedDownloads() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "project-main/src/a.txt", "1")
        try fixture.write(.right, "project-2.1/src/a.txt", "2")
        try fixture.write(.left, "__MACOSX/._junk", "x")
        let (viewModel, _) = makeViewModel()
        try await open(fixture, in: viewModel)

        let suggestion = try #require(viewModel.innerFolderSuggestion)
        #expect(suggestion.left.name == "project-main" && suggestion.right.name == "project-2.1")
        viewModel.compareInnerFolders()
        try await waitUntil("inner scan") { viewModel.hasScanned && !viewModel.isScanning && viewModel.leftFolderURL?.lastPathComponent == "project-main" }
        #expect(DiffTree.node(at: "src/a.txt", in: viewModel.rootNodes)?.status == .modified)
        #expect(viewModel.innerFolderSuggestion == nil)
    }

    @Test func rejectsTheSameFolderTwice() throws {
        let fixture = try FolderFixture()
        let (viewModel, _) = makeViewModel()
        viewModel.setFolder(fixture.left, for: .left)
        viewModel.setFolder(fixture.left, for: .right)
        #expect(viewModel.rightFolderURL == nil)
        #expect(viewModel.alert != nil)
    }

    @Test func navigatesBetweenChangedFiles() async throws {
        let fixture = try makeRepositoryLikeFixture()
        let (viewModel, _) = makeViewModel()
        try await open(fixture, in: viewModel)

        viewModel.selectAdjacentChangedFile(forward: true)
        let first = try #require(viewModel.selectedNode?.id)
        viewModel.selectAdjacentChangedFile(forward: true)
        let second = try #require(viewModel.selectedNode?.id)
        #expect(first != second)
        viewModel.selectAdjacentChangedFile(forward: false)
        #expect(viewModel.selectedNode?.id == first)
    }

    @Test func reportListsEveryDifference() async throws {
        let fixture = try makeRepositoryLikeFixture()
        let (viewModel, _) = makeViewModel()
        try await open(fixture, in: viewModel)
        try await waitUntil("moves") { viewModel.summary.moved == 5 }

        viewModel.kindFilter = [.modified]   // reports ignore sidebar filters
        let markdown = ReportBuilder.render(viewModel.reportData(), format: .markdown)
        #expect(markdown.contains("## Moved or renamed (2)"))
        #expect(markdown.contains("- `lib/old/` → `lib/new/` — 4 files"))
        #expect(markdown.contains("- `extra/` — 5 files"))
        #expect(markdown.contains("- `src/missing.swift`"))
    }
}

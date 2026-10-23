//
//  DiffViewModel+Sync.swift
//  PathDiff
//

import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Holds state an undo step needs before the asynchronous work that produces it finishes.
private final class UndoPayload<Value> {
    var value: Value?
}

/// What an undo puts back: the state before a write, plus the state right after it of the
/// paths the write created, so undo can tell whether they were edited since.
private struct UndoStep {
    let snapshots: [FileSnapshot]
    var created: [URL: HistoryAfterState] = [:]
}

/// A write that failed after it may already have changed files. It carries the state
/// captured before the write, so what was done can still be undone and reverted.
nonisolated struct PartialWriteError: LocalizedError {
    let snapshots: [FileSnapshot]?
    let underlying: any Error

    var errorDescription: String? { underlying.localizedDescription }

    /// Runs `write`, wrapping its error with the snapshots taken before it.
    static func wrapping(_ snapshots: [FileSnapshot]?, _ write: () async throws -> Void) async throws {
        do {
            try await write()
        } catch {
            throw PartialWriteError(snapshots: snapshots, underlying: error)
        }
    }
}

/// How a write operation appears in the sync history.
struct HistoryContext {
    let kind: HistoryKind
    let title: String
    let direction: SyncDirection?
    /// The side whose files change; used to describe items from snapshots.
    let side: Side
    /// Explicit items; derived from the snapshots when `nil`.
    var items: [HistoryItem]?
}

/// File and folder sync, applying moves, trashing, undo/redo, reports and sub-comparisons.
extension DiffViewModel {
    /// Whether copying `node` in `direction` would change anything.
    func canCopy(_ node: DiffNode?, direction: SyncDirection) -> Bool {
        guard let node else { return false }
        return canCopy([node], direction: direction)
    }

    func canCopy(_ nodes: [DiffNode], direction: SyncDirection) -> Bool {
        guard hasBothFolders, !isPerformingFileOperation else { return false }
        return nodes.contains { node in
            node.exists(on: direction.source) && node.status != .identical && node.status != .ignored
        }
    }

    // MARK: - Copying

    func copySelection(direction: SyncDirection) {
        copy(selectedNodes, direction: direction)
    }

    func copy(_ node: DiffNode, direction: SyncDirection) {
        copy([node], direction: direction)
    }

    /// Copies files, or every differing item inside folders, to the other side.
    func copy(_ nodes: [DiffNode], direction: SyncDirection) {
        guard let leftRoot = leftFolderURL, let rightRoot = rightFolderURL, !isPerformingFileOperation, !nodes.isEmpty else { return }
        let plan = SyncPlanner.plan(for: nodes, direction: direction, leftRoot: leftRoot, rightRoot: rightRoot)
        let single = nodes.count == 1 ? nodes[0].name : nil
        let count = nodes.count
        guard plan.fileCount > 0 || plan.directoryCount > 0 else {
            let reason = if plan.skippedCount > 0 {
                String(localized: "A file and a folder share the same name, so the item can’t be copied automatically.")
            } else if let single {
                String(localized: "There are no differences in “\(single)” that can be copied \(direction.title).")
            } else {
                String(localized: "There are no differences in \(count) items that can be copied \(direction.title).")
            }
            alert = AlertMessage(title: String(localized: "Nothing to Copy"), message: reason)
            return
        }

        let actionName = direction == .leftToRight ? String(localized: "Copy Left → Right") : String(localized: "Copy Right → Left")
        let destination = sideName(direction.destination)
        let history = HistoryContext(
            kind: .copy,
            title: single.map { String(localized: "Copy “\($0)” to \(destination)") }
                ?? String(localized: "Copy \(count) items to \(destination)"),
            direction: direction,
            side: direction.destination
        )
        // Undo backs up the replaced files; beyond the limit there is no undo, so ask first.
        let isUndoable = plan.replacedBytes <= FileManagerService.undoSnapshotLimit
        let isSingleFile = nodes.count == 1 && !nodes[0].isDirectory && plan.fileCount == 1
        guard !isSingleFile || !isUndoable else {
            executeSyncPlan(plan, actionName: actionName, history: history)
            return
        }

        let source = sideName(direction.source)
        var message = copyDescription(plan, source: source, destination: destination)
        message += " " + String(localized: "Items that only exist in “\(destination)” are kept.")
        if plan.skippedCount > 0 {
            message += " " + String(localized: "\(plan.skippedCount) items where a file and a folder share a name will be skipped.")
        }
        message += " " + (isUndoable
            ? String(localized: "You can undo this with ⌘Z.")
            : String(localized: "This is too large to undo."))
        pendingConfirmation = PendingConfirmation(
            title: single.map { String(localized: "Copy “\($0)” \(direction.title)?") }
                ?? String(localized: "Copy \(count) items \(direction.title)?"),
            message: message,
            confirmTitle: String(localized: "Copy", comment: "Confirmation button that copies files"),
            isDestructive: false
        ) { [weak self] in
            self?.executeSyncPlan(plan, actionName: actionName, history: history)
        }
    }

    /// The first sentence of the copy confirmation: what will be copied, and where.
    private func copyDescription(_ plan: SyncPlan, source: String, destination: String) -> String {
        let files = plan.fileCount
        let folders = plan.directoryCount
        guard folders > 0 else {
            return String(localized: "\(files) files will be copied from “\(source)” to “\(destination)”, replacing any existing versions.")
        }
        return String(localized: "\(files) files and \(folders) new folders will be copied from “\(source)” to “\(destination)”, replacing any existing versions.")
    }

    private func executeSyncPlan(_ plan: SyncPlan, actionName: String, history: HistoryContext) {
        let service = fileService
        performFileOperation(actionName: actionName, refreshPaths: plan.refreshPaths, history: history) {
            let snapshots = try await service.capture(plan.destinationURLs)
            try await PartialWriteError.wrapping(snapshots) { try await service.execute(plan) }
            return snapshots
        }
    }

    // MARK: - Trash

    func moveToTrash(_ node: DiffNode, side: Side) {
        moveToTrash([node], side: side)
    }

    func moveToTrash(_ nodes: [DiffNode], side: Side) {
        let targets = nodes.filter { $0.exists(on: side) }
        let urls = targets.compactMap { $0.url(on: side) }
        guard !urls.isEmpty, !isPerformingFileOperation else { return }
        let service = fileService
        let single = targets.count == 1 ? targets[0].name : nil
        let count = targets.count
        let folder = sideName(side)
        let history = HistoryContext(
            kind: .trash,
            title: single.map { String(localized: "Move “\($0)” in \(folder) to the Trash") }
                ?? String(localized: "Move \(count) items in \(folder) to the Trash"),
            direction: nil,
            side: side,
            items: targets.map { HistoryItem(action: .trashed, path: $0.relativePath, previousPath: nil, side: side) }
        )
        pendingConfirmation = PendingConfirmation(
            title: single.map { String(localized: "Move “\($0)” in “\(folder)” to the Trash?") }
                ?? String(localized: "Move \(count) items in “\(folder)” to the Trash?"),
            message: (targets.count == 1
                ? String(localized: "\(DisplayFormat.abbreviatedPath(urls[0])) will be moved to the Trash.")
                : String(localized: "These items will be moved to the Trash."))
                + " " + String(localized: "You can undo this with ⌘Z or revert it from the History."),
            confirmTitle: String(localized: "Move to Trash"),
            isDestructive: true
        ) { [weak self] in
            self?.performFileOperation(actionName: String(localized: "Move to Trash"), refreshPaths: Set(targets.map(\.relativePath)), history: history) {
                // Back up the contents first, so the trash can be undone or reverted.
                let snapshots = try await service.capture(urls.flatMap(FileManagerService.treeURLs(at:)))
                try await PartialWriteError.wrapping(snapshots) { try await service.moveToTrash(urls) }
                return snapshots
            }
        }
    }

    // MARK: - Applying moves

    /// Renames the item on `side` so both trees have it at the same path: on the right the
    /// right item moves to the left path; on the left the left item moves to the right path.
    func applyMove(_ match: MoveMatch, on side: Side) {
        guard let root = folderURL(for: side), !isPerformingFileOperation else { return }
        let (from, to) = side == .right ? (match.rightPath, match.leftPath) : (match.leftPath, match.rightPath)
        let source = root.appending(path: from)
        let destination = root.appending(path: to)
        let refreshPaths: Set<String> = [from, to]
        let actionName = match.isDirectory ? String(localized: "Move Folder") : String(localized: "Move File")
        let service = fileService

        enqueueFileOperation { [self] in
            do {
                let created = try await service.moveItem(from: source, to: destination)
                var historyID: UUID?
                if let left = leftFolderURL, let right = rightFolderURL {
                    historyID = history.record(
                        HistoryDraft(
                            kind: .move,
                            title: String(localized: "Move \(from) to \(to) in \(sideName(side))"),
                            direction: nil,
                            items: [HistoryItem(action: .renamed, path: to, previousPath: from, side: side)]
                        ),
                        leftRoot: left,
                        rightRoot: right,
                        snapshots: [],
                        renames: [HistoryRename(
                            from: source.path(percentEncoded: false),
                            to: destination.path(percentEncoded: false),
                            createdFolders: created.map { $0.path(percentEncoded: false) }
                        )]
                    )
                }
                registerMoveUndo(from: destination, to: source, cleanup: created, refreshPaths: refreshPaths, actionName: actionName, historyID: historyID)
                select(nodeID: to)
            } catch {
                alert = AlertMessage(title: String(localized: "\(actionName) Failed"), message: error.localizedDescription)
            }
            scheduleRefresh(refreshPaths)
        }
    }

    /// Registers moving `from` back `to`, then removing folders the original move created.
    private func registerMoveUndo(from: URL, to: URL, cleanup: [URL], refreshPaths: Set<String>, actionName: String, historyID: UUID?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.performUndoMove(from: from, to: to, cleanup: cleanup, refreshPaths: refreshPaths, actionName: actionName, historyID: historyID, marking: .undone)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func performUndoMove(from: URL, to: URL, cleanup: [URL], refreshPaths: Set<String>, actionName: String, historyID: UUID?, marking state: HistoryEntry.State) {
        guard let undoManager else { return }
        guard !history.wasReverted(historyID) else {
            NSSound.beep()
            return
        }
        // The inverse (redo) must be registered synchronously; the folders it will have to
        // clean up are only known once the move ran.
        let created = UndoPayload<[URL]>()
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.performUndoMove(
                    from: to, to: from, cleanup: created.value ?? [], refreshPaths: refreshPaths, actionName: actionName,
                    historyID: historyID, marking: state == .undone ? .applied : .undone
                )
            }
        }
        undoManager.setActionName(actionName)

        let service = fileService
        enqueueFileOperation { [self] in
            do {
                created.value = try await service.moveItem(from: from, to: to)
                await service.removeEmptyDirectories(cleanup)
                if let historyID { history.setState(historyID, state) }
            } catch {
                alert = AlertMessage(title: String(localized: "Couldn’t Undo “\(actionName)”"), message: error.localizedDescription)
            }
            scheduleRefresh(refreshPaths)
        }
    }

    // MARK: - Operations and snapshot undo

    /// Runs a write, registers undo with the captured snapshots and refreshes affected nodes.
    /// Runs a write, records it in the history, registers undo with the captured snapshots
    /// (the state before the write) and refreshes affected nodes. `completion` receives
    /// whether the operation succeeded.
    func performFileOperation(
        actionName: String,
        refreshPaths: Set<String>,
        undoable: Bool = true,
        history historyContext: HistoryContext? = nil,
        reportsErrors: Bool = true,
        completion: ((Error?) -> Void)? = nil,
        operation: @escaping () async throws -> [FileSnapshot]?
    ) {
        enqueueFileOperation { [self] in
            var failure: Error?
            /// Records the write and makes it undoable; also after a partial failure, so files
            /// that were already changed can be put back.
            @MainActor func finish(_ snapshots: [FileSnapshot]?) async {
                let historyID = historyContext.flatMap { recordHistory($0, snapshots: snapshots) }
                if undoable, let snapshots {
                    let created = await FileManagerService.createdStates(of: snapshots)
                    registerUndo(restoring: UndoStep(snapshots: snapshots, created: created), refreshPaths: refreshPaths, actionName: actionName, historyID: historyID)
                }
            }
            do {
                await finish(try await operation())
            } catch {
                var error = error
                if let partial = error as? PartialWriteError {
                    await finish(partial.snapshots)
                    error = partial.underlying
                }
                failure = error
                logger.error("\(actionName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if reportsErrors {
                    alert = AlertMessage(title: String(localized: "\(actionName) Failed"), message: error.localizedDescription)
                }
            }
            scheduleRefresh(refreshPaths)
            completion?(failure)
        }
    }

    /// Adds an operation to the sync history and returns its entry ID.
    private func recordHistory(_ context: HistoryContext, snapshots: [FileSnapshot]?) -> UUID? {
        guard let left = leftFolderURL, let right = rightFolderURL else { return nil }
        let items = context.items ?? (snapshots ?? []).compactMap { snapshot -> HistoryItem? in
            if case .directory = snapshot.state { return nil }
            let isNew = if case .missing = snapshot.state { true } else { false }
            return HistoryItem(action: isNew ? .added : .updated, path: relativePath(of: snapshot.url, side: context.side), previousPath: nil, side: context.side)
        }
        return history.record(
            HistoryDraft(kind: context.kind, title: context.title, direction: context.direction, items: items),
            leftRoot: left,
            rightRoot: right,
            snapshots: snapshots
        )
    }

    private func registerUndo(restoring step: UndoStep, refreshPaths: Set<String>, actionName: String, historyID: UUID?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.restore(step, refreshPaths: refreshPaths, actionName: actionName, historyID: historyID, marking: .undone)
            }
        }
        undoManager.setActionName(actionName)
    }

    /// Runs file writes one at a time, in the order they were started. An undo chosen while
    /// a copy still runs waits for it instead of racing it on the same files.
    func enqueueFileOperation(_ work: @escaping @MainActor () async -> Void) {
        let previous = fileOperationTail
        pendingFileOperations += 1
        isPerformingFileOperation = true
        fileOperationTail = Task {
            await previous?.value
            await work()
            pendingFileOperations -= 1
            isPerformingFileOperation = pendingFileOperations > 0
        }
    }

    /// Performs an undo (or redo). The inverse step is registered synchronously, as
    /// `UndoManager` requires, and its snapshot is filled in once captured. The history
    /// entry is marked undone (or applied again).
    private func restore(_ step: UndoStep, refreshPaths: Set<String>, actionName: String, historyID: UUID?, marking state: HistoryEntry.State) {
        guard let undoManager else { return }
        guard !history.wasReverted(historyID) else {
            NSSound.beep()
            return
        }
        let inverse = UndoPayload<UndoStep>()
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                guard let inverseStep = inverse.value else {
                    NSSound.beep()
                    return
                }
                target.restore(inverseStep, refreshPaths: refreshPaths, actionName: actionName, historyID: historyID, marking: state == .undone ? .applied : .undone)
            }
        }
        undoManager.setActionName(actionName)

        let service = fileService
        enqueueFileOperation { [self] in
            do {
                let current = try await service.capture(step.snapshots.map(\.url), limit: .max) ?? []
                inverse.value = UndoStep(snapshots: current)
                try await service.restore(step.snapshots, created: step.created)
                inverse.value?.created = await FileManagerService.createdStates(of: current)
                if let historyID { history.setState(historyID, state) }
            } catch {
                alert = AlertMessage(title: String(localized: "Couldn’t Undo “\(actionName)”"), message: error.localizedDescription)
            }
            scheduleRefresh(refreshPaths)
        }
    }

    // MARK: - Ignore patterns

    func addIgnorePattern(for node: DiffNode) {
        settings.addIgnorePattern(node.name)
    }

    func addIgnorePattern(_ pattern: String) {
        settings.addIgnorePattern(pattern)
    }

    // MARK: - Reports

    func reportData() -> ReportData {
        var items: [ReportItem] = []
        for section in makeChangeSections(applyingFilters: false) {
            for row in section.rows {
                let node = row.node
                let counterpart = row.move.flatMap { DiffTree.node(at: $0.rightPath, in: rootNodes) }
                items.append(ReportItem(
                    kind: row.kind,
                    path: node.relativePath,
                    counterpartPath: row.move?.rightPath,
                    isDirectory: node.isDirectory,
                    fileCount: row.fileCount,
                    isExactMove: row.move?.isExact ?? false,
                    leftSize: node.isDirectory ? nil : node.leftMetadata?.size,
                    rightSize: node.isDirectory ? nil : (counterpart ?? node).rightMetadata?.size
                ))
            }
        }
        return ReportData(
            leftRoot: leftFolderURL?.path(percentEncoded: false) ?? "",
            rightRoot: rightFolderURL?.path(percentEncoded: false) ?? "",
            generated: .now,
            summary: summary,
            options: settings.diffOptions,
            respectsGitIgnore: settings.respectsGitIgnore,
            items: items
        )
    }

    func exportReport(format: ReportFormat) async {
        guard hasScanned else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Comparison Report")
        panel.nameFieldStringValue = "\(sideName(.left)) vs \(sideName(.right)).\(format.fileExtension)"
            .replacingOccurrences(of: "/", with: "-")
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        let text = ReportBuilder.render(reportData(), format: format)
        do {
            try await fileService.writeText(text, to: url)
        } catch {
            alert = AlertMessage(title: String(localized: "Couldn’t Export Report"), message: error.localizedDescription)
        }
    }

    func copyReportToPasteboard() {
        guard hasScanned else { return }
        FinderActions.copyToPasteboard(ReportBuilder.render(reportData(), format: .markdown))
    }

    // MARK: - Sub-comparisons

    /// A request to compare a folder pair in its own window: a folder present on both
    /// sides, or a moved folder with its new location.
    func comparisonRequest(for node: DiffNode) -> ComparisonRequest? {
        guard node.isDirectory else { return nil }
        let left: URL?
        let right: URL?
        if let match = moves.match(for: node), match.isDirectory {
            left = DiffTree.node(at: match.leftPath, in: rootNodes)?.leftURL
            right = DiffTree.node(at: match.rightPath, in: rootNodes)?.rightURL
        } else {
            left = node.leftMetadata?.kind == .directory ? node.leftURL : nil
            right = node.rightMetadata?.kind == .directory ? node.rightURL : nil
        }
        guard let left, let right,
              let leftBookmark = BookmarkStore.bookmark(for: left),
              let rightBookmark = BookmarkStore.bookmark(for: right)
        else { return nil }
        return ComparisonRequest(leftBookmark: leftBookmark, rightBookmark: rightBookmark)
    }
}

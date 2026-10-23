//
//  DiffViewModel+BatchSync.swift
//  PathDiff
//

import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Holds an undo step's result until the asynchronous work that produces it finishes.
private final class BatchRecordBox {
    var record: BatchSyncRecord?
}

/// The Sync sheet (batch sync with a dry run) and patch export.
extension DiffViewModel {
    // MARK: - Session

    /// Opens the Sync sheet for the selection (or everything when nothing is selected).
    func beginBatchSync(ids: Set<String>? = nil) {
        guard hasScanned, !isPerformingFileOperation else { return }
        let selection = ids ?? selectedIDs
        var session = BatchSyncSession(scopeIDs: selection.isEmpty ? nil : selection, selectionIDs: selection)
        session.plan = makeBatchPlan(for: session)
        batchSync = session
    }

    /// Changes options or scope and re-plans (the dry run updates immediately).
    func updateBatchSync(_ change: (inout BatchSyncSession) -> Void) {
        guard var session = batchSync, !session.isRunning else { return }
        change(&session)
        session.plan = makeBatchPlan(for: session)
        session.excluded = []
        session.errorMessage = nil
        batchSync = session
    }

    func setBatchOperation(_ id: Int, included: Bool) {
        guard batchSync?.isRunning == false else { return }
        if included {
            batchSync?.excluded.remove(id)
        } else {
            batchSync?.excluded.insert(id)
        }
    }

    func setBatchOperations(of kind: SyncOperation.Kind, included: Bool) {
        guard let session = batchSync, !session.isRunning else { return }
        let ids = session.plan.operations.filter { $0.kind == kind }.map(\.id)
        if included {
            batchSync?.excluded.subtract(ids)
        } else {
            batchSync?.excluded.formUnion(ids)
        }
    }

    /// Closes the sheet, or stops a running sync after the current operation.
    func cancelBatchSync() {
        if batchSync?.isRunning == true {
            batchSyncTask?.cancel()
        } else {
            batchSync = nil
        }
    }

    func copyBatchSyncPlan() {
        guard let session = batchSync else { return }
        let text = BatchSyncPlanner.describe(
            session.plan,
            excluding: session.excluded,
            options: session.options,
            leftName: sideName(.left),
            rightName: sideName(.right)
        )
        FinderActions.copyToPasteboard(text)
    }

    /// Content that a sync would overwrite or trash, compared with the undo limit.
    func batchSyncIsUndoable(_ session: BatchSyncSession) -> Bool {
        var bytes: Int64 = 0
        for operation in session.plan.operations where !session.excluded.contains(operation.id) {
            switch operation.kind {
            case .trash: bytes += operation.bytes
            case .copy where operation.overwrites:
                if let node = DiffTree.node(at: operation.path, in: rootNodes) {
                    bytes += node.metadata(on: operation.destination)?.size ?? 0
                }
            default: break
            }
        }
        return bytes <= FileManagerService.undoSnapshotLimit
    }

    func makeBatchPlan(for session: BatchSyncSession) -> BatchSyncPlan {
        guard let leftRoot = leftFolderURL, let rightRoot = rightFolderURL else { return BatchSyncPlan() }
        let scope = session.scopeIDs.map { ids in ids.sorted().compactMap { DiffTree.node(at: $0, in: rootNodes) } }
        return BatchSyncPlanner.plan(
            scope: scope,
            tree: rootNodes,
            moves: settings.detectsMoves ? moves : MoveMap(),
            options: session.options,
            leftRoot: leftRoot,
            rightRoot: rightRoot,
            unreadable: Set(scanIssues.map(\.path))
        )
    }

    // MARK: - Running

    func runBatchSync() {
        guard var session = batchSync, !session.isRunning, !isPerformingFileOperation else { return }
        let plan = session.plan
        let excluded = session.excluded
        let included = plan.operations.filter { !excluded.contains($0.id) }
        guard !included.isEmpty else { return }
        session.isRunning = true
        session.errorMessage = nil
        session.progress = BatchSyncProgress(total: included.count)
        batchSync = session

        let paths = Self.affectedPaths(of: included)
        let service = fileService
        let report: @Sendable (BatchSyncProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in self?.batchSync?.progress = progress }
        }
        // Part of the file-operation queue, so an undo chosen meanwhile waits for the sync.
        let previous = fileOperationTail
        pendingFileOperations += 1
        isPerformingFileOperation = true
        batchSyncTask = Task { [weak self] in
            await previous?.value
            let (record, error) = await service.execute(plan, excluding: excluded, progress: report)
            guard let self else { return }
            self.pendingFileOperations -= 1
            self.isPerformingFileOperation = self.pendingFileOperations > 0
            if record.changedAnything {
                let historyID = self.recordBatchHistory(record, operations: included, options: session.options)
                self.registerBatchUndo(record: record, plan: plan, excluded: excluded, paths: paths, historyID: historyID)
            }
            if let error, !(error is CancellationError) {
                self.logger.error("Sync failed: \(error.localizedDescription, privacy: .public)")
                self.batchSync?.isRunning = false
                self.batchSync?.errorMessage = String(localized: "Stopped after \(record.completedOperations) of \(included.count) operations: \(error.localizedDescription)")
            } else {
                self.batchSync = nil
            }
            self.refreshAfterBatch(paths)
        }
        fileOperationTail = batchSyncTask
    }

    /// One history entry for the whole sync.
    private func recordBatchHistory(_ record: BatchSyncRecord, operations: [SyncOperation], options: BatchSyncOptions) -> UUID? {
        guard let left = leftFolderURL, let right = rightFolderURL else { return nil }
        let items = operations.map { operation -> HistoryItem in
            let action: HistoryItem.Action = switch operation.kind {
            case .rename: .renamed
            case .copy: operation.overwrites ? .updated : .added
            case .trash: .trashed
            }
            return HistoryItem(action: action, path: operation.path, previousPath: operation.previousPath, side: operation.destination)
        }
        var title = switch options.mode {
        case .oneWay: String(localized: "Sync \(sideName(options.direction.source)) → \(sideName(options.direction.destination))")
        case .merge: String(localized: "Merge \(sideName(.left)) ⇄ \(sideName(.right))")
        }
        if record.completedOperations < operations.count {
            title = String(localized: "\(title) (stopped after \(record.completedOperations) of \(operations.count))")
        }
        return history.record(
            HistoryDraft(kind: .sync, title: title, direction: options.mode == .oneWay ? options.direction : nil, items: items),
            leftRoot: left,
            rightRoot: right,
            snapshots: record.snapshots,
            renames: record.renames.map {
                HistoryRename(from: $0.from.path(percentEncoded: false), to: $0.to.path(percentEncoded: false), createdFolders: $0.createdFolders.map { $0.path(percentEncoded: false) })
            }
        )
    }

    private static func affectedPaths(of operations: [SyncOperation]) -> Set<String> {
        var paths = Set<String>()
        for operation in operations {
            paths.insert(operation.path)
            if let previous = operation.previousPath { paths.insert(previous) }
        }
        return paths
    }

    /// Small syncs refresh just their paths; large ones rescan (fast thanks to the cache).
    private func refreshAfterBatch(_ paths: Set<String>) {
        if paths.count > 200 {
            rescan()
        } else {
            scheduleRefresh(paths)
        }
    }

    private func registerBatchUndo(record: BatchSyncRecord, plan: BatchSyncPlan, excluded: Set<Int>, paths: Set<String>, historyID: UUID?) {
        guard let undoManager, record.snapshots != nil else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.revertBatch(record, plan: plan, excluded: excluded, paths: paths, historyID: historyID)
            }
        }
        undoManager.setActionName(String(localized: "undo.sync", defaultValue: "Sync", comment: "Undo action name, shown after “Undo”: use a noun where the language prefers one"))
    }

    /// Undo. Registers the redo (running the same plan again) synchronously.
    private func revertBatch(_ record: BatchSyncRecord, plan: BatchSyncPlan, excluded: Set<Int>, paths: Set<String>, historyID: UUID?) {
        guard let undoManager else { return }
        guard !history.wasReverted(historyID) else {
            NSSound.beep()
            return
        }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.redoBatch(plan: plan, excluded: excluded, paths: paths, historyID: historyID)
            }
        }
        undoManager.setActionName(String(localized: "undo.sync", defaultValue: "Sync", comment: "Undo action name, shown after “Undo”: use a noun where the language prefers one"))
        let service = fileService
        enqueueFileOperation { [self] in
            do {
                try await service.revert(record)
                if let historyID { history.setState(historyID, .undone) }
            } catch {
                alert = AlertMessage(title: String(localized: "Couldn’t Undo Sync"), message: error.localizedDescription)
            }
            refreshAfterBatch(paths)
        }
    }

    /// Redo. Registers the next undo synchronously; its record arrives when the run ends.
    private func redoBatch(plan: BatchSyncPlan, excluded: Set<Int>, paths: Set<String>, historyID: UUID?) {
        guard let undoManager else { return }
        let box = BatchRecordBox()
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                // Without snapshots (over the size limit) the contents couldn't be put back.
                guard let record = box.record, record.snapshots != nil else {
                    NSSound.beep()
                    return
                }
                target.revertBatch(record, plan: plan, excluded: excluded, paths: paths, historyID: historyID)
            }
        }
        undoManager.setActionName(String(localized: "undo.sync", defaultValue: "Sync", comment: "Undo action name, shown after “Undo”: use a noun where the language prefers one"))
        let service = fileService
        enqueueFileOperation { [self] in
            let (record, error) = await service.execute(plan, excluding: excluded) { _ in }
            box.record = record
            if error == nil, let historyID { history.setState(historyID, .applied) }
            if let error {
                alert = AlertMessage(title: String(localized: "Couldn’t Redo Sync"), message: error.localizedDescription)
            }
            refreshAfterBatch(paths)
        }
    }

    // MARK: - Patches

    /// The selected text file's changes as a unified diff, or `nil` for non-text selections.
    func patchForCurrentFile() -> String? {
        guard let diff = textDiff, let selected = selectedNode, let node = activeDiffNode else { return nil }
        if let match = moves.match(for: selected), !match.isDirectory {
            return PatchBuilder.unifiedDiff(oldPath: match.leftPath, newPath: match.rightPath, diff: diff, rename: true)
        }
        return PatchBuilder.unifiedDiff(
            oldPath: node.existsOnLeft ? node.relativePath : nil,
            newPath: node.existsOnRight ? node.relativePath : nil,
            diff: diff
        )
    }

    func copyPatchForCurrentFile() {
        guard let patch = patchForCurrentFile() else {
            NSSound.beep()
            return
        }
        FinderActions.copyToPasteboard(patch)
    }

    /// Every difference as patch entries (left = old, right = new); moves become renames.
    func patchEntries() -> [PatchBuilder.Entry] {
        var entries: [PatchBuilder.Entry] = []
        for match in moves.allMatches where !match.isDirectory {
            guard let left = DiffTree.node(at: match.leftPath, in: rootNodes),
                  let right = DiffTree.node(at: match.rightPath, in: rootNodes)
            else { continue }
            entries.append(PatchBuilder.Entry(oldPath: match.leftPath, newPath: match.rightPath, leftURL: left.leftURL, rightURL: right.rightURL, isRename: true))
        }
        DiffTree.forEachDepthFirst(rootNodes) { node in
            guard !node.isDirectory, !node.isSymlink, moves.match(for: node) == nil else { return }
            switch node.status {
            case .modified where !node.hasKindMismatch:
                entries.append(PatchBuilder.Entry(oldPath: node.relativePath, newPath: node.relativePath, leftURL: node.leftURL, rightURL: node.rightURL, isRename: false))
            case .leftOnly:
                entries.append(PatchBuilder.Entry(oldPath: node.relativePath, newPath: nil, leftURL: node.leftURL, rightURL: nil, isRename: false))
            case .rightOnly:
                entries.append(PatchBuilder.Entry(oldPath: nil, newPath: node.relativePath, leftURL: nil, rightURL: node.rightURL, isRename: false))
            default:
                break
            }
        }
        return entries.sorted { ($0.oldPath ?? $0.newPath ?? "") < ($1.oldPath ?? $1.newPath ?? "") }
    }

    func exportPatch() async {
        guard hasScanned else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Patch")
        panel.message = String(localized: "A unified diff that turns “\(sideName(.left))” into “\(sideName(.right))”.")
        panel.nameFieldStringValue = "\(sideName(.left)) to \(sideName(.right)).patch".replacingOccurrences(of: "/", with: "-")
        if let type = UTType(filenameExtension: "patch") { panel.allowedContentTypes = [type] }
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        isPerformingFileOperation = true
        defer { isPerformingFileOperation = false }
        do {
            // Strict options: a patch that skipped whitespace-only edits wouldn't turn the
            // left side into the right one.
            let patch = try await PatchBuilder.patch(for: patchEntries(), options: DiffOptions())
            try await fileService.writeText(patch, to: url)
        } catch {
            alert = AlertMessage(title: String(localized: "Couldn’t Export Patch"), message: error.localizedDescription)
        }
    }
}

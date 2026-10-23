//
//  BatchSync.swift
//  PathDiff
//

import Foundation

/// Whether a sync copies one way, or fills each side with what the other has.
nonisolated enum BatchSyncMode: String, Sendable, Hashable, CaseIterable, Identifiable {
    case oneWay
    /// Copies what each side is missing to it, and replaces older copies of modified files
    /// with the newer one. Nothing is deleted and moved items stay where they are.
    case merge

    var id: Self { self }
    var title: String { self == .oneWay ? String(localized: "One Way") : String(localized: "Merge Both Ways") }
}

/// What a batch sync should do.
nonisolated struct BatchSyncOptions: Sendable, Hashable {
    var mode = BatchSyncMode.oneWay
    /// One-way syncs only.
    var direction: SyncDirection = .leftToRight
    /// Overwrite files that differ.
    var copyModified = true
    /// Copy items that only exist on the source side.
    var copyMissing = true
    /// Rename detected moves on the destination instead of copying and deleting.
    var applyMoves = true
    /// Move items that only exist on the destination to the Trash (a full mirror).
    var deleteExtras = false
}

/// One planned change, shown in the dry run and individually excludable.
nonisolated struct SyncOperation: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable, CaseIterable {
        case rename
        case copy
        case trash
    }

    let id: Int
    let kind: Kind
    /// The side this operation writes to.
    let destination: Side
    /// Path on the destination side after the operation.
    let path: String
    /// For renames: the destination item's current path.
    let previousPath: String?
    let isFolder: Bool
    let fileCount: Int
    let bytes: Int64
    /// Whether this replaces an existing destination file (as opposed to adding one).
    let overwrites: Bool
    /// Concrete file-system steps for copies.
    let steps: [SyncPlan.Step]
    /// The destination item a rename moves or trash removes.
    let targetURL: URL?
    /// Where a rename moves the item to.
    let renameDestination: URL?

    static func == (lhs: SyncOperation, rhs: SyncOperation) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The dry-run result: everything a sync would do.
nonisolated struct BatchSyncPlan: Sendable {
    var operations: [SyncOperation] = []
    /// Items that can't be synced automatically, with the reason.
    var skipped: [(path: String, reason: String)] = []

    func operations(of kind: SyncOperation.Kind, excluding excluded: Set<Int> = []) -> [SyncOperation] {
        operations.filter { $0.kind == kind && !excluded.contains($0.id) }
    }

    func totals(excluding excluded: Set<Int>) -> (renames: Int, copiedFiles: Int, copiedBytes: Int64, trashed: Int, trashedFiles: Int) {
        var totals = (renames: 0, copiedFiles: 0, copiedBytes: Int64(0), trashed: 0, trashedFiles: 0)
        for operation in operations where !excluded.contains(operation.id) {
            switch operation.kind {
            case .rename: totals.renames += 1
            case .copy:
                totals.copiedFiles += operation.fileCount
                totals.copiedBytes += operation.bytes
            case .trash:
                totals.trashed += 1
                totals.trashedFiles += operation.fileCount
            }
        }
        return totals
    }
}

nonisolated enum BatchSyncPlanner {
    /// Plans a sync of `scope` (or of everything when `scope` is nil).
    /// Items at or inside `unreadable` paths (folders or files that couldn't be read while
    /// scanning) are skipped: an unreadable folder looks empty, so its counterpart's contents
    /// would otherwise be planned as extras to trash, or as new files to add.
    static func plan(
        scope: [DiffNode]?,
        tree: [DiffNode],
        moves: MoveMap,
        options: BatchSyncOptions,
        leftRoot: URL,
        rightRoot: URL,
        unreadable: Set<String> = []
    ) -> BatchSyncPlan {
        let plan = options.mode == .merge
            ? planMerge(scope: scope, tree: tree, moves: moves, options: options, leftRoot: leftRoot, rightRoot: rightRoot)
            : planOneWay(scope: scope, tree: tree, moves: moves, options: options, leftRoot: leftRoot, rightRoot: rightRoot)
        return excludingUnreadable(plan, unreadable)
    }

    private static func excludingUnreadable(_ plan: BatchSyncPlan, _ unreadable: Set<String>) -> BatchSyncPlan {
        guard !unreadable.isEmpty else { return plan }
        func touchesUnreadable(_ path: String) -> Bool {
            unreadable.contains { DiffTree.isSameOrDescendant(path, of: $0) || DiffTree.isSameOrDescendant($0, of: path) }
        }
        var filtered = plan
        filtered.operations = []
        for operation in plan.operations {
            if touchesUnreadable(operation.path) || operation.previousPath.map(touchesUnreadable) == true {
                filtered.skipped.append((operation.path, String(localized: "The file couldn’t be read on one or both sides.")))
            } else {
                filtered.operations.append(operation)
            }
        }
        return filtered
    }

    private static func planOneWay(
        scope: [DiffNode]?,
        tree: [DiffNode],
        moves: MoveMap,
        options: BatchSyncOptions,
        leftRoot: URL,
        rightRoot: URL
    ) -> BatchSyncPlan {
        let direction = options.direction
        let destinationRoot = direction.destination == .left ? leftRoot : rightRoot
        let inScope = scopeTest(scope)

        var plan = BatchSyncPlan()
        var nextID = 0
        func add(_ kind: SyncOperation.Kind, path: String, previousPath: String? = nil, isFolder: Bool, fileCount: Int, bytes: Int64,
                 overwrites: Bool = false, steps: [SyncPlan.Step] = [], target: URL? = nil, renameDestination: URL? = nil) {
            plan.operations.append(SyncOperation(
                id: nextID, kind: kind, destination: direction.destination, path: path, previousPath: previousPath, isFolder: isFolder,
                fileCount: fileCount, bytes: bytes, overwrites: overwrites, steps: steps, targetURL: target, renameDestination: renameDestination
            ))
            nextID += 1
        }

        // 1. Moves become renames on the destination. Paths covered by them are excluded
        //    from copying and trashing below.
        var handledSourcePaths: [String] = []
        var handledDestinationPaths: [String] = []
        if options.applyMoves {
            let matches = moves.allMatches.sorted { $0.leftPath < $1.leftPath }
            let exactFolderMoves = matches.filter { $0.isDirectory && $0.isExact }
            for match in matches {
                let sourcePath = direction == .leftToRight ? match.leftPath : match.rightPath
                let currentPath = direction == .leftToRight ? match.rightPath : match.leftPath
                guard inScope(sourcePath) || inScope(currentPath) else { continue }
                if match.isDirectory && !match.isExact { continue }   // its files move one by one
                if !match.isDirectory, exactFolderMoves.contains(where: { folder in
                    DiffTree.isSameOrDescendant(match.leftPath, of: folder.leftPath) && (inScope(direction == .leftToRight ? folder.leftPath : folder.rightPath) || inScope(direction == .leftToRight ? folder.rightPath : folder.leftPath))
                }) { continue }   // moves along with its folder

                let size = DiffTree.node(at: currentPath, in: tree).flatMap { $0.metadata(on: direction.destination)?.size } ?? 0
                add(.rename, path: sourcePath, previousPath: currentPath, isFolder: match.isDirectory,
                    fileCount: match.isDirectory ? match.totalFiles : 1, bytes: size,
                    target: destinationRoot.appending(path: currentPath), renameDestination: destinationRoot.appending(path: sourcePath))
                handledSourcePaths.append(sourcePath)
                handledDestinationPaths.append(currentPath)

                // A file that moved *and* changed still needs its new contents.
                if !match.isExact, !match.isDirectory, options.copyModified,
                   let sourceNode = DiffTree.node(at: sourcePath, in: tree),
                   let sourceURL = sourceNode.url(on: direction.source),
                   let metadata = sourceNode.metadata(on: direction.source) {
                    let destination = destinationRoot.appending(path: sourcePath)
                    add(.copy, path: sourcePath, isFolder: false, fileCount: 1, bytes: metadata.size, overwrites: true,
                        steps: [metadata.kind == .symlink ? .copySymlink(from: sourceURL, to: destination) : .copyFile(from: sourceURL, to: destination)])
                }
            }
        }
        func isHandled(_ path: String, on side: Side) -> Bool {
            let handled = side == direction.source ? handledSourcePaths : handledDestinationPaths
            return handled.contains { DiffTree.isSameOrDescendant(path, of: $0) }
        }

        // 2. Copies and trash, walking the tree.
        func visit(_ node: DiffNode, scoped: Bool) {
            let isScoped = scoped || inScope(node.relativePath)
            let nodeIsSourceOnly = node.status == (direction.source == .left ? .leftOnly : .rightOnly)
            let nodeIsDestinationOnly = node.status == (direction.destination == .left ? .leftOnly : .rightOnly)

            switch node.status {
            case .identical, .ignored:
                return
            case .modified where node.hasKindMismatch:
                if isScoped { plan.skipped.append((node.relativePath, String(localized: "A file and a folder share this name"))) }
                return
            case .modified where node.isDirectory:
                for child in node.children ?? [] { visit(child, scoped: isScoped) }
                return
            case .modified:
                guard isScoped, options.copyModified,
                      let sourceURL = node.url(on: direction.source),
                      let metadata = node.metadata(on: direction.source)
                else { return }
                let destination = node.url(on: direction.destination) ?? destinationRoot.appending(path: node.relativePath)
                add(.copy, path: node.relativePath, isFolder: false, fileCount: 1, bytes: metadata.size, overwrites: true,
                    steps: [metadata.kind == .symlink ? .copySymlink(from: sourceURL, to: destination) : .copyFile(from: sourceURL, to: destination)])
            case .leftOnly, .rightOnly:
                if nodeIsSourceOnly {
                    if isHandled(node.relativePath, on: direction.source) { return }
                    // Something inside moved: handle the children one by one.
                    if node.isDirectory, (node.children ?? []).contains(where: { child in containsHandled(child, side: direction.source) }) {
                        for child in node.children ?? [] { visit(child, scoped: isScoped) }
                        return
                    }
                    guard isScoped, options.copyMissing else {
                        if node.isDirectory, !isScoped { for child in node.children ?? [] { visit(child, scoped: false) } }
                        return
                    }
                    let steps = SyncPlanner.plan(for: node, direction: direction, leftRoot: leftRoot, rightRoot: rightRoot)
                    guard !steps.isEmpty else { return }
                    add(.copy, path: node.relativePath, isFolder: node.isDirectory, fileCount: steps.fileCount,
                        bytes: steps.totalBytes, steps: steps.steps)
                } else if nodeIsDestinationOnly {
                    if isHandled(node.relativePath, on: direction.destination) { return }
                    if node.isDirectory, (node.children ?? []).contains(where: { child in containsHandled(child, side: direction.destination) }) {
                        // When mirroring, the folder is trashed after its moved items have been
                        // renamed out of it, so no empty folder is left behind.
                        if isScoped, options.deleteExtras, let url = node.url(on: direction.destination) {
                            var remaining = 0
                            var bytes: Int64 = 0
                            DiffTree.forEachDepthFirst(node.children ?? []) { child in
                                guard !child.isDirectory, child.status != .ignored, !isHandled(child.relativePath, on: direction.destination) else { return }
                                remaining += 1
                                bytes += child.metadata(on: direction.destination)?.size ?? 0
                            }
                            add(.trash, path: node.relativePath, isFolder: true, fileCount: remaining, bytes: bytes, target: url)
                            return
                        }
                        for child in node.children ?? [] { visit(child, scoped: isScoped) }
                        return
                    }
                    guard isScoped, options.deleteExtras, let url = node.url(on: direction.destination) else {
                        if node.isDirectory, !isScoped { for child in node.children ?? [] { visit(child, scoped: false) } }
                        return
                    }
                    let fileCount = DiffTree.fileCount(in: node)
                    var bytes: Int64 = 0
                    DiffTree.forEachDepthFirst([node]) { bytes += $0.metadata(on: direction.destination)?.size ?? 0 }
                    add(.trash, path: node.relativePath, isFolder: node.isDirectory, fileCount: fileCount, bytes: bytes, target: url)
                }
            }
        }
        func containsHandled(_ node: DiffNode, side: Side) -> Bool {
            if isHandled(node.relativePath, on: side) { return true }
            return (node.children ?? []).contains { containsHandled($0, side: side) }
        }
        for node in tree { visit(node, scoped: false) }
        return plan
    }

    /// Whether a path is inside the scope (everything when `scope` is nil). Nodes inside
    /// another scoped folder are covered by it.
    private static func scopeTest(_ scope: [DiffNode]?) -> (String) -> Bool {
        let scopePaths = scope.map { nodes in
            let paths = Set(nodes.map(\.relativePath))
            return nodes.map(\.relativePath).filter { path in !DiffTree.ancestorPaths(of: path).contains(where: paths.contains) }
        }
        return { path in
            guard let scopePaths else { return true }
            return scopePaths.contains { DiffTree.isSameOrDescendant(path, of: $0) }
        }
    }

    /// Plans a two-way merge: items missing on either side are copied there, and for files
    /// that differ the copy with the newer modification date replaces the older one.
    /// Nothing is trashed. Moved items are left where they are, since copying them would
    /// duplicate them under a second path.
    private static func planMerge(
        scope: [DiffNode]?,
        tree: [DiffNode],
        moves: MoveMap,
        options: BatchSyncOptions,
        leftRoot: URL,
        rightRoot: URL
    ) -> BatchSyncPlan {
        let inScope = scopeTest(scope)
        let leftMoveAncestors = moves.ancestorsOfMoves(on: .left)
        let rightMoveAncestors = moves.ancestorsOfMoves(on: .right)
        var plan = BatchSyncPlan()

        func addCopy(_ node: DiffNode, direction: SyncDirection, overwrites: Bool) {
            let steps: SyncPlan
            if overwrites {
                guard let sourceURL = node.url(on: direction.source), let metadata = node.metadata(on: direction.source),
                      let destination = node.url(on: direction.destination)
                else { return }
                var single = SyncPlan(refreshPaths: [node.relativePath])
                single.steps = [metadata.kind == .symlink ? .copySymlink(from: sourceURL, to: destination) : .copyFile(from: sourceURL, to: destination)]
                single.fileCount = 1
                single.totalBytes = metadata.size
                steps = single
            } else {
                steps = SyncPlanner.plan(for: node, direction: direction, leftRoot: leftRoot, rightRoot: rightRoot)
            }
            guard !steps.isEmpty else { return }
            plan.operations.append(SyncOperation(
                id: plan.operations.count, kind: .copy, destination: direction.destination, path: node.relativePath,
                previousPath: nil, isFolder: node.isDirectory, fileCount: steps.fileCount, bytes: steps.totalBytes,
                overwrites: overwrites, steps: steps.steps, targetURL: nil, renameDestination: nil
            ))
        }

        func visit(_ node: DiffNode, scoped: Bool) {
            let isScoped = scoped || inScope(node.relativePath)
            switch node.status {
            case .identical, .ignored:
                return
            case .modified where node.hasKindMismatch:
                if isScoped { plan.skipped.append((node.relativePath, String(localized: "A file and a folder share this name"))) }
            case .modified where node.isDirectory:
                for child in node.children ?? [] { visit(child, scoped: isScoped) }
            case .modified:
                guard isScoped, options.copyModified else { return }
                let leftDate = node.leftMetadata?.modificationDate
                let rightDate = node.rightMetadata?.modificationDate
                guard let leftDate, let rightDate,
                      abs(leftDate.timeIntervalSince(rightDate)) > ComparisonMethod.modificationDateTolerance
                else {
                    plan.skipped.append((node.relativePath, String(localized: "Changed on both sides at about the same time: sync it one way or copy it from the diff")))
                    return
                }
                addCopy(node, direction: leftDate > rightDate ? .leftToRight : .rightToLeft, overwrites: true)
            case .leftOnly, .rightOnly:
                let side: Side = node.status == .leftOnly ? .left : .right
                let isMoved = side == .left ? moves.byLeftPath[node.relativePath] != nil : moves.byRightPath[node.relativePath] != nil
                let containsMoves = (side == .left ? leftMoveAncestors : rightMoveAncestors).contains(node.relativePath)
                // A moved item (or a moved folder with everything in it) stays where it is.
                if isMoved { return }
                if containsMoves {
                    // Copy what didn't move, item by item.
                    for child in node.children ?? [] { visit(child, scoped: isScoped) }
                    return
                }
                guard options.copyMissing else { return }
                guard isScoped else {
                    if node.isDirectory { for child in node.children ?? [] { visit(child, scoped: false) } }
                    return
                }
                addCopy(node, direction: side == .left ? .leftToRight : .rightToLeft, overwrites: false)
            }
        }
        for node in tree { visit(node, scoped: false) }
        return plan
    }

    /// A plain-text dry-run listing, for sharing or review.
    static func describe(_ plan: BatchSyncPlan, excluding excluded: Set<Int>, options: BatchSyncOptions, leftName: String, rightName: String) -> String {
        let header = switch options.mode {
        case .merge: "Merge \(leftName) ⇄ \(rightName) (dry run)"
        case .oneWay: options.direction == .leftToRight ? "Sync \(leftName) → \(rightName) (dry run)" : "Sync \(rightName) → \(leftName) (dry run)"
        }
        var lines = [header, ""]
        for operation in plan.operations where !excluded.contains(operation.id) {
            var suffix = operation.isFolder ? "/ (\(operation.fileCount) files)" : ""
            if options.mode == .merge { suffix += "  → \(operation.destination == .left ? leftName : rightName)" }
            switch operation.kind {
            case .rename: lines.append("RENAME  \(operation.previousPath ?? "")\(operation.isFolder ? "/" : "") → \(operation.path)\(suffix)")
            case .copy: lines.append("\(operation.overwrites ? "UPDATE" : "ADD   ")  \(operation.path)\(suffix)")
            case .trash: lines.append("TRASH   \(operation.path)\(suffix)")
            }
        }
        for skipped in plan.skipped {
            lines.append("SKIP    \(skipped.path) — \(skipped.reason)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// What an executed sync did, for undo.
nonisolated struct BatchSyncRecord: Sendable {
    var renames: [(from: URL, to: URL, createdFolders: [URL])] = []
    /// State of every overwritten, created or trashed path before the change; `nil` when
    /// it would have exceeded the undo size limit.
    var snapshots: [FileSnapshot]? = []
    var completedOperations = 0
    /// Copying or trashing began, so files may have changed even when no operation finished
    /// (a large folder copy that was stopped or failed halfway).
    var startedWriting = false

    var changedAnything: Bool { completedOperations > 0 || startedWriting }
}

nonisolated struct BatchSyncProgress: Sendable, Equatable {
    var completed = 0
    var total = 0
    var currentPath = ""
}

nonisolated extension FileManagerService {
    /// Runs a plan: renames first, then copies, then trash (deepest first). Stops between
    /// operations when cancelled; the returned record covers what was done either way.
    @concurrent
    func execute(
        _ plan: BatchSyncPlan,
        excluding excluded: Set<Int>,
        snapshotLimit: Int64 = FileManagerService.undoSnapshotLimit,
        progress: @escaping @Sendable (BatchSyncProgress) -> Void
    ) async -> (record: BatchSyncRecord, error: Error?) {
        let operations = plan.operations.filter { !excluded.contains($0.id) }
        let renames = operations.filter { $0.kind == .rename }.sorted { $0.path < $1.path }
        let copies = operations.filter { $0.kind == .copy }
        let trash = operations.filter { $0.kind == .trash }.sorted { $0.path.count > $1.path.count }
        var record = BatchSyncRecord()
        var state = BatchSyncProgress(total: operations.count)
        let fileManager = FileManager()

        do {
            for operation in renames {
                try Task.checkCancellation()
                guard let from = operation.targetURL, let to = operation.renameDestination else { continue }
                state.currentPath = operation.path
                progress(state)
                let created = try await moveItem(from: from, to: to)
                record.renames.append((from, to, created))
                record.completedOperations += 1
                state.completed += 1
            }

            // Snapshots are taken after renames, so undo can restore contents first and then
            // rename back.
            var snapshotTargets: [URL] = copies.flatMap { $0.steps.map(\.destination) }
            for operation in trash {
                guard let url = operation.targetURL else { continue }
                snapshotTargets.append(contentsOf: Self.treeURLs(at: url, fileManager: fileManager))
            }
            record.snapshots = try await capture(snapshotTargets, limit: snapshotLimit)
            record.startedWriting = true

            for operation in copies {
                try Task.checkCancellation()
                state.currentPath = operation.path
                progress(state)
                try await execute(SyncPlan(steps: operation.steps))
                record.completedOperations += 1
                state.completed += 1
            }
            for operation in trash {
                try Task.checkCancellation()
                guard let url = operation.targetURL else { continue }
                state.currentPath = operation.path
                progress(state)
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                record.completedOperations += 1
                state.completed += 1
            }
            state.currentPath = ""
            progress(state)
            return (record, nil)
        } catch {
            return (record, error)
        }
    }

    /// Reverses a sync: restores contents, then undoes renames in reverse order.
    @concurrent
    func revert(_ record: BatchSyncRecord) async throws {
        if let snapshots = record.snapshots {
            try await restore(snapshots)
        }
        for rename in record.renames.reversed() {
            _ = try await moveItem(from: rename.to, to: rename.from)
            await removeEmptyDirectories(rename.createdFolders)
        }
    }

    /// A folder and everything inside it (or just the URL for a file).
    static func treeURLs(at url: URL) -> [URL] {
        treeURLs(at: url, fileManager: FileManager())
    }

    private static func treeURLs(at url: URL, fileManager: FileManager) -> [URL] {
        var urls = [url]
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) {
            while let child = enumerator.nextObject() as? URL { urls.append(child) }
        }
        return urls
    }
}

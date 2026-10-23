//
//  FileManagerService.swift
//  PathDiff
//

import Foundation

nonisolated enum SyncDirection: String, Sendable, Hashable, Codable {
    case leftToRight
    case rightToLeft

    var source: Side { self == .leftToRight ? .left : .right }
    var destination: Side { self == .leftToRight ? .right : .left }
    var title: String { self == .leftToRight ? String(localized: "Left → Right") : String(localized: "Right → Left") }
}

nonisolated enum FileOperationError: LocalizedError {
    case fileChangedOnDisk(String)
    case destinationExists(String)

    var errorDescription: String? {
        switch self {
        case .fileChangedOnDisk(let name):
            String(localized: "“\(name)” changed on disk after it was loaded. The diff has been reloaded; please review it and try again.")
        case .destinationExists(let path):
            String(localized: "Something already exists at “\(path)”.")
        }
    }
}

/// The state of one path before a write, used to undo (and redo) file operations.
nonisolated struct FileSnapshot: Sendable {
    enum State: Sendable {
        case file(Data, permissions: Int?)
        case symlink(destination: String)
        case directory
        case missing
    }

    let url: URL
    let state: State
}

/// The concrete steps for copying a node (and, for folders, its differing contents).
nonisolated struct SyncPlan: Sendable {
    enum Step: Sendable {
        case createDirectory(URL)
        /// `replacing` is false when the destination didn't exist when planned. If something
        /// is there by the time the step runs (it appeared since, or the name differs only in
        /// case on a case-insensitive volume), the step refuses rather than overwrite it.
        case copyFile(from: URL, to: URL, replacing: Bool = true)
        case copySymlink(from: URL, to: URL, replacing: Bool = true)

        var destination: URL {
            switch self {
            case .createDirectory(let url): url
            case .copyFile(_, let url, _), .copySymlink(_, let url, _): url
            }
        }
    }

    var steps: [Step] = []
    var fileCount = 0
    var directoryCount = 0
    var totalBytes: Int64 = 0
    /// Size of the destination files that will be replaced: what undo has to back up.
    var replacedBytes: Int64 = 0
    /// Items skipped because a file and a folder share a name.
    var skippedCount = 0
    /// The shallowest paths whose tree nodes must be rescanned afterwards.
    var refreshPaths: Set<String> = []

    var isEmpty: Bool { steps.isEmpty }
    var destinationURLs: [URL] { steps.map(\.destination) }

    /// Appends another plan, skipping folders that are already being created.
    mutating func merge(_ other: SyncPlan) {
        let existingFolders = Set(steps.compactMap { step -> String? in
            if case .createDirectory(let url) = step { return url.path(percentEncoded: false) }
            return nil
        })
        for step in other.steps {
            if case .createDirectory(let url) = step, existingFolders.contains(url.path(percentEncoded: false)) { continue }
            if case .createDirectory = step { directoryCount += 1 }
            steps.append(step)
        }
        fileCount += other.fileCount
        totalBytes += other.totalBytes
        replacedBytes += other.replacedBytes
        skippedCount += other.skippedCount
        refreshPaths.formUnion(other.refreshPaths)
    }
}

nonisolated enum SyncPlanner {
    /// Plans copying `node` in `direction`. Only differing items are copied; items that exist
    /// only on the destination side are left untouched (nothing is ever deleted).
    /// Plans several nodes at once; nodes inside another selected folder are covered by it.
    static func plan(for nodes: [DiffNode], direction: SyncDirection, leftRoot: URL, rightRoot: URL) -> SyncPlan {
        let paths = Set(nodes.map(\.relativePath))
        let topLevel = nodes
            .filter { node in !DiffTree.ancestorPaths(of: node.relativePath).contains(where: paths.contains) }
            .sorted { $0.relativePath < $1.relativePath }
        var combined = SyncPlan()
        for node in topLevel {
            combined.merge(plan(for: node, direction: direction, leftRoot: leftRoot, rightRoot: rightRoot))
        }
        return combined
    }

    static func plan(for node: DiffNode, direction: SyncDirection, leftRoot: URL, rightRoot: URL) -> SyncPlan {
        let destinationRoot = direction.destination == .left ? leftRoot : rightRoot
        var refreshPath = node.relativePath

        // Parent folders that don't exist yet on the destination side.
        let fileManager = FileManager()
        var missingAncestors: [URL] = []
        var ancestor = DiffTree.parentPath(of: node.relativePath)
        while !ancestor.isEmpty {
            let url = destinationRoot.appending(path: ancestor)
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) { break }
            missingAncestors.insert(url, at: 0)
            refreshPath = ancestor
            ancestor = DiffTree.parentPath(of: ancestor)
        }

        var body = SyncPlan(refreshPaths: [refreshPath])
        collect(node, direction: direction, destinationRoot: destinationRoot, into: &body)
        guard !body.isEmpty else { return body }

        var plan = SyncPlan(refreshPaths: [refreshPath])
        plan.steps = missingAncestors.map { .createDirectory($0) } + body.steps
        plan.directoryCount = missingAncestors.count + body.directoryCount
        plan.fileCount = body.fileCount
        plan.totalBytes = body.totalBytes
        plan.replacedBytes = body.replacedBytes
        plan.skippedCount = body.skippedCount
        return plan
    }

    private static func collect(_ node: DiffNode, direction: SyncDirection, destinationRoot: URL, into plan: inout SyncPlan) {
        guard node.status != .ignored, node.status != .identical else { return }
        guard let sourceURL = node.url(on: direction.source),
              let sourceMetadata = node.metadata(on: direction.source)
        else { return }
        let destinationMetadata = node.metadata(on: direction.destination)
        let destinationURL = node.url(on: direction.destination) ?? destinationRoot.appending(path: node.relativePath)

        switch sourceMetadata.kind {
        case .directory:
            if let destinationMetadata, destinationMetadata.kind != .directory {
                plan.skippedCount += 1
                return
            }
            if destinationMetadata == nil {
                plan.steps.append(.createDirectory(destinationURL))
                plan.directoryCount += 1
            }
            for child in node.children ?? [] {
                collect(child, direction: direction, destinationRoot: destinationRoot, into: &plan)
            }
        case .file, .symlink:
            if destinationMetadata?.kind == .directory {
                plan.skippedCount += 1
                return
            }
            let replacing = destinationMetadata != nil
            plan.steps.append(sourceMetadata.kind == .file
                ? .copyFile(from: sourceURL, to: destinationURL, replacing: replacing)
                : .copySymlink(from: sourceURL, to: destinationURL, replacing: replacing))
            plan.fileCount += 1
            plan.totalBytes += sourceMetadata.size
            plan.replacedBytes += destinationMetadata?.size ?? 0
        }
    }
}

/// All file-system writes. Heavy work runs off the main actor.
nonisolated struct FileManagerService: Sendable {
    /// Undo is only offered when the overwritten content fits in this budget.
    static let undoSnapshotLimit: Int64 = 128 * 1024 * 1024

    /// Captures the current state of `urls`, or returns `nil` if their contents exceed `limit`.
    @concurrent
    func capture(_ urls: [URL], limit: Int64 = undoSnapshotLimit) async throws -> [FileSnapshot]? {
        var total: Int64 = 0
        var snapshots: [FileSnapshot] = []
        for url in urls {
            try Task.checkCancellation()
            let snapshot = try Self.snapshot(of: url)
            if case .file(let data, _) = snapshot.state {
                total += Int64(data.count)
                if total > limit { return nil }
            }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    /// The state, right now, of the paths that were missing in `snapshots` (taken before a
    /// write), i.e. the items the write created.
    @concurrent
    static func createdStates(of snapshots: [FileSnapshot]) async -> [URL: HistoryAfterState] {
        var states: [URL: HistoryAfterState] = [:]
        for snapshot in snapshots {
            if case .missing = snapshot.state {
                states[snapshot.url] = HistoryAfterState.current(at: snapshot.url.path(percentEncoded: false))
            }
        }
        return states
    }

    /// Puts every path back into its captured state. Paths that didn't exist are removed;
    /// those whose state differs from `created` (edited since) go to the Trash instead.
    @concurrent
    func restore(_ snapshots: [FileSnapshot], created: [URL: HistoryAfterState] = [:]) async throws {
        let fileManager = FileManager()
        let byDepth = snapshots.sorted { $0.url.pathComponents.count < $1.url.pathComponents.count }

        for snapshot in byDepth {
            if case .directory = snapshot.state {
                try fileManager.createDirectory(at: snapshot.url, withIntermediateDirectories: true)
            }
        }
        for snapshot in byDepth {
            switch snapshot.state {
            case .file(let data, let permissions):
                try Self.writeAtomically(data, to: snapshot.url, permissions: permissions)
            case .symlink(let destination):
                try Self.replaceSymlink(at: snapshot.url, destination: destination)
            case .directory, .missing:
                break
            }
        }
        for snapshot in byDepth.reversed() {
            if case .missing = snapshot.state {
                try Self.removeItemCreatedByUs(at: snapshot.url, expected: created[snapshot.url])
            }
        }
    }

    /// Whether the file still decodes to `expected` (it wasn't changed by someone else).
    @concurrent
    func isUnchanged(_ url: URL, expected: TextDocument) async -> Bool {
        guard let data = try? Data(contentsOf: url), let decoded = TextDocument.decode(data) else { return false }
        return decoded == expected
    }

    /// Writes an edited document, refusing if the file changed since `expected` was read
    /// (pass `nil` to overwrite whatever is there).
    @concurrent
    func write(_ document: TextDocument, to url: URL, expecting expected: TextDocument?) async throws {
        if let expected {
            let current = try Data(contentsOf: url)
            guard let decoded = TextDocument.decode(current), decoded == expected else {
                throw FileOperationError.fileChangedOnDisk(url.lastPathComponent)
            }
        }
        let data = try document.encodedData()
        try Self.writeAtomically(data, to: url, permissions: Self.permissions(of: url))
    }

    @concurrent
    func execute(_ plan: SyncPlan) async throws {
        let fileManager = FileManager()
        for step in plan.steps {
            try Task.checkCancellation()
            switch step {
            case .createDirectory(let url):
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            case .copyFile(let source, let destination, let replacing):
                if !replacing { try Self.refuseIfExists(destination) }
                try Self.copyFile(from: source, to: destination)
            case .copySymlink(let source, let destination, let replacing):
                if !replacing { try Self.refuseIfExists(destination) }
                let target = try fileManager.destinationOfSymbolicLink(atPath: source.path(percentEncoded: false))
                try Self.replaceSymlink(at: destination, destination: target)
            }
        }
    }

    @concurrent
    func moveToTrash(_ urls: [URL]) async throws {
        let fileManager = FileManager()
        for url in urls {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
    }

    @concurrent
    func writeText(_ text: String, to url: URL) async throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Moves (renames) an item within one tree, creating missing parent folders.
    /// Returns the folders that had to be created, shallowest first.
    @concurrent
    func moveItem(from source: URL, to destination: URL) async throws -> [URL] {
        let fileManager = FileManager()
        if let existing = try? fileManager.attributesOfItem(atPath: destination.path(percentEncoded: false)) {
            // On a case-insensitive volume "foo" → "Foo" finds the item itself at the
            // destination. Rename it through a temporary name; anything else is a collision.
            let current = try? fileManager.attributesOfItem(atPath: source.path(percentEncoded: false))
            guard let current, Self.isSameItem(current, existing) else {
                throw FileOperationError.destinationExists(destination.lastPathComponent)
            }
            let temporary = source.deletingLastPathComponent().appending(path: ".\(source.lastPathComponent).pathdiff-\(UUID().uuidString)")
            try fileManager.moveItem(at: source, to: temporary)
            do {
                try fileManager.moveItem(at: temporary, to: destination)
            } catch {
                try? fileManager.moveItem(at: temporary, to: source)
                throw error
            }
            return []
        }
        var created: [URL] = []
        var parent = destination.deletingLastPathComponent()
        while !fileManager.fileExists(atPath: parent.path(percentEncoded: false)) {
            created.insert(parent, at: 0)
            parent = parent.deletingLastPathComponent()
        }
        if !created.isEmpty {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try fileManager.moveItem(at: source, to: destination)
        return created
    }

    /// Removes folders (deepest first) that are empty apart from Finder metadata.
    @concurrent
    func removeEmptyDirectories(_ urls: [URL]) async {
        let fileManager = FileManager()
        for url in urls.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            let contents = (try? fileManager.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? ["?"]
            if contents.allSatisfy({ $0 == ".DS_Store" }) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: Primitives

    static func snapshot(of url: URL) throws -> FileSnapshot {
        let fileManager = FileManager()
        let path = url.path(percentEncoded: false)
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return FileSnapshot(url: url, state: .missing)
        }
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory:
            return FileSnapshot(url: url, state: .directory)
        case .typeSymbolicLink:
            return FileSnapshot(url: url, state: .symlink(destination: try fileManager.destinationOfSymbolicLink(atPath: path)))
        default:
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            return FileSnapshot(url: url, state: .file(try Data(contentsOf: url), permissions: permissions))
        }
    }

    static func permissions(of url: URL) -> Int? {
        let attributes = try? FileManager().attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    static func isSymlink(_ url: URL) -> Bool {
        let attributes = try? FileManager().attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// Writes through a temporary file and an atomic rename, then restores POSIX permissions
    /// (an atomic replace would otherwise drop e.g. the executable bit).
    static func writeAtomically(_ data: Data, to url: URL, permissions: Int?) throws {
        let fileManager = FileManager()
        try refuseToReplaceFolder(at: url)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if isSymlink(url) {
            try fileManager.removeItem(at: url)
        }
        try data.write(to: url, options: .atomic)
        if let permissions {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    /// Copies via a sibling temporary file so the destination is replaced in one step and
    /// never left half-written. The copy keeps the source's permissions and attributes.
    static func copyFile(from source: URL, to destination: URL) throws {
        let fileManager = FileManager()
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try refuseToReplaceFolder(at: destination)
        let temporary = directory.appending(path: ".\(destination.lastPathComponent).pathdiff-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: source, to: temporary)
            let destinationExists = (try? fileManager.attributesOfItem(atPath: destination.path(percentEncoded: false))) != nil
            if destinationExists && !isSymlink(destination) {
                do {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [.usingNewMetadataOnly])
                } catch {
                    try fileManager.removeItem(at: destination)
                    try fileManager.moveItem(at: temporary, to: destination)
                }
            } else {
                if destinationExists { try fileManager.removeItem(at: destination) }
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    static func replaceSymlink(at url: URL, destination: String) throws {
        let fileManager = FileManager()
        try refuseToReplaceFolder(at: url)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil {
            try fileManager.removeItem(at: url)
        }
        try fileManager.createSymbolicLink(atPath: url.path(percentEncoded: false), withDestinationPath: destination)
    }

    /// Whether two attribute sets describe the same file system object (volume and inode).
    static func isSameItem(_ lhs: [FileAttributeKey: Any], _ rhs: [FileAttributeKey: Any]) -> Bool {
        guard let lhsVolume = lhs[.systemNumber] as? NSNumber, let rhsVolume = rhs[.systemNumber] as? NSNumber,
              let lhsFile = lhs[.systemFileNumber] as? NSNumber, let rhsFile = rhs[.systemFileNumber] as? NSNumber
        else { return false }
        return lhsVolume == rhsVolume && lhsFile == rhsFile
    }

    static func refuseIfExists(_ url: URL) throws {
        if (try? FileManager().attributesOfItem(atPath: url.path(percentEncoded: false))) != nil {
            throw FileOperationError.destinationExists(url.lastPathComponent)
        }
    }

    /// A file or link write never replaces a folder: the folder (and everything in it) would
    /// be deleted, not moved to the Trash. This happens when a folder appeared at the path
    /// after the operation was planned.
    static func refuseToReplaceFolder(at url: URL) throws {
        let attributes = try? FileManager().attributesOfItem(atPath: url.path(percentEncoded: false))
        if attributes?[.type] as? FileAttributeType == .typeDirectory {
            throw FileOperationError.destinationExists(url.lastPathComponent)
        }
    }

    /// Removes an item that an undone operation created. Folders that gained other content in
    /// the meantime go to the Trash instead of being deleted, and so do files that changed
    /// since the operation (`expected` is their state right after it, when known).
    static func removeItemCreatedByUs(at url: URL, expected: HistoryAfterState? = nil) throws {
        let fileManager = FileManager()
        let path = url.path(percentEncoded: false)
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return }
        if let expected, HistoryAfterState.current(at: path) != expected {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
            return
        }
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            let contents = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
            if contents.allSatisfy({ $0 == ".DS_Store" }) {
                try fileManager.removeItem(at: url)
            } else {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
            }
        } else {
            try fileManager.removeItem(at: url)
        }
    }
}

//
//  FolderScanner.swift
//  PathDiff
//

import CryptoKit
import Foundation
import Synchronization

nonisolated struct ScanProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case idle
        case enumerating
        case comparing
        case finished
    }

    var phase: Phase = .idle
    var itemsDiscovered = 0
    var filesToCompare = 0
    var filesCompared = 0
    /// Files proven identical (or different) from git's index without reading them.
    var filesResolvedByGitIndex = 0
}

/// Something that couldn't be read during a scan.
nonisolated struct ScanIssue: Sendable, Hashable, Identifiable {
    let path: String
    /// `nil` when it concerns comparing both sides.
    let side: Side?
    let message: String

    var id: String { (side?.rawValue ?? "both") + ":" + path }
}

nonisolated enum ScanError: LocalizedError {
    case folderUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable(let path):
            String(localized: "The folder “\(path)” can’t be read. It may have been moved, deleted or disconnected.")
        }
    }
}

nonisolated struct ScanOutcome: Sendable {
    let nodes: [DiffNode]
    let issues: [ScanIssue]
}

/// What decides which items are skipped during a walk.
nonisolated struct ScanRules: Sendable {
    let matcher: IgnoreMatcher
    /// Honor each tree's own `.gitignore` files and `.git/info/exclude`.
    let respectsGitIgnore: Bool
    /// Use each tree's `.git/index` to skip reading files git knows are unchanged.
    var usesGitIndex = true
}

/// Crawls the left and right folders concurrently, compares files that exist on both sides
/// and merges everything into a single `DiffNode` tree.
///
/// The actor keeps caches so repeated scans of huge trees only read files that changed:
/// - comparison results keyed by both files' size, modification date and inode, also
///   persisted between launches through `ComparisonCacheStore`;
/// - content digests used by move detection.
actor FolderScanner {
    typealias ProgressHandler = @Sendable (ScanProgress) -> Void

    private struct ComparisonKey: Hashable {
        let path: String
        let left: FileStamp
        let right: FileStamp
        let options: DiffOptions
    }

    private var comparisonCache: [ComparisonKey: Bool] = [:]
    private var gitIndexes: GitIndexPair?
    private var digestCache: [String: (FileStamp, SHA256.Digest)] = [:]
    private let cacheStore: ComparisonCacheStore?
    /// The folder pair and options whose persisted results were merged into memory.
    private var loadedCacheIdentity: URL?

    /// - Parameter cacheDirectory: where comparison results are persisted between launches;
    ///   `nil` keeps them in memory only.
    init(cacheDirectory: URL? = ComparisonCacheStore.defaultDirectory) {
        cacheStore = cacheDirectory.map(ComparisonCacheStore.init(directory:))
    }

    /// Forgets every remembered result for a folder pair, in memory and on disk.
    func clearCaches(leftRoot: URL, rightRoot: URL) {
        comparisonCache = [:]
        digestCache = [:]
        loadedCacheIdentity = nil
        cacheStore?.remove(leftRoot: leftRoot, rightRoot: rightRoot)
    }

    func scan(
        leftRoot: URL,
        rightRoot: URL,
        rules: ScanRules,
        options: DiffOptions,
        progress: ProgressHandler? = nil
    ) async throws -> ScanOutcome {
        let reporter = ProgressReporter(handler: progress)
        reporter.update { $0.phase = .enumerating }
        await loadPersistedResults(leftRoot: leftRoot, rightRoot: rightRoot, options: options)

        async let leftWalk = ScanEngine.walkRoot(leftRoot, side: .left, rules: rules, reporter: reporter)
        async let rightWalk = ScanEngine.walkRoot(rightRoot, side: .right, rules: rules, reporter: reporter)
        async let leftIndex = rules.usesGitIndex ? ScanEngine.loadGitIndex(leftRoot) : nil
        async let rightIndex = rules.usesGitIndex ? ScanEngine.loadGitIndex(rightRoot) : nil
        let (left, right) = try await (leftWalk, rightWalk)
        gitIndexes = await GitIndexPair(left: leftIndex, right: rightIndex)

        var jobs: [ComparisonJob] = []
        ScanEngine.collectJobs(left: left, right: right, parentPath: "", into: &jobs)
        reporter.update {
            $0.phase = .comparing
            $0.filesToCompare = jobs.count
        }
        let results = try await compare(jobs, options: options, reporter: reporter, replacingCache: true)
        let nodes = await ScanEngine.makeNodes(left: left, right: right, parentPath: "", results: results, depth: 0)
        reporter.update { $0.phase = .finished }
        persistResults(leftRoot: leftRoot, rightRoot: rightRoot, options: options)
        return ScanOutcome(nodes: nodes, issues: reporter.issues)
    }

    private func loadPersistedResults(leftRoot: URL, rightRoot: URL, options: DiffOptions) async {
        guard let cacheStore else { return }
        let identity = cacheStore.fileURL(leftRoot: leftRoot, rightRoot: rightRoot, options: options)
        guard identity != loadedCacheIdentity else { return }
        loadedCacheIdentity = identity
        let entries = await ScanEngine.loadCache(cacheStore, leftRoot: leftRoot, rightRoot: rightRoot, options: options)
        for (path, entry) in entries {
            comparisonCache[ComparisonKey(path: path, left: entry.left, right: entry.right, options: options)] = entry.isEqual
        }
    }

    private func persistResults(leftRoot: URL, rightRoot: URL, options: DiffOptions) {
        guard let cacheStore else { return }
        var entries: [String: CachedComparison] = [:]
        entries.reserveCapacity(comparisonCache.count)
        for (key, isEqual) in comparisonCache where key.options == options {
            entries[key.path] = CachedComparison(left: key.left, right: key.right, isEqual: isEqual)
        }
        Task.detached(priority: .utility) {
            cacheStore.save(entries, leftRoot: leftRoot, rightRoot: rightRoot, options: options)
        }
    }

    /// Rescans a single item (file or folder subtree) on both sides.
    /// Returns `nil` when the item no longer exists on either side.
    func scanItem(
        relativePath: String,
        leftRoot: URL,
        rightRoot: URL,
        rules: ScanRules,
        options: DiffOptions
    ) async throws -> (node: DiffNode?, issues: [ScanIssue]) {
        guard let name = DiffTree.components(of: relativePath).last else { return (nil, []) }
        let reporter = ProgressReporter(handler: nil)

        async let leftScan = ScanEngine.scanSingleItem(root: leftRoot, side: .left, relativePath: relativePath, name: name, rules: rules, reporter: reporter)
        async let rightScan = ScanEngine.scanSingleItem(root: rightRoot, side: .right, relativePath: relativePath, name: name, rules: rules, reporter: reporter)
        let (left, right) = try await (leftScan, rightScan)
        guard left != nil || right != nil else { return (nil, reporter.issues) }

        var jobs: [ComparisonJob] = []
        ScanEngine.collectJobs(
            left: left.map { [name: $0] },
            right: right.map { [name: $0] },
            parentPath: DiffTree.parentPath(of: relativePath),
            into: &jobs
        )
        let results = try await compare(jobs, options: options, reporter: reporter, replacingCache: false)
        return (ScanEngine.makeNode(name: name, relativePath: relativePath, left: left, right: right, results: results), reporter.issues)
    }

    /// Answers from the cache where possible and compares the rest in parallel.
    private func compare(_ jobs: [ComparisonJob], options: DiffOptions, reporter: ProgressReporter?, replacingCache: Bool) async throws -> [String: Bool] {
        var results: [String: Bool] = [:]
        results.reserveCapacity(jobs.count)
        var pending: [ComparisonJob] = []
        var keys: [ComparisonKey?] = []

        for job in jobs {
            let key = Self.cacheKey(for: job, options: options)
            if let key, let cached = comparisonCache[key] {
                results[job.relativePath] = cached
            } else {
                pending.append(job)
                keys.append(key)
            }
        }
        reporter?.filesCompared(jobs.count - pending.count)
        // Reading in inode order follows the on-disk layout closely enough to roughly halve
        // the time for large trees of small files compared to hash-table order.
        let order = pending.indices.sorted {
            (pending[$0].leftMetadata.fileIdentifier ?? 0) < (pending[$1].leftMetadata.fileIdentifier ?? 0)
        }
        pending = order.map { pending[$0] }
        keys = order.map { keys[$0] }

        let fresh = try await ScanEngine.runComparisons(pending, options: options, gitIndexes: gitIndexes, reporter: reporter)
        var newCache: [ComparisonKey: Bool] = [:]
        if replacingCache {
            // Keep only entries for files that still exist, so the cache can't grow forever.
            newCache.reserveCapacity(jobs.count)
            for job in jobs {
                if let key = Self.cacheKey(for: job, options: options), let result = results[job.relativePath] {
                    newCache[key] = result
                }
            }
        }
        for (index, job) in pending.enumerated() {
            results[job.relativePath] = fresh[index]
            if let key = keys[index] {
                if replacingCache { newCache[key] = fresh[index] } else { comparisonCache[key] = fresh[index] }
            }
        }
        if replacingCache { comparisonCache = newCache }
        return results
    }

    private static func cacheKey(for job: ComparisonJob, options: DiffOptions) -> ComparisonKey? {
        guard let left = job.leftMetadata.stamp, let right = job.rightMetadata.stamp else { return nil }
        // A file modified in the last few seconds can be rewritten within its timestamp's
        // resolution (1–2 s on HFS+, FAT and exFAT) without its stamp changing, so its result
        // isn't remembered yet (like git's "racily clean" check).
        let settled = Date.now.timeIntervalSinceReferenceDate - 3
        guard left.modified < settled, right.modified < settled else { return nil }
        return ComparisonKey(path: job.relativePath, left: left, right: right, options: options)
    }

    // MARK: Move detection

    /// Matches left-only files with right-only files: first by identical contents, then by
    /// a unique shared file name with mostly the same lines (or, for photos, videos and audio,
    /// a unique shared name). Folders whose files moved together are reported as folder moves.
    ///
    /// With the quick comparison method, files with the same name, size and modification
    /// date are paired as exact moves without being read.
    func detectMoves(in nodes: [DiffNode], method: ComparisonMethod = .contents) async throws -> MoveMap {
        var leftFiles: [MoveCandidate] = []
        var rightFiles: [MoveCandidate] = []
        DiffTree.forEachDepthFirst(nodes) { node in
            guard !node.isDirectory, !node.isSymlink else { return }
            if node.status == .leftOnly, let url = node.leftURL, let metadata = node.leftMetadata {
                leftFiles.append(MoveCandidate(path: node.relativePath, name: node.name, url: url, metadata: metadata))
            } else if node.status == .rightOnly, let url = node.rightURL, let metadata = node.rightMetadata {
                rightFiles.append(MoveCandidate(path: node.relativePath, name: node.name, url: url, metadata: metadata))
            }
        }
        guard !leftFiles.isEmpty, !rightFiles.isEmpty else { return MoveMap() }

        var map = MoveMap()
        var matchedLeft = Set<String>()
        var matchedRight = Set<String>()

        // 0. Quick method: same name, size and modification date.
        if method == .quick {
            for (leftPath, rightPath) in ScanEngine.quickMovePairs(left: leftFiles, right: rightFiles) {
                map.insert(MoveMatch(leftPath: leftPath, rightPath: rightPath, isExact: true, isDirectory: false))
                matchedLeft.insert(leftPath)
                matchedRight.insert(rightPath)
            }
        }

        // 1. Exact moves: only files whose size exists on both sides need hashing.
        let hashableLeft = leftFiles.filter { !matchedLeft.contains($0.path) }
        let hashableRight = rightFiles.filter { !matchedRight.contains($0.path) }
        let rightSizes = Set(hashableRight.map(\.metadata.size))
        let leftSizes = Set(hashableLeft.map(\.metadata.size))
        let toHash = hashableLeft.filter { $0.metadata.size > 0 && rightSizes.contains($0.metadata.size) }.map { ("L:", $0) }
            + hashableRight.filter { $0.metadata.size > 0 && leftSizes.contains($0.metadata.size) }.map { ("R:", $0) }
        let digests = try await digests(for: toHash)

        var rightByDigest: [SHA256.Digest: [MoveCandidate]] = [:]
        for candidate in hashableRight {
            if let digest = digests["R:" + candidate.path] { rightByDigest[digest, default: []].append(candidate) }
        }
        for candidate in hashableLeft {
            guard let digest = digests["L:" + candidate.path], var options = rightByDigest[digest], !options.isEmpty else { continue }
            // Prefer a counterpart with the same file name.
            let index = options.firstIndex { $0.name == candidate.name } ?? 0
            let counterpart = options.remove(at: index)
            rightByDigest[digest] = options
            map.insert(MoveMatch(leftPath: candidate.path, rightPath: counterpart.path, isExact: true, isDirectory: false))
            matchedLeft.insert(candidate.path)
            matchedRight.insert(counterpart.path)
        }

        // 2. Moved and edited: same name on both sides, mostly the same lines.
        let unmatchedLeft = Dictionary(grouping: leftFiles.filter { !matchedLeft.contains($0.path) }, by: \.name)
        let unmatchedRight = Dictionary(grouping: rightFiles.filter { !matchedRight.contains($0.path) }, by: \.name)
        let similarPairs = try await ScanEngine.similarPairs(left: unmatchedLeft, right: unmatchedRight)
        for (leftPath, rightPath) in similarPairs {
            map.insert(MoveMatch(leftPath: leftPath, rightPath: rightPath, isExact: false, isDirectory: false))
            matchedLeft.insert(leftPath)
            matchedRight.insert(rightPath)
        }

        // 2b. Renamed and edited in place: different names in the same folder, mostly the same lines.
        let remainingLeft = Dictionary(grouping: leftFiles.filter { !matchedLeft.contains($0.path) }) { DiffTree.parentPath(of: $0.path) }
        let remainingRight = Dictionary(grouping: rightFiles.filter { !matchedRight.contains($0.path) }) { DiffTree.parentPath(of: $0.path) }
        for (leftPath, rightPath) in try await ScanEngine.similarPairs(left: remainingLeft, right: remainingRight) {
            map.insert(MoveMatch(leftPath: leftPath, rightPath: rightPath, isExact: false, isDirectory: false))
            matchedLeft.insert(leftPath)
            matchedRight.insert(rightPath)
        }

        // 2c. Edited media: a photo, video or audio file whose name is unique on both sides.
        let mediaPairs = try await ScanEngine.editedMediaPairs(
            left: leftFiles.filter { !matchedLeft.contains($0.path) },
            right: rightFiles.filter { !matchedRight.contains($0.path) }
        )
        for (leftPath, rightPath) in mediaPairs {
            map.insert(MoveMatch(leftPath: leftPath, rightPath: rightPath, isExact: false, isDirectory: false))
        }

        // 3. Folder moves.
        for folderMove in ScanEngine.folderMoves(in: nodes, fileMoves: map) {
            map.insert(folderMove)
        }
        return map
    }

    private func digests(for candidates: [(String, MoveCandidate)]) async throws -> [String: SHA256.Digest] {
        var result: [String: SHA256.Digest] = [:]
        var missing: [(String, MoveCandidate)] = []
        for (prefix, candidate) in candidates {
            let key = prefix + candidate.path
            if let stamp = candidate.metadata.stamp, let cached = digestCache[key], cached.0 == stamp {
                result[key] = cached.1
            } else {
                missing.append((prefix, candidate))
            }
        }
        missing.sort { ($0.1.metadata.fileIdentifier ?? 0) < ($1.1.metadata.fileIdentifier ?? 0) }
        let computed = try await ScanEngine.computeDigests(missing.map { ($0.0 + $0.1.path, $0.1.url) })
        for (prefix, candidate) in missing {
            let key = prefix + candidate.path
            guard let digest = computed[key] else { continue }
            result[key] = digest
            if let stamp = candidate.metadata.stamp { digestCache[key] = (stamp, digest) }
        }
        return result
    }
}

nonisolated struct MoveCandidate: Sendable {
    let path: String
    let name: String
    let url: URL
    let metadata: ItemMetadata
}

// MARK: - Scan engine

/// One side's view of an item discovered while walking a folder.
nonisolated struct ScannedItem: Sendable {
    let name: String
    let url: URL
    let metadata: ItemMetadata
    let isIgnored: Bool
    /// Present for folders that were descended into.
    let children: [String: ScannedItem]?
}

nonisolated struct ComparisonJob: Sendable {
    let relativePath: String
    let leftURL: URL
    let rightURL: URL
    let leftMetadata: ItemMetadata
    let rightMetadata: ItemMetadata
}

nonisolated enum ScanEngine {
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isRegularFileKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .fileIdentifierKey,
    ]
    private static let resourceKeySet = Set(resourceKeys)
    /// File-reading workers. Opening files in parallel stops scaling early (the kernel
    /// serializes much of `open`), and too many workers is measurably slower than a few.
    static let ioWorkerCount: Int = {
        if let override = ProcessInfo.processInfo.environment["PATHDIFF_IO_WORKERS"].flatMap(Int.init), override > 0 {
            return override
        }
        return max(2, min(ProcessInfo.processInfo.activeProcessorCount / 2, 6))
    }()
    /// Folders down to this depth are walked (and turned into nodes) in parallel.
    static let parallelDepth = 4

    static func joinPath(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    // MARK: Walking

    @concurrent
    static func loadGitIndex(_ root: URL) async -> GitIndex? {
        GitIndex.load(root: root)
    }

    @concurrent
    static func loadCache(_ store: ComparisonCacheStore, leftRoot: URL, rightRoot: URL, options: DiffOptions) async -> [String: CachedComparison] {
        store.load(leftRoot: leftRoot, rightRoot: rightRoot, options: options)
    }

    /// Walks a compared root. Unlike subfolders, an unreadable root is an error: treating it
    /// as empty would report every item on the other side as missing.
    @concurrent
    static func walkRoot(_ root: URL, side: Side, rules: ScanRules, reporter: ProgressReporter?) async throws -> [String: ScannedItem] {
        let path = root.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              (try? FileManager().contentsOfDirectory(atPath: path)) != nil
        else { throw ScanError.folderUnavailable(path) }
        let stack = rules.respectsGitIgnore ? GitIgnoreStack().pushing(GitIgnoreFile.loadExclude(root: root)) : GitIgnoreStack()
        return try await walkDirectory(at: root, side: side, relativePath: "", gitIgnore: stack, rules: rules, reporter: reporter, depth: 0)
    }

    /// Lists a folder recursively. Unreadable folders are treated as empty.
    @concurrent
    static func walkDirectory(
        at url: URL,
        side: Side,
        relativePath: String,
        gitIgnore: GitIgnoreStack,
        rules: ScanRules,
        reporter: ProgressReporter?,
        depth: Int
    ) async throws -> [String: ScannedItem] {
        try Task.checkCancellation()
        let contents: [URL]
        do {
            contents = try FileManager().contentsOfDirectory(at: url, includingPropertiesForKeys: resourceKeys, options: [])
        } catch {
            // An unreadable subfolder is reported and treated as empty.
            reporter?.recordIssue(ScanIssue(path: relativePath, side: side, message: error.localizedDescription))
            return [:]
        }

        let stack = rules.respectsGitIgnore && contents.contains(where: { $0.lastPathComponent == ".gitignore" })
            ? gitIgnore.pushing(GitIgnoreFile.load(directory: url, basePath: relativePath))
            : gitIgnore

        var items: [String: ScannedItem] = [:]
        items.reserveCapacity(contents.count)
        var subdirectories: [(url: URL, name: String, path: String, metadata: ItemMetadata)] = []

        for childURL in contents {
            guard let metadata = readMetadata(at: childURL) else { continue }
            let name = childURL.lastPathComponent
            let path = joinPath(relativePath, name)
            let isDirectory = metadata.kind == .directory
            if isIgnored(name: name, path: path, isDirectory: isDirectory, rules: rules, gitIgnore: stack) {
                items[name] = ScannedItem(name: name, url: childURL, metadata: metadata, isIgnored: true, children: nil)
            } else if isDirectory {
                subdirectories.append((childURL, name, path, metadata))
            } else {
                items[name] = ScannedItem(name: name, url: childURL, metadata: metadata, isIgnored: false, children: nil)
            }
        }
        reporter?.itemsDiscovered(contents.count)

        if depth < parallelDepth && subdirectories.count > 1 {
            try await withThrowingTaskGroup(of: ScannedItem.self) { group in
                for directory in subdirectories {
                    group.addTask {
                        let children = try await walkDirectory(
                            at: directory.url, side: side, relativePath: directory.path, gitIgnore: stack,
                            rules: rules, reporter: reporter, depth: depth + 1
                        )
                        return ScannedItem(name: directory.name, url: directory.url, metadata: directory.metadata, isIgnored: false, children: children)
                    }
                }
                for try await item in group { items[item.name] = item }
            }
        } else {
            for directory in subdirectories {
                let children = try await walkDirectory(
                    at: directory.url, side: side, relativePath: directory.path, gitIgnore: stack,
                    rules: rules, reporter: reporter, depth: depth + 1
                )
                items[directory.name] = ScannedItem(name: directory.name, url: directory.url, metadata: directory.metadata, isIgnored: false, children: children)
            }
        }
        return items
    }

    static func isIgnored(name: String, path: String, isDirectory: Bool, rules: ScanRules, gitIgnore: GitIgnoreStack) -> Bool {
        if rules.matcher.isIgnored(name: name, relativePath: path, isDirectory: isDirectory) { return true }
        return rules.respectsGitIgnore && gitIgnore.isIgnored(relativePath: path, name: name, isDirectory: isDirectory)
    }

    /// Scans one item (and its subtree) for a partial refresh. Returns `nil` if it doesn't exist.
    @concurrent
    static func scanSingleItem(root: URL, side: Side, relativePath: String, name: String, rules: ScanRules, reporter: ProgressReporter?) async throws -> ScannedItem? {
        let url = root.appending(path: relativePath)
        guard let metadata = readMetadata(at: url) else { return nil }
        let stack = rules.respectsGitIgnore ? GitIgnoreStack.forParent(of: relativePath, root: root) : GitIgnoreStack()
        let isDirectory = metadata.kind == .directory
        if isIgnored(name: name, path: relativePath, isDirectory: isDirectory, rules: rules, gitIgnore: stack) {
            return ScannedItem(name: name, url: url, metadata: metadata, isIgnored: true, children: nil)
        }
        let children = isDirectory
            ? try await walkDirectory(at: url, side: side, relativePath: relativePath, gitIgnore: stack, rules: rules, reporter: reporter, depth: 0)
            : nil
        return ScannedItem(name: name, url: url, metadata: metadata, isIgnored: false, children: children)
    }

    /// Reads metadata without following symbolic links.
    static func readMetadata(at url: URL) -> ItemMetadata? {
        guard let values = try? url.resourceValues(forKeys: resourceKeySet) else { return nil }
        if values.isSymbolicLink == true {
            let destination = try? FileManager().destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))
            return ItemMetadata(kind: .symlink, size: 0, modificationDate: values.contentModificationDate, symlinkDestination: destination)
        }
        if values.isDirectory == true {
            return ItemMetadata(kind: .directory, size: 0, modificationDate: values.contentModificationDate)
        }
        // Named pipes, sockets and device files are left out: opening a pipe to compare it
        // blocks until another process writes to it, which would hang the scan.
        guard values.isRegularFile != false else { return nil }
        return ItemMetadata(
            kind: .file,
            size: Int64(values.fileSize ?? 0),
            modificationDate: values.contentModificationDate,
            fileIdentifier: values.fileIdentifier
        )
    }

    // MARK: Comparing

    /// Finds every pair of non-folder items present on both sides.
    static func collectJobs(left: [String: ScannedItem]?, right: [String: ScannedItem]?, parentPath: String, into jobs: inout [ComparisonJob]) {
        guard let left, let right else { return }
        for (name, leftItem) in left {
            guard let rightItem = right[name], !leftItem.isIgnored, !rightItem.isIgnored else { continue }
            let path = joinPath(parentPath, name)
            switch (leftItem.metadata.kind, rightItem.metadata.kind) {
            case (.directory, .directory):
                collectJobs(left: leftItem.children, right: rightItem.children, parentPath: path, into: &jobs)
            case (.directory, _), (_, .directory):
                continue
            default:
                jobs.append(ComparisonJob(
                    relativePath: path,
                    leftURL: leftItem.url,
                    rightURL: rightItem.url,
                    leftMetadata: leftItem.metadata,
                    rightMetadata: rightItem.metadata
                ))
            }
        }
    }

    /// Compares files on a pool of workers that pull jobs from a shared cursor; each worker
    /// reuses its own read buffers. Returns one result per job, in order.
    @concurrent
    static func runComparisons(_ jobs: [ComparisonJob], options: DiffOptions, gitIndexes: GitIndexPair?, reporter: ProgressReporter?) async throws -> [Bool] {
        guard !jobs.isEmpty else { return [] }
        let workerCount = min(jobs.count, ioWorkerCount)
        let cursor = WorkCursor()

        return try await withThrowingTaskGroup(of: [(Int, Bool)].self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    let buffers = FileComparator.Buffers()
                    var local: [(Int, Bool)] = []
                    var unreported = 0
                    var resolvedByIndex = 0
                    while let index = cursor.next(below: jobs.count) {
                        try Task.checkCancellation()
                        let job = jobs[index]
                        let equal: Bool
                        if let known = gitIndexes?.knownResult(for: job, options: options) {
                            equal = known
                            resolvedByIndex += 1
                        } else if let result = FileComparator.areEqual(
                            left: job.leftURL,
                            right: job.rightURL,
                            leftMetadata: job.leftMetadata,
                            rightMetadata: job.rightMetadata,
                            options: options,
                            buffers: buffers
                        ) {
                            equal = result
                        } else {
                            // Can't tell: report it and show it as modified so it gets attention.
                            equal = false
                            reporter?.recordIssue(ScanIssue(path: job.relativePath, side: nil, message: String(localized: "The file couldn’t be read on one or both sides.")))
                        }
                        local.append((index, equal))
                        unreported += 1
                        if unreported >= 128 {
                            reporter?.filesCompared(unreported)
                            unreported = 0
                        }
                    }
                    reporter?.filesCompared(unreported)
                    reporter?.update { $0.filesResolvedByGitIndex += resolvedByIndex }
                    return local
                }
            }
            var results = [Bool](repeating: false, count: jobs.count)
            for try await batch in group {
                for (index, equal) in batch { results[index] = equal }
            }
            return results
        }
    }

    // MARK: Building nodes

    @concurrent
    static func makeNodes(left: [String: ScannedItem]?, right: [String: ScannedItem]?, parentPath: String, results: [String: Bool], depth: Int) async -> [DiffNode] {
        var names = Set<String>()
        if let left { names.formUnion(left.keys) }
        if let right { names.formUnion(right.keys) }

        var nodes: [DiffNode]
        if depth < parallelDepth && names.count > 1 {
            nodes = await withTaskGroup(of: DiffNode.self) { group in
                for name in names {
                    group.addTask {
                        await makeNodeAsync(name: name, relativePath: joinPath(parentPath, name), left: left?[name], right: right?[name], results: results, depth: depth)
                    }
                }
                var collected: [DiffNode] = []
                collected.reserveCapacity(names.count)
                for await node in group { collected.append(node) }
                return collected
            }
        } else {
            nodes = names.map { name in
                makeNode(name: name, relativePath: joinPath(parentPath, name), left: left?[name], right: right?[name], results: results)
            }
        }
        nodes.sort(by: DiffNode.sortPrecedes)
        return nodes
    }

    @concurrent
    private static func makeNodeAsync(name: String, relativePath: String, left: ScannedItem?, right: ScannedItem?, results: [String: Bool], depth: Int) async -> DiffNode {
        let leftKind = left?.metadata.kind
        let rightKind = right?.metadata.kind
        let isIgnored = left?.isIgnored == true || right?.isIgnored == true
        guard !isIgnored, leftKind == .directory || rightKind == .directory else {
            return makeNode(name: name, relativePath: relativePath, left: left, right: right, results: results)
        }
        let children = await makeNodes(
            left: leftKind == .directory ? left?.children : nil,
            right: rightKind == .directory ? right?.children : nil,
            parentPath: relativePath,
            results: results,
            depth: depth + 1
        )
        return directoryNode(name: name, relativePath: relativePath, left: left, right: right, children: children)
    }

    static func makeNodesSync(left: [String: ScannedItem]?, right: [String: ScannedItem]?, parentPath: String, results: [String: Bool]) -> [DiffNode] {
        var names = Set<String>()
        if let left { names.formUnion(left.keys) }
        if let right { names.formUnion(right.keys) }
        var nodes = names.map { name in
            makeNode(name: name, relativePath: joinPath(parentPath, name), left: left?[name], right: right?[name], results: results)
        }
        nodes.sort(by: DiffNode.sortPrecedes)
        return nodes
    }

    static func makeNode(name: String, relativePath: String, left: ScannedItem?, right: ScannedItem?, results: [String: Bool]) -> DiffNode {
        let leftKind = left?.metadata.kind
        let rightKind = right?.metadata.kind

        if left?.isIgnored == true || right?.isIgnored == true {
            return DiffNode(
                name: name, relativePath: relativePath,
                leftURL: left?.url, rightURL: right?.url,
                leftMetadata: left?.metadata, rightMetadata: right?.metadata,
                status: .ignored, children: nil
            )
        }

        if leftKind == .directory || rightKind == .directory {
            let children = makeNodesSync(
                left: leftKind == .directory ? left?.children : nil,
                right: rightKind == .directory ? right?.children : nil,
                parentPath: relativePath,
                results: results
            )
            return directoryNode(name: name, relativePath: relativePath, left: left, right: right, children: children)
        }

        let status: FileStatus
        if left == nil {
            status = .rightOnly
        } else if right == nil {
            status = .leftOnly
        } else {
            status = results[relativePath] == true ? .identical : .modified
        }
        return DiffNode(
            name: name, relativePath: relativePath,
            leftURL: left?.url, rightURL: right?.url,
            leftMetadata: left?.metadata, rightMetadata: right?.metadata,
            status: status, children: nil
        )
    }

    private static func directoryNode(name: String, relativePath: String, left: ScannedItem?, right: ScannedItem?, children: [DiffNode]) -> DiffNode {
        // Two-sided folders get their status from their children in `recomputeAggregates`.
        let status: FileStatus
        if left == nil {
            status = .rightOnly
        } else if right == nil {
            status = .leftOnly
        } else {
            status = left?.metadata.kind == right?.metadata.kind ? .identical : .modified
        }
        return DiffNode(
            name: name, relativePath: relativePath,
            leftURL: left?.url, rightURL: right?.url,
            leftMetadata: left?.metadata, rightMetadata: right?.metadata,
            status: status, children: children
        )
    }

    // MARK: Move helpers

    @concurrent
    static func computeDigests(_ files: [(key: String, url: URL)]) async throws -> [String: SHA256.Digest] {
        guard !files.isEmpty else { return [:] }
        let workerCount = min(files.count, ioWorkerCount)
        let cursor = WorkCursor()
        return try await withThrowingTaskGroup(of: [(String, SHA256.Digest)].self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    let buffers = FileComparator.Buffers()
                    var local: [(String, SHA256.Digest)] = []
                    while let index = cursor.next(below: files.count) {
                        try Task.checkCancellation()
                        if let digest = FileComparator.digest(of: files[index].url, buffers: buffers) {
                            local.append((files[index].key, digest))
                        }
                    }
                    return local
                }
            }
            var result: [String: SHA256.Digest] = [:]
            for try await batch in group {
                for (key, digest) in batch { result[key] = digest }
            }
            return result
        }
    }

    /// Pairs one-sided files with the same name, size and modification date (quick method).
    /// Among several candidates, the first unused one in path order wins.
    static func quickMovePairs(left: [MoveCandidate], right: [MoveCandidate]) -> [(String, String)] {
        struct Key: Hashable {
            let name: String
            let size: Int64
        }
        var rightByKey: [Key: [MoveCandidate]] = [:]
        for candidate in right where candidate.metadata.size > 0 {
            rightByKey[Key(name: candidate.name, size: candidate.metadata.size), default: []].append(candidate)
        }
        for key in rightByKey.keys { rightByKey[key]?.sort { $0.path < $1.path } }
        var used = Set<String>()
        var pairs: [(String, String)] = []
        for candidate in left.sorted(by: { $0.path < $1.path }) where candidate.metadata.size > 0 {
            let key = Key(name: candidate.name, size: candidate.metadata.size)
            guard let counterpart = rightByKey[key]?.first(where: {
                !used.contains($0.path) && ComparisonMethod.haveSameModificationDate(candidate.metadata, $0.metadata)
            }) else { continue }
            used.insert(counterpart.path)
            pairs.append((candidate.path, counterpart.path))
        }
        return pairs
    }

    /// Photos, videos and audio files whose name occurs exactly once among the unmatched
    /// files on each side, paired as "moved and edited". Images whose recorded capture
    /// dates differ are different shots that happen to share a name, and stay unpaired.
    @concurrent
    static func editedMediaPairs(left: [MoveCandidate], right: [MoveCandidate]) async throws -> [(String, String)] {
        let leftByName = Dictionary(grouping: left.filter { MediaKind(path: $0.name) != nil }, by: \.name)
        let rightByName = Dictionary(grouping: right.filter { MediaKind(path: $0.name) != nil }, by: \.name)
        var pairs: [(String, String)] = []
        for (name, lefts) in leftByName {
            try Task.checkCancellation()
            guard lefts.count == 1, let rights = rightByName[name], rights.count == 1 else { continue }
            let leftFile = lefts[0]
            let rightFile = rights[0]
            if MediaKind(path: name) == .image,
               let leftDate = MediaInspector.captureDate(of: leftFile.url),
               let rightDate = MediaInspector.captureDate(of: rightFile.url),
               leftDate != rightDate {
                continue
            }
            pairs.append((leftFile.path, rightFile.path))
        }
        return pairs
    }

    /// Lines-in-common ratio required to call a same-named file "moved and edited".
    static let renameSimilarity = 0.5
    /// Groups larger than this on either side are too ambiguous (and costly) to pair.
    static let maximumNameGroup = 8

    /// Within each group (files sharing a name, or a folder), pairs files that share most of
    /// their lines, best matches first.
    @concurrent
    static func similarPairs(left: [String: [MoveCandidate]], right: [String: [MoveCandidate]]) async throws -> [(String, String)] {
        var groups: [([MoveCandidate], [MoveCandidate])] = []
        for (name, lefts) in left {
            guard let rights = right[name], lefts.count <= maximumNameGroup, rights.count <= maximumNameGroup else { continue }
            groups.append((lefts, rights))
        }
        guard !groups.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: [(String, String)].self) { group in
            for (lefts, rights) in groups {
                group.addTask {
                    try Task.checkCancellation()
                    let leftLines = lefts.map { lineProfile($0) }
                    let rightLines = rights.map { lineProfile($0) }
                    var scored: [(Double, Int, Int)] = []
                    for (i, l) in leftLines.enumerated() {
                        guard let l else { continue }
                        for (j, r) in rightLines.enumerated() {
                            guard let r else { continue }
                            let similarity = lineSimilarity(l, r)
                            if similarity >= renameSimilarity { scored.append((similarity, i, j)) }
                        }
                    }
                    scored.sort { $0.0 > $1.0 }
                    var usedLeft = Set<Int>()
                    var usedRight = Set<Int>()
                    var pairs: [(String, String)] = []
                    for (_, i, j) in scored where !usedLeft.contains(i) && !usedRight.contains(j) {
                        usedLeft.insert(i)
                        usedRight.insert(j)
                        pairs.append((lefts[i].path, rights[j].path))
                    }
                    return pairs
                }
            }
            var all: [(String, String)] = []
            for try await pairs in group { all.append(contentsOf: pairs) }
            return all
        }
    }

    /// Line multiset of a text file (whitespace-insensitive), or `nil` for binary/huge files.
    private static func lineProfile(_ candidate: MoveCandidate) -> [String: Int]? {
        guard candidate.metadata.size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: candidate.url),
              let document = TextDocument.decode(data)
        else { return nil }
        var counts: [String: Int] = [:]
        let options = DiffOptions(ignoreWhitespace: true)
        for line in document.lines {
            let key = DiffEngine.comparisonKey(for: line, options: options)
            if !key.isEmpty { counts[key, default: 0] += 1 }
        }
        return counts
    }

    private static func lineSimilarity(_ lhs: [String: Int], _ rhs: [String: Int]) -> Double {
        let lhsTotal = lhs.values.reduce(0, +)
        let rhsTotal = rhs.values.reduce(0, +)
        guard lhsTotal + rhsTotal > 0 else { return 1 }
        var shared = 0
        for (line, count) in lhs { shared += min(count, rhs[line] ?? 0) }
        return Double(2 * shared) / Double(lhsTotal + rhsTotal)
    }

    /// Topmost left-only folders whose files mostly moved, keeping their relative layout,
    /// into one right-only folder.
    static func folderMoves(in nodes: [DiffNode], fileMoves: MoveMap) -> [MoveMatch] {
        var result: [MoveMatch] = []

        func filePaths(in node: DiffNode) -> [String] {
            var paths: [String] = []
            DiffTree.forEachDepthFirst(node.children ?? []) { child in
                if !child.isDirectory && child.status != .ignored { paths.append(child.relativePath) }
            }
            return paths
        }

        func visit(_ level: [DiffNode]) {
            for node in level where node.isDirectory {
                guard node.status == .leftOnly else {
                    if node.status == .modified { visit(node.children ?? []) }
                    continue
                }
                let files = filePaths(in: node)
                guard !files.isEmpty else { continue }
                var votes: [String: (count: Int, exact: Int)] = [:]
                for path in files {
                    guard let match = fileMoves.byLeftPath[path] else { continue }
                    let suffix = String(path.dropFirst(node.relativePath.count))   // "/sub/file"
                    guard match.rightPath.hasSuffix(suffix) else { continue }
                    let destination = String(match.rightPath.dropLast(suffix.count))
                    votes[destination, default: (0, 0)].count += 1
                    if match.isExact { votes[destination, default: (0, 0)].exact += 1 }
                }
                guard let (destination, tally) = votes.max(by: { $0.value.count < $1.value.count }),
                      tally.count * 2 >= files.count,
                      let target = DiffTree.node(at: destination, in: nodes),
                      target.isDirectory, target.status == .rightOnly
                else { continue }
                let total = max(files.count, filePaths(in: target).count)
                result.append(MoveMatch(
                    leftPath: node.relativePath,
                    rightPath: destination,
                    isExact: tally.exact == total,
                    isDirectory: true,
                    matchedFiles: tally.count,
                    totalFiles: total
                ))
            }
        }
        visit(nodes)
        return result
    }
}

/// Hands out job indices to comparison workers.
nonisolated final class WorkCursor: Sendable {
    private let position = Atomic<Int>(0)

    func next(below limit: Int) -> Int? {
        let index = position.wrappingAdd(1, ordering: .relaxed).oldValue
        return index < limit ? index : nil
    }
}

// MARK: - File comparison

nonisolated enum FileComparator {
    static let bufferSize = 1 << 20
    /// Above this size, files whose bytes differ are not re-compared as text.
    static let textComparisonLimit: Int64 = 16 * 1024 * 1024

    /// Per-worker read buffers, reused for every file the worker compares.
    final class Buffers {
        let left = UnsafeMutableRawPointer.allocate(byteCount: FileComparator.bufferSize, alignment: 16)
        let right = UnsafeMutableRawPointer.allocate(byteCount: FileComparator.bufferSize, alignment: 16)

        deinit {
            left.deallocate()
            right.deallocate()
        }
    }

    /// Whether two files have the same contents, or `nil` if either can't be read.
    static func areEqual(left: URL, right: URL, leftMetadata: ItemMetadata, rightMetadata: ItemMetadata, options: DiffOptions, buffers: Buffers) -> Bool? {
        if leftMetadata.kind == .symlink || rightMetadata.kind == .symlink {
            return leftMetadata.kind == rightMetadata.kind
                && leftMetadata.symlinkDestination == rightMetadata.symlinkDestination
        }
        if options.comparisonMethod == .quick, leftMetadata.size == rightMetadata.size,
           ComparisonMethod.haveSameModificationDate(leftMetadata, rightMetadata) {
            return true
        }
        if leftMetadata.size == rightMetadata.size {
            guard let equal = bytesEqual(left, right, buffers: buffers) else { return nil }
            if equal { return true }
        }
        guard options.isTextAware, max(leftMetadata.size, rightMetadata.size) <= textComparisonLimit,
              let leftData = try? Data(contentsOf: left),
              let rightData = try? Data(contentsOf: right),
              let leftDocument = TextDocument.decode(leftData),
              let rightDocument = TextDocument.decode(rightData)
        else { return false }
        return DiffEngine.comparisonKeys(for: leftDocument.lines, options: options)
            == DiffEngine.comparisonKeys(for: rightDocument.lines, options: options)
    }

    /// Streams both files with POSIX reads and stops at the first differing chunk.
    /// Returns `nil` if either file can't be read.
    static func bytesEqual(_ left: URL, _ right: URL, buffers: Buffers) -> Bool? {
        let leftDescriptor = left.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY) } ?? -1 }
        guard leftDescriptor >= 0 else { return nil }
        defer { close(leftDescriptor) }
        let rightDescriptor = right.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY) } ?? -1 }
        guard rightDescriptor >= 0 else { return nil }
        defer { close(rightDescriptor) }

        while true {
            let leftCount = readFully(leftDescriptor, into: buffers.left)
            let rightCount = readFully(rightDescriptor, into: buffers.right)
            guard leftCount >= 0, rightCount >= 0 else { return nil }
            if leftCount != rightCount { return false }
            if leftCount == 0 { return true }
            if memcmp(buffers.left, buffers.right, leftCount) != 0 { return false }
            if leftCount < bufferSize { return true }
        }
    }

    static func digest(of url: URL, buffers: Buffers) -> SHA256.Digest? {
        let descriptor = url.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY) } ?? -1 }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var hasher = SHA256()
        while true {
            let count = readFully(descriptor, into: buffers.left)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffers.left, count: count))
            if count < bufferSize { break }
        }
        return hasher.finalize()
    }

    /// Reads until the buffer is full or the file ends. Returns -1 on error.
    private static func readFully(_ descriptor: Int32, into buffer: UnsafeMutableRawPointer) -> Int {
        var total = 0
        while total < bufferSize {
            let count = read(descriptor, buffer + total, bufferSize - total)
            if count < 0 {
                if errno == EINTR { continue }
                return -1
            }
            if count == 0 { break }
            total += count
        }
        return total
    }
}

// MARK: - Progress

/// Thread-safe progress accumulator that forwards throttled snapshots to a handler.
nonisolated final class ProgressReporter: Sendable {
    private struct State {
        var progress = ScanProgress()
        var lastReport: ContinuousClock.Instant?
    }

    private let state = Mutex(State())
    private let collectedIssues = Mutex<[ScanIssue]>([])
    private let handler: FolderScanner.ProgressHandler?
    /// Issues beyond this many are dropped (the count shown is still capped, not exact).
    static let maximumIssues = 1_000
    private static let interval = Duration.milliseconds(100)

    init(handler: FolderScanner.ProgressHandler?) {
        self.handler = handler
    }

    func update(_ body: (inout ScanProgress) -> Void) {
        let snapshot = state.withLock { state -> ScanProgress in
            body(&state.progress)
            state.lastReport = .now
            return state.progress
        }
        handler?(snapshot)
    }

    var issues: [ScanIssue] {
        collectedIssues.withLock { $0 }
    }

    func recordIssue(_ issue: ScanIssue) {
        collectedIssues.withLock { issues in
            if issues.count < Self.maximumIssues { issues.append(issue) }
        }
    }

    func itemsDiscovered(_ count: Int) {
        throttled { $0.itemsDiscovered += count }
    }

    func filesCompared(_ count: Int) {
        guard count > 0 else { return }
        throttled { $0.filesCompared += count }
    }

    private func throttled(_ body: (inout ScanProgress) -> Void) {
        guard handler != nil else { return }
        let snapshot = state.withLock { state -> ScanProgress? in
            body(&state.progress)
            let now = ContinuousClock.now
            if let last = state.lastReport, now - last < Self.interval { return nil }
            state.lastReport = now
            return state.progress
        }
        if let snapshot { handler?(snapshot) }
    }
}

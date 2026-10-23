//
//  DiffViewModel.swift
//  PathDiff
//

import AppKit
import Foundation
import Observation
import OSLog

/// A visible row in the sidebar's flattened tree.
struct SidebarRow: Identifiable, Equatable {
    let node: DiffNode
    let depth: Int
    let isExpanded: Bool
    let move: MoveMatch?

    var id: String { node.id }
}

/// A row in the Changes list. One-sided folders are collapsed into a single row.
struct ChangeRow: Identifiable, Equatable {
    let node: DiffNode
    let kind: ChangeKind
    let move: MoveMatch?
    /// Files inside a collapsed folder row.
    let fileCount: Int

    var id: String { node.id }
}

struct ChangeSection: Identifiable, Equatable {
    let kind: ChangeKind
    let rows: [ChangeRow]

    var id: ChangeKind { kind }
}

/// Which part of a row a unified-layout item shows.
enum UnifiedPart: Int, Hashable {
    case context = 1
    case removed = 2
    case added = 3
}

/// An item in the diff list: a side-by-side row, one side of a row in the unified layout,
/// or a collapsed run of unchanged rows.
enum DiffDisplayItem: Identifiable, Hashable {
    case line(Int)
    case unified(row: Int, part: UnifiedPart)
    case fold(Range<Int>)

    private static let unifiedBase = 1 << 40

    var id: Int {
        switch self {
        case .line(let index): index
        case .unified(let row, let part): Self.unifiedBase + (row << 2 | part.rawValue)
        case .fold(let range): -(range.lowerBound + 1)
        }
    }

    var row: Int? {
        switch self {
        case .line(let row), .unified(let row, _): row
        case .fold: nil
        }
    }
}

/// An open Sync sheet: options, the dry-run plan and, while running, progress.
struct BatchSyncSession {
    var options = BatchSyncOptions()
    /// `nil` syncs everything.
    var scopeIDs: Set<String>?
    /// The sidebar selection when the sheet was opened.
    let selectionIDs: Set<String>
    var plan = BatchSyncPlan()
    /// Operations the user unticked.
    var excluded: Set<Int> = []
    var progress: BatchSyncProgress?
    var isRunning = false
    var errorMessage: String?
}

struct DiffScrollRequest: Equatable {
    let rowID: Int
    let token = UUID()
}

struct SidebarScrollRequest: Equatable {
    let nodeID: String
    let token = UUID()
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct PendingConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let isDestructive: Bool
    let action: () -> Void
}

/// Search and change-kind filter results for the tree: nodes that match, and folders that
/// contain matches (which are shown expanded).
struct TreeFilterResults {
    var matches: Set<String> = []
    var ancestorsOfMatches: Set<String> = []
}

/// State and behavior for one comparison window.
///
/// The type is split across files: this file holds the state, folder selection, scanning,
/// incremental refresh, file watching and move detection; see `+Sidebar`, `+Diff` and
/// `+Sync` for the rest. Properties without `private(set)` are written by those extensions
/// and should only be changed through view-model methods.
@Observable
final class DiffViewModel {
    // MARK: Folders

    private(set) var leftFolderURL: URL?
    private(set) var rightFolderURL: URL?

    // MARK: Tree and changes

    var rootNodes: [DiffNode] = []
    var moves = MoveMap()
    var summary = DiffSummary()
    var sidebarRows: [SidebarRow] = []
    var changeSections: [ChangeSection] = []
    var expandedPaths: Set<String> = []
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSidebarRebuild() } }
    }
    var showOnlyDifferences: Bool {
        didSet {
            settings.showOnlyDifferences = showOnlyDifferences
            rebuildSidebar()
        }
    }
    var showIgnored = false {
        didSet { rebuildSidebar() }
    }
    /// Which kinds of change are listed. All kinds means no filtering.
    var kindFilter: Set<ChangeKind> = Set(ChangeKind.allCases) {
        didSet { rebuildSidebar() }
    }
    /// Lists only files of this type (folders are opened up to show them).
    var typeFilter: FileCategory? {
        didSet { if typeFilter != oldValue { rebuildSidebar() } }
    }
    var sidebarMode: SidebarMode {
        didSet { settings.sidebarMode = sidebarMode }
    }

    // MARK: Selection and diff

    var selectedIDs: Set<String> = []
    /// The single selected node; `nil` when nothing or several items are selected.
    var selectedNode: DiffNode?
    /// The node actually compared in the detail view. For a moved file this pairs it with
    /// its counterpart at the other path.
    var activeDiffNode: DiffNode?
    /// Tree paths whose changes affect the active diff.
    var activeDiffPaths: Set<String> = []
    var activeDiff: FileDiffContent = .none
    var activeDiffLines: [LineDiff] = []
    var displayItems: [DiffDisplayItem] = []
    var currentHunkIndex: Int?
    var diffScrollRequest: DiffScrollRequest?
    var sidebarScrollRequest: SidebarScrollRequest?

    // MARK: Activity

    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var scanProgress = ScanProgress()
    private(set) var lastScanDuration: Duration?
    private(set) var isDetectingMoves = false
    /// Folders and files that couldn't be read during the last scan and later refreshes.
    private(set) var scanIssues: [ScanIssue] = []
    var isPerformingFileOperation = false
    var alert: AlertMessage?
    var pendingConfirmation: PendingConfirmation?
    /// The Sync sheet, when open.
    var batchSync: BatchSyncSession?
    /// For image files that are also text (SVG): show the visual comparison.
    var showsImageComparison = true
    /// The file being edited in place, when editing.
    var editSession: EditSession?
    /// Asks what to do with unsaved edits before leaving them.
    var editGuard: EditGuard?

    /// The exclusion patterns in effect (shared by all windows).
    var ignorePatterns: [String] {
        get { settings.ignorePatterns }
        set { settings.ignorePatterns = newValue }
    }

    // MARK: Non-observed state

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let scanner: FolderScanner
    @ObservationIgnored let history: SyncHistory
    @ObservationIgnored let fileService = FileManagerService()
    @ObservationIgnored private var leftAccess: SecurityScopedAccess?
    @ObservationIgnored private var rightAccess: SecurityScopedAccess?
    /// Access to parent folders kept alive after switching to folders inside them.
    @ObservationIgnored private var inheritedAccesses: [SecurityScopedAccess] = []
    @ObservationIgnored let logger = Logger(subsystem: "com.openappbox.pathdiff", category: "Comparison")
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var moveTask: Task<Void, Never>?
    @ObservationIgnored var diffTask: Task<Void, Never>?
    @ObservationIgnored var sidebarTask: Task<Void, Never>?
    @ObservationIgnored var batchSyncTask: Task<Void, Never>?
    @ObservationIgnored var editAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefreshPaths: Set<String> = []
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var scanConfiguration: ScanConfiguration?
    @ObservationIgnored private var rules = ScanRules(matcher: IgnoreMatcher(patterns: []), respectsGitIgnore: false)
    @ObservationIgnored private var watchers: [FolderWatcher] = []
    /// When the running full scan started, so changes made during it aren't missed.
    @ObservationIgnored private var scanStartEventID: UInt64?
    @ObservationIgnored private var filesChangedObserver: (any NSObjectProtocol)?
    /// The last file write started; the next one waits for it (see `enqueueFileOperation`).
    @ObservationIgnored var fileOperationTail: Task<Void, Never>?
    @ObservationIgnored var pendingFileOperations = 0
    @ObservationIgnored var expandedFolds: Set<Int> = []
    @ObservationIgnored var cachedTreeFilter: TreeFilterResults?
    @ObservationIgnored var nodeCount = 0
    /// Differing files in tree order, for next/previous changed file.
    @ObservationIgnored var changedFileOrder: [String] = []
    @ObservationIgnored var changedFileIndex: [String: Int] = [:]
    @ObservationIgnored private static var didRestoreLastSession = false

    /// When there are at most this many differences, folders containing them start expanded.
    private static let autoExpandLimit = 400

    /// Every open window's model, for work that must finish before the app quits.
    private static let allViewModels = NSHashTable<DiffViewModel>.weakObjects()

    /// Lets running file writes finish (a running sync is stopped between operations), so
    /// their undo and history backups are complete before the app quits.
    static func finishFileOperations() async {
        for viewModel in allViewModels.allObjects {
            viewModel.batchSyncTask?.cancel()
            await viewModel.batchSyncTask?.value
            await viewModel.fileOperationTail?.value
        }
    }

    init(settings: AppSettings = .shared, scanner: FolderScanner = FolderScanner(), history: SyncHistory = .shared) {
        self.settings = settings
        self.scanner = scanner
        self.history = history
        self.showOnlyDifferences = settings.showOnlyDifferences
        self.sidebarMode = settings.sidebarMode
        Self.allViewModels.add(self)
        // Reverts from the History window change files behind this window's back.
        filesChangedObserver = NotificationCenter.default.addObserver(forName: .pathDiffFilesChanged, object: nil, queue: .main) { [weak self] notification in
            let roots = notification.userInfo?["roots"] as? [String] ?? []
            MainActor.assumeIsolated { self?.filesChangedElsewhere(roots: roots) }
        }
    }

    /// A closed window stops its background work instead of letting a scan, refresh or
    /// sync run on (and read folders whose sandbox access ends with the window).
    isolated deinit {
        if let filesChangedObserver { NotificationCenter.default.removeObserver(filesChangedObserver) }
        for task in [scanTask, refreshTask, moveTask, diffTask, sidebarTask, editAnalysisTask] {
            task?.cancel()
        }
    }

    private func filesChangedElsewhere(roots: [String]) {
        let mine = [leftFolderURL, rightFolderURL].compactMap { $0?.path(percentEncoded: false) }
        guard hasScanned, !mine.isEmpty, roots.contains(where: mine.contains) else { return }
        rescan()
    }

    /// A destination path relative to the compared folder on `side`.
    func relativePath(of url: URL, side: Side) -> String {
        guard let root = folderURL(for: side)?.path(percentEncoded: false) else { return url.lastPathComponent }
        let path = url.path(percentEncoded: false)
        return PathUtilities.relativePath(path, to: root) ?? path
    }

    // MARK: - Derived state

    var hasBothFolders: Bool { leftFolderURL != nil && rightFolderURL != nil }

    /// Folders can't change while files are being written (the write would lose its sandbox
    /// access and be recorded against the wrong folders) or while the Sync sheet holds a
    /// plan for the current ones.
    var canChangeFolders: Bool { !isPerformingFileOperation && batchSync == nil }

    func folderURL(for side: Side) -> URL? {
        side == .left ? leftFolderURL : rightFolderURL
    }

    /// A short name for a side: the folder name, with its parent when both are named alike.
    func sideName(_ side: Side) -> String {
        guard let url = folderURL(for: side) else { return side.title }
        let name = url.lastPathComponent
        if let other = folderURL(for: side.opposite), other.lastPathComponent == name {
            return url.deletingLastPathComponent().lastPathComponent + "/" + name
        }
        return name
    }

    // MARK: - Folder selection

    func chooseFolder(for side: Side) async {
        guard canChangeFolders else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = side == .left ? String(localized: "Choose Left Folder") : String(localized: "Choose Right Folder")
        panel.prompt = String(localized: "Choose", comment: "Button of the panel that chooses a folder")
        panel.directoryURL = folderURL(for: side) ?? folderURL(for: side.opposite)?.deletingLastPathComponent()

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        setFolder(url, for: side)
    }

    func setFolder(_ url: URL, for side: Side) {
        guard canChangeFolders else { return }
        guard editSession == nil else {
            requestLeavingEdits { [weak self] in self?.setFolder(url, for: side) }
            return
        }
        if let other = folderURL(for: side.opposite),
           other.standardizedFileURL.path(percentEncoded: false) == url.standardizedFileURL.path(percentEncoded: false) {
            let name = url.lastPathComponent
            alert = AlertMessage(
                title: String(localized: "Same Folder"),
                message: side.opposite == .left
                    ? String(localized: "“\(name)” is already the left folder. Choose a different folder to compare with.")
                    : String(localized: "“\(name)” is already the right folder. Choose a different folder to compare with.")
            )
            return
        }
        let access = SecurityScopedAccess(url: url)
        switch side {
        case .left:
            leftAccess = access
            leftFolderURL = url
        case .right:
            rightAccess = access
            rightFolderURL = url
        }
        folderPairDidChange()
    }

    func openRecent(_ recent: RecentComparison) {
        guard canChangeFolders else { return }
        guard editSession == nil else {
            requestLeavingEdits { [weak self] in self?.openRecent(recent) }
            return
        }
        // Chosen explicitly, so a server or drive may be mounted to reach it.
        guard let left = BookmarkStore.resolve(recent.leftBookmark, allowsMounting: true),
              let right = BookmarkStore.resolve(recent.rightBookmark, allowsMounting: true)
        else {
            settings.removeRecentComparison(recent)
            alert = AlertMessage(
                title: String(localized: "Folders Unavailable"),
                message: String(localized: "“\(recent.title)” can no longer be opened. The folders may have been moved, renamed or deleted.")
            )
            return
        }
        inheritedAccesses = []
        adoptFolders(left: left, right: right)
    }

    /// Opens the folders of a "Compare in New Window" request.
    func open(_ request: ComparisonRequest) {
        guard let left = BookmarkStore.resolve(request.leftBookmark),
              let right = BookmarkStore.resolve(request.rightBookmark)
        else {
            alert = AlertMessage(
                title: String(localized: "Folders Unavailable"),
                message: String(localized: "The folders for this comparison can no longer be opened.")
            )
            return
        }
        adoptFolders(left: left, right: right)
    }

    /// Reopens the most recent comparison in the first window after launch.
    func restoreLastSessionIfNeeded() {
        guard !Self.didRestoreLastSession else { return }
        Self.didRestoreLastSession = true
        guard !hasBothFolders, let recent = settings.recentComparisons.first,
              let left = BookmarkStore.resolve(recent.leftBookmark),
              let right = BookmarkStore.resolve(recent.rightBookmark)
        else { return }
        // In the sandbox the folders can only be checked once access has started.
        let accesses = [SecurityScopedAccess(url: left), SecurityScopedAccess(url: right)]
        withExtendedLifetime(accesses) {
            guard FileManager.default.fileExists(atPath: left.path(percentEncoded: false)),
                  FileManager.default.fileExists(atPath: right.path(percentEncoded: false))
            else { return }
            adoptFolders(left: left, right: right)
        }
    }

    /// When each folder contains nothing but one folder with a different name (typical for
    /// extracted downloads like `project-main/` and `project-2.1/`), those inner folders.
    var innerFolderSuggestion: (left: DiffNode, right: DiffNode)? {
        guard hasScanned else { return nil }
        let visible = rootNodes.filter { $0.status != .ignored }
        guard visible.count == 2,
              let left = visible.first(where: { $0.status == .leftOnly && $0.leftMetadata?.kind == .directory }),
              let right = visible.first(where: { $0.status == .rightOnly && $0.rightMetadata?.kind == .directory })
        else { return nil }
        return (left, right)
    }

    /// Compares the suggested inner folders instead, keeping access to their parents.
    func compareInnerFolders() {
        guard canChangeFolders else { return }
        guard editSession == nil else {
            requestLeavingEdits { [weak self] in self?.compareInnerFolders() }
            return
        }
        guard let suggestion = innerFolderSuggestion,
              let left = suggestion.left.leftURL, let right = suggestion.right.rightURL
        else { return }
        inheritedAccesses.append(contentsOf: [leftAccess, rightAccess].compactMap { $0 })
        adoptFolders(left: left, right: right)
    }

    private func adoptFolders(left: URL, right: URL) {
        leftAccess = SecurityScopedAccess(url: left)
        rightAccess = SecurityScopedAccess(url: right)
        leftFolderURL = left
        rightFolderURL = right
        folderPairDidChange()
    }

    private func folderPairDidChange() {
        cancelScan()
        moveTask?.cancel()
        clearSelection()
        rootNodes = []
        moves = MoveMap()
        summary = DiffSummary()
        expandedPaths = []
        sidebarRows = []
        changeSections = []
        scanIssues = []
        hasScanned = false
        watchers.removeAll()
        undoManager?.removeAllActions(withTarget: self)
        if let left = leftFolderURL, let right = rightFolderURL {
            settings.recordRecentComparison(left: left, right: right)
        }
        rescan()
    }

    /// Swaps the folders and mirrors the existing results instead of rescanning.
    func swapFolders() {
        guard canChangeFolders else { return }
        guard editSession == nil else {
            requestLeavingEdits { [weak self] in self?.swapFolders() }
            return
        }
        guard leftFolderURL != nil || rightFolderURL != nil else { return }
        let previousLeft = leftFolderURL
        leftFolderURL = rightFolderURL
        rightFolderURL = previousLeft
        swap(&leftAccess, &rightAccess)
        undoManager?.removeAllActions(withTarget: self)

        if let left = leftFolderURL, let right = rightFolderURL {
            settings.recordRecentComparison(left: left, right: right)
        }
        guard hasScanned, !isScanning else {
            rescan()
            return
        }

        // In-flight refreshes were computed for the old orientation.
        scanGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        moveTask?.cancel()
        moves = moves.mirrored()
        applyTree(DiffTree.mirrored(rootNodes), changedPaths: [""], detectMoves: false)
        restartWatchers()
        drainRefreshQueue()
    }

    // MARK: - Scanning

    /// Rescans everything, re-reading every file instead of trusting remembered results.
    func rescanIgnoringCache() {
        guard let left = leftFolderURL, let right = rightFolderURL else { return }
        scanTask?.cancel()
        let scanner = self.scanner
        Task { [weak self] in
            await scanner.clearCaches(leftRoot: left, rightRoot: right)
            self?.rescan()
        }
    }

    func rescan() {
        guard let left = leftFolderURL, let right = rightFolderURL else { return }
        scanTask?.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        moveTask?.cancel()
        pendingRefreshPaths.removeAll()
        scanGeneration += 1
        scanStartEventID = FolderWatcher.currentEventID
        let generation = scanGeneration
        let configuration = settings.scanConfiguration
        scanConfiguration = configuration
        let rules = configuration.rules
        self.rules = rules
        let isInitialScan = !hasScanned
        let start = ContinuousClock.now
        logger.info("Scanning \(left.path(percentEncoded: false), privacy: .private) vs \(right.path(percentEncoded: false), privacy: .private)")

        let reportProgress: FolderScanner.ProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.scanGeneration == generation, self.isScanning else { return }
                self.scanProgress = progress
            }
        }

        isScanning = true
        scanProgress = ScanProgress(phase: .enumerating)
        scanTask = Task { [weak self, scanner] in
            do {
                let outcome = try await scanner.scan(
                    leftRoot: left,
                    rightRoot: right,
                    rules: rules,
                    options: configuration.options,
                    progress: reportProgress
                )
                guard let self, self.scanGeneration == generation else { return }
                self.scanIssues = outcome.issues
                self.finishScan(outcome.nodes, isInitialScan: isInitialScan, duration: ContinuousClock.now - start)
            } catch {
                guard let self, self.scanGeneration == generation else { return }
                self.isScanning = false
                if !(error is CancellationError) {
                    self.logger.error("Scan failed: \(error.localizedDescription, privacy: .public)")
                    self.alert = AlertMessage(title: String(localized: "Scan Failed"), message: error.localizedDescription)
                }
            }
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        isScanning = false
    }

    /// Called (debounced) when ignore patterns or comparison options change.
    func scanConfigurationDidChange() {
        guard hasBothFolders, settings.scanConfiguration != scanConfiguration else { return }
        rescan()
    }

    func watchSettingDidChange() {
        restartWatchers()
    }

    func moveDetectionSettingDidChange() {
        scheduleMoveDetection(after: .zero)
    }

    private func finishScan(_ nodes: [DiffNode], isInitialScan: Bool, duration: Duration) {
        isScanning = false
        hasScanned = true
        lastScanDuration = duration
        logger.info("Scan finished in \(duration.formatted(), privacy: .public): \(nodes.count) top-level items, \(self.scanIssues.count) issues")
        if isInitialScan {
            // Open folders that exist on both sides and contain differences; folders that
            // exist on one side only stay collapsed as a single unit.
            let differences = DiffSummary(nodes: nodes).differences
            var paths = Set<String>()
            DiffTree.forEachDepthFirst(nodes) { node in
                guard node.isDirectory, node.status == .modified, !node.hasKindMismatch else { return }
                if differences <= Self.autoExpandLimit || !node.relativePath.contains("/") {
                    paths.insert(node.id)
                }
            }
            expandedPaths = paths
        }
        applyTree(nodes, changedPaths: [""], detectMoves: true)
        // Files can change while a long scan runs, after they were read: the watchers replay
        // everything since the scan started.
        restartWatchers(since: scanStartEventID)
        scanStartEventID = nil
        drainRefreshQueue()
    }

    /// Installs a new tree and updates everything derived from it.
    /// `changedPaths` containing `""` means the whole tree changed.
    func applyTree(_ nodes: [DiffNode], changedPaths: [String], detectMoves: Bool) {
        rootNodes = nodes
        moves = validMoves(moves, in: nodes)
        var count = 0
        var order: [String] = []
        DiffTree.forEachDepthFirst(nodes) { node in
            count += 1
            if (!node.isDirectory || node.hasKindMismatch) && node.status.isDifference {
                order.append(node.id)
            }
        }
        nodeCount = count
        changedFileOrder = order
        changedFileIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        recomputeSummary()
        rebuildSidebar()
        refreshSelection(changedPaths: changedPaths)
        replanOpenBatchSync()
        if detectMoves {
            scheduleMoveDetection(after: changedPaths == [""] ? .zero : .milliseconds(400))
        }
    }

    /// Keeps an open Sync sheet's dry run in step with the folders: it shows (and the sync
    /// runs) what is on disk now. Unticked operations stay unticked.
    private func replanOpenBatchSync() {
        guard var session = batchSync, !session.isRunning else { return }
        func key(_ operation: SyncOperation) -> String {
            "\(operation.kind.rawValue)|\(operation.destination.rawValue)|\(operation.path)"
        }
        let excludedKeys = Set(session.plan.operations.filter { session.excluded.contains($0.id) }.map(key))
        session.plan = makeBatchPlan(for: session)
        session.excluded = Set(session.plan.operations.filter { excludedKeys.contains(key($0)) }.map(\.id))
        batchSync = session
    }

    private func recomputeSummary() {
        var newSummary = DiffSummary(nodes: rootNodes)
        newSummary.apply(moves, in: rootNodes)
        summary = newSummary
    }

    /// Re-resolves the selection against the current tree and reloads the diff if needed.
    private func refreshSelection(changedPaths: [String]) {
        let existing = selectedIDs.filter { DiffTree.node(at: $0, in: rootNodes) != nil }
        if existing != selectedIDs { selectedIDs = existing }

        guard let selected = selectedNode else { return }
        guard let updated = DiffTree.node(at: selected.id, in: rootNodes) else {
            if editSession?.nodeID == selected.id {
                // The edited file is gone (trashed, or removed by another app). Ask about the
                // unsaved edits instead of hiding them behind a cleared selection.
                requestLeavingEdits { [weak self] in self?.clearSelection() }
            } else {
                clearSelection()
            }
            return
        }
        let isAffected = changedPaths.contains { changed in
            changed.isEmpty || activeDiffPaths.contains { DiffTree.isSameOrDescendant($0, of: changed) }
        }
        if updated != selected || isAffected {
            selectedNode = updated
            loadDiff(for: updated, preservePosition: true)
        }
    }

    // MARK: - Partial refresh

    /// Queues paths (relative to the roots) whose tree nodes must be rebuilt.
    func scheduleRefresh(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        pendingRefreshPaths.formUnion(paths)
        drainRefreshQueue()
    }

    private func drainRefreshQueue() {
        guard refreshTask == nil, hasScanned, !isScanning, !pendingRefreshPaths.isEmpty else { return }
        let generation = scanGeneration
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.scanGeneration == generation, !self.pendingRefreshPaths.isEmpty {
                let batch = DiffTree.minimalPaths(self.pendingRefreshPaths)
                self.pendingRefreshPaths.removeAll()
                await self.refresh(batch, generation: generation)
            }
            if let self, self.scanGeneration == generation {
                self.refreshTask = nil
            }
        }
    }

    private func refresh(_ paths: [String], generation: Int) async {
        guard let left = leftFolderURL, let right = rightFolderURL, let options = scanConfiguration?.options else { return }
        let rules = self.rules
        var nodes = rootNodes
        var changed: [String] = []
        for path in paths {
            let target = DiffTree.refreshTarget(for: path, in: nodes)
            // `nil` means the item is gone from both sides; an error leaves the tree as is.
            let result: (node: DiffNode?, issues: [ScanIssue])
            do {
                result = try await scanner.scanItem(relativePath: target, leftRoot: left, rightRoot: right, rules: rules, options: options)
            } catch {
                continue
            }
            guard scanGeneration == generation else { return }
            nodes = DiffTree.replacing(path: target, with: result.node, in: nodes)
            scanIssues.removeAll { DiffTree.isSameOrDescendant($0.path, of: target) }
            scanIssues.append(contentsOf: result.issues)
            changed.append(target)
        }
        guard scanGeneration == generation, !changed.isEmpty else { return }
        applyTree(nodes, changedPaths: changed, detectMoves: true)
    }

    // MARK: - File system events

    private func restartWatchers(since eventID: UInt64? = nil) {
        watchers.removeAll()
        guard settings.watchForChanges, hasScanned else { return }
        for side in Side.allCases {
            guard let root = folderURL(for: side) else { continue }
            let rootPath = FolderWatcher.canonicalPath(root.path(percentEncoded: false))
            let watcher = FolderWatcher(path: rootPath, since: eventID) { [weak self] paths, requiresRescan in
                Task { @MainActor [weak self] in
                    self?.handleFileSystemEvents(paths, rootPath: rootPath, requiresRescan: requiresRescan)
                }
            }
            if let watcher { watchers.append(watcher) }
        }
    }

    /// More changed paths than this (a checkout, an unzip, a formatter run) are handled with
    /// one rescan, which the remembered results make fast; refreshing each path on its own
    /// costs time on the main thread for every one of them.
    private static let maximumIncrementalPaths = 500

    private func handleFileSystemEvents(_ paths: [String], rootPath: String, requiresRescan: Bool) {
        guard hasScanned, !watchers.isEmpty else { return }
        if requiresRescan || paths.count + pendingRefreshPaths.count > Self.maximumIncrementalPaths {
            rescan()
            return
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var relativePaths = Set<String>()
        for path in paths where path.hasPrefix(prefix) {
            var relative = String(path.dropFirst(prefix.count))
            while relative.hasSuffix("/") { relative.removeLast() }
            guard !relative.isEmpty else { continue }

            // Ignore rules changed: what is in the tree at all may change everywhere.
            if rules.respectsGitIgnore && (relative.hasSuffix("/.gitignore") || relative == ".gitignore" || relative == ".git/info/exclude") {
                rescan()
                return
            }
            // Churn inside ignored folders (.git, build output, node_modules) is irrelevant.
            if DiffTree.isInsideIgnoredNode(relative, in: rootNodes) { continue }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            if rules.matcher.isPathOrAncestorIgnored(relative, isDirectory: isDirectory.boolValue) { continue }
            relativePaths.insert(relative)
        }
        scheduleRefresh(relativePaths)
    }

    // MARK: - Move detection

    func scheduleMoveDetection(after delay: Duration) {
        moveTask?.cancel()
        guard settings.detectsMoves, hasScanned else {
            if !moves.isEmpty { applyMoves(MoveMap()) }
            isDetectingMoves = false
            return
        }
        let nodes = rootNodes
        let generation = scanGeneration
        let method = scanConfiguration?.options.comparisonMethod ?? settings.comparisonMethod
        moveTask = Task { [weak self, scanner] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
            self.isDetectingMoves = true
            do {
                let detected = try await scanner.detectMoves(in: nodes, method: method)
                guard !Task.isCancelled, self.scanGeneration == generation else { return }
                self.isDetectingMoves = false
                self.applyMoves(self.validMoves(detected, in: self.rootNodes))
            } catch {
                self.isDetectingMoves = false
            }
        }
    }

    private func applyMoves(_ newMoves: MoveMap) {
        guard newMoves != moves else { return }
        moves = newMoves
        recomputeSummary()
        rebuildSidebar()
        if let selected = selectedNode {
            let target = comparisonTarget(for: selected)
            if target.paths != activeDiffPaths || target.node != activeDiffNode {
                loadDiff(for: selected, preservePosition: false)
            }
        }
    }

    /// Drops matches whose items are no longer one-sided (the tree changed since detection).
    private func validMoves(_ map: MoveMap, in nodes: [DiffNode]) -> MoveMap {
        guard !map.isEmpty else { return map }
        var result = MoveMap()
        for match in map.allMatches {
            guard DiffTree.node(at: match.leftPath, in: nodes)?.status == .leftOnly,
                  DiffTree.node(at: match.rightPath, in: nodes)?.status == .rightOnly
            else { continue }
            result.insert(match)
        }
        return result
    }
}

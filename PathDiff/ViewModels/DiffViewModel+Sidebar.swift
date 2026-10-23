//
//  DiffViewModel+Sidebar.swift
//  PathDiff
//

import AppKit
import Foundation

/// Sidebar contents (tree rows and the Changes list), filtering, expansion, selection and
/// navigation between changed files.
extension DiffViewModel {
    /// Trees larger than this rebuild search results after a short typing pause.
    private static let debouncedSearchNodeCount = 20_000

    var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    var isKindFilterActive: Bool {
        kindFilter.count < ChangeKind.allCases.count
    }

    /// How a node differs, or `nil` for identical/ignored items and for two-sided folders.
    func changeKind(of node: DiffNode) -> ChangeKind? {
        switch node.status {
        case .modified:
            return node.isDirectory && !node.hasKindMismatch ? nil : .modified
        case .leftOnly:
            return moves.byLeftPath[node.relativePath] != nil ? .moved : .leftOnly
        case .rightOnly:
            return moves.byRightPath[node.relativePath] != nil ? .moved : .rightOnly
        case .identical, .ignored:
            return nil
        }
    }

    /// File counts below a folder, with moved files reported as moves.
    func summary(inside node: DiffNode) -> DiffSummary {
        var result = DiffSummary(nodes: node.children ?? [])
        let prefix = node.relativePath + "/"
        var leftEnds = 0
        var rightEnds = 0
        var moved = 0
        for match in moves.allMatches where !match.isDirectory {
            let leftInside = match.leftPath.hasPrefix(prefix)
            let rightInside = match.rightPath.hasPrefix(prefix)
            if leftInside { leftEnds += 1 }
            if rightInside { rightEnds += 1 }
            if leftInside || rightInside {
                moved += 1
                result.reclassifyBytes(of: match, in: rootNodes, countsLeft: leftInside, countsRight: rightInside)
            }
        }
        result.leftOnly = max(0, result.leftOnly - leftEnds)
        result.rightOnly = max(0, result.rightOnly - rightEnds)
        result.moved = moved
        return result
    }

    func count(of kind: ChangeKind) -> Int {
        summary.count(of: kind)
    }

    /// Click: show only this kind (or toggle it while already filtering). Showing nothing
    /// or everything resets the filter.
    func toggleKindFilter(_ kind: ChangeKind) {
        var filter = kindFilter
        if !isKindFilterActive {
            filter = [kind]
        } else if filter.contains(kind) {
            filter.remove(kind)
        } else {
            filter.insert(kind)
        }
        kindFilter = filter.isEmpty ? Set(ChangeKind.allCases) : filter
    }

    func resetFilters() {
        searchText = ""
        kindFilter = Set(ChangeKind.allCases)
        typeFilter = nil
    }

    // MARK: - Rebuilding

    func scheduleSidebarRebuild() {
        sidebarTask?.cancel()
        guard nodeCount > Self.debouncedSearchNodeCount else {
            rebuildSidebar()
            return
        }
        sidebarTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            self.rebuildSidebar()
        }
    }

    /// Rebuilds both the tree rows and the Changes list.
    func rebuildSidebar() {
        cachedTreeFilter = nil
        rebuildTreeRows()
        changeSections = makeChangeSections(applyingFilters: true)
    }

    /// Rebuilds only the tree rows (enough after expanding or collapsing a folder).
    func rebuildTreeRows() {
        var filter: TreeFilterResults?
        if !searchQuery.isEmpty || isKindFilterActive || typeFilter != nil {
            filter = cachedTreeFilter ?? makeTreeFilter()
            cachedTreeFilter = filter
        }
        var rows: [SidebarRow] = []
        appendRows(rootNodes, depth: 0, filter: filter, ancestorMatched: false, into: &rows)
        sidebarRows = rows
    }

    private func isVisible(_ node: DiffNode) -> Bool {
        switch node.status {
        case .ignored: showIgnored
        case .identical: !showOnlyDifferences && !isKindFilterActive
        case .modified, .leftOnly, .rightOnly: true
        }
    }

    private func matchesFilter(_ node: DiffNode, query: String) -> Bool {
        if let typeFilter {
            guard !node.isDirectory, FileCategory(path: node.name) == typeFilter else { return false }
        }
        if isKindFilterActive {
            guard let kind = changeKind(of: node), kindFilter.contains(kind) else { return false }
        }
        if !query.isEmpty {
            let subject = query.contains("/") ? node.relativePath : node.name
            guard subject.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return false }
        }
        return true
    }

    private func makeTreeFilter() -> TreeFilterResults {
        let query = searchQuery
        var results = TreeFilterResults()

        func visit(_ level: [DiffNode]) -> Bool {
            var found = false
            for node in level where isVisible(node) {
                if let children = node.children, visit(children) {
                    results.ancestorsOfMatches.insert(node.id)
                    found = true
                }
                if matchesFilter(node, query: query) {
                    results.matches.insert(node.id)
                    found = true
                }
            }
            return found
        }
        _ = visit(rootNodes)
        return results
    }

    private func appendRows(_ level: [DiffNode], depth: Int, filter: TreeFilterResults?, ancestorMatched: Bool, into rows: inout [SidebarRow]) {
        for node in level where isVisible(node) {
            var forcedOpen = false
            var isMatch = false
            if let filter, !ancestorMatched {
                isMatch = filter.matches.contains(node.id)
                // A matching folder keeps its own expansion state (everything inside a
                // one-sided folder matches too, and could be thousands of files).
                forcedOpen = !isMatch && filter.ancestorsOfMatches.contains(node.id)
                guard isMatch || forcedOpen else { continue }
            }
            let isExpanded = node.hasChildren && (forcedOpen || expandedPaths.contains(node.id))
            rows.append(SidebarRow(node: node, depth: depth, isExpanded: isExpanded, move: moves.match(for: node)))
            if isExpanded, let children = node.children {
                appendRows(children, depth: depth + 1, filter: filter, ancestorMatched: ancestorMatched || isMatch, into: &rows)
            }
        }
    }

    // MARK: - Changes list

    /// Groups every difference by kind. Folders that exist on one side only are collapsed
    /// into one row, unless something inside them moved; a moved folder is one row. While
    /// searching, folders are opened up so files inside them can be found.
    func makeChangeSections(applyingFilters: Bool) -> [ChangeSection] {
        let query = applyingFilters ? searchQuery : ""
        let kinds = applyingFilters ? kindFilter : Set(ChangeKind.allCases)
        let category = applyingFilters ? typeFilter : nil
        let isSearching = !query.isEmpty
        // Folders are opened up so files inside them can be found by name or type.
        let opensFolders = isSearching || category != nil
        let leftMoveAncestors = moves.ancestorsOfMoves(on: .left)
        let rightMoveAncestors = moves.ancestorsOfMoves(on: .right)
        var buckets: [ChangeKind: [ChangeRow]] = [:]

        func add(_ node: DiffNode, _ kind: ChangeKind, move: MoveMatch? = nil) {
            guard kinds.contains(kind) else { return }
            if let category {
                guard !node.isDirectory, FileCategory(path: node.name) == category else { return }
            }
            if isSearching {
                let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
                let matches = node.relativePath.range(of: query, options: options) != nil
                    || move?.rightPath.range(of: query, options: options) != nil
                guard matches else { return }
            }
            let fileCount: Int
            if let move, move.isDirectory {
                fileCount = move.totalFiles
            } else {
                fileCount = node.isDirectory ? DiffTree.fileCount(in: node) : 1
            }
            buckets[kind, default: []].append(ChangeRow(node: node, kind: kind, move: move, fileCount: fileCount))
        }

        func visit(_ level: [DiffNode], insideFolderMove folderMove: MoveMatch?) {
            for node in level {
                switch node.status {
                case .identical, .ignored:
                    continue
                case .modified:
                    if node.isDirectory && !node.hasKindMismatch {
                        visit(node.children ?? [], insideFolderMove: folderMove)
                    } else {
                        add(node, .modified)
                    }
                case .leftOnly:
                    if let match = moves.byLeftPath[node.relativePath] {
                        let isCovered = folderMove.map { DiffTree.isSameOrDescendant(match.rightPath, of: $0.rightPath) } ?? false
                        if !isCovered { add(node, .moved, move: match) }
                        if node.isDirectory {
                            // While filtering, list matching files of a moved folder individually.
                            visit(node.children ?? [], insideFolderMove: opensFolders ? nil : match)
                        }
                    } else if node.isDirectory && (opensFolders || leftMoveAncestors.contains(node.relativePath)) {
                        visit(node.children ?? [], insideFolderMove: folderMove)
                    } else {
                        add(node, .leftOnly)
                    }
                case .rightOnly:
                    if moves.byRightPath[node.relativePath] != nil {
                        // Listed from the left side; unmatched files inside still count as extra.
                        if node.isDirectory { visit(node.children ?? [], insideFolderMove: folderMove) }
                    } else if node.isDirectory && (opensFolders || rightMoveAncestors.contains(node.relativePath)) {
                        visit(node.children ?? [], insideFolderMove: folderMove)
                    } else {
                        add(node, .rightOnly)
                    }
                }
            }
        }
        visit(rootNodes, insideFolderMove: nil)
        return ChangeKind.allCases.compactMap { kind in
            buckets[kind].map { ChangeSection(kind: kind, rows: $0) }
        }
    }

    // MARK: - Expansion

    /// Option-clicking expands or collapses the whole subtree, like Finder.
    func toggleExpansion(of node: DiffNode, recursively: Bool = false) {
        setExpanded(!expandedPaths.contains(node.id), node: node, recursively: recursively)
    }

    func setExpanded(_ expanded: Bool, node: DiffNode, recursively: Bool = false) {
        var paths: Set<String> = [node.id]
        if recursively {
            paths.formUnion(DiffTree.expandableDirectoryPaths(in: node.children ?? [], onlyWithDifferences: false))
        }
        if expanded {
            expandedPaths.formUnion(paths)
        } else {
            expandedPaths.subtract(paths)
        }
        rebuildTreeRows()
    }

    func expandAll() {
        expandedPaths = DiffTree.expandableDirectoryPaths(in: rootNodes, onlyWithDifferences: false)
        rebuildTreeRows()
    }

    func collapseAll() {
        expandedPaths = []
        rebuildTreeRows()
    }

    /// Right arrow in the sidebar: expand the selected folder.
    func expandSelection() -> Bool {
        guard sidebarMode == .tree, let node = selectedNode, node.hasChildren, !expandedPaths.contains(node.id) else { return false }
        setExpanded(true, node: node)
        return true
    }

    /// Left arrow in the sidebar: collapse the selected folder, or move to its parent.
    func collapseSelectionOrSelectParent() -> Bool {
        guard sidebarMode == .tree, let node = selectedNode else { return false }
        if node.hasChildren, expandedPaths.contains(node.id) {
            setExpanded(false, node: node)
            return true
        }
        let parent = DiffTree.parentPath(of: node.id)
        guard !parent.isEmpty else { return false }
        select(nodeID: parent)
        sidebarScrollRequest = SidebarScrollRequest(nodeID: parent)
        return true
    }

    /// Expands the tree down to a node and scrolls it into view.
    func reveal(_ nodeID: String) {
        let ancestors = DiffTree.ancestorPaths(of: nodeID)
        if !ancestors.allSatisfy(expandedPaths.contains) {
            expandedPaths.formUnion(ancestors)
            rebuildTreeRows()
        }
        sidebarScrollRequest = SidebarScrollRequest(nodeID: nodeID)
    }

    /// Shows a node in the tree, clearing filters that would hide it.
    func revealInTree(_ nodeID: String) {
        sidebarMode = .tree
        if isKindFilterActive || !searchQuery.isEmpty { resetFilters() }
        if let node = DiffTree.node(at: nodeID, in: rootNodes), node.status == .identical, showOnlyDifferences {
            showOnlyDifferences = false
        }
        reveal(nodeID)
        select(nodeID: nodeID)
    }

    // MARK: - Selection

    var selectedNodes: [DiffNode] {
        selectedIDs.sorted().compactMap { DiffTree.node(at: $0, in: rootNodes) }
    }

    func select(nodeID: String?) {
        select(ids: nodeID.map { [$0] } ?? [])
    }

    func select(ids: Set<String>) {
        guard ids != selectedIDs else { return }
        if editSession != nil {
            // Keep the current selection (and snap the list back) until edits are dealt with.
            selectedIDs = selectedIDs
            requestLeavingEdits { [weak self] in self?.select(ids: ids) }
            return
        }
        selectedIDs = ids
        guard ids.count == 1, let id = ids.first, let node = DiffTree.node(at: id, in: rootNodes) else {
            selectedNode = nil
            clearDiff()
            return
        }
        guard node.id != selectedNode?.id else { return }
        selectedNode = node
        loadDiff(for: node, preservePosition: false)
    }

    func clearSelection() {
        selectedIDs = []
        selectedNode = nil
        clearDiff()
    }

    /// Selects the next/previous differing file in tree order (independent of filters and
    /// folder expansion).
    func selectAdjacentChangedFile(forward: Bool) {
        guard !changedFileOrder.isEmpty else {
            NSSound.beep()
            return
        }
        let targetIndex: Int
        if let current = selectedNode?.id {
            if let index = changedFileIndex[current] {
                targetIndex = index + (forward ? 1 : -1)
            } else {
                // The selection isn't a changed file: find where it sits among them.
                let insertion = changedFilesBefore(current)
                targetIndex = forward ? insertion : insertion - 1
            }
        } else {
            targetIndex = forward ? 0 : changedFileOrder.count - 1
        }
        guard changedFileOrder.indices.contains(targetIndex) else {
            NSSound.beep()
            return
        }
        let target = changedFileOrder[targetIndex]
        if sidebarMode == .tree { reveal(target) }
        select(nodeID: target)
        sidebarScrollRequest = SidebarScrollRequest(nodeID: target)
    }

    /// Number of changed files that come before `nodeID` in tree order.
    private func changedFilesBefore(_ nodeID: String) -> Int {
        var count = 0
        var found = false
        func visit(_ level: [DiffNode]) {
            for node in level {
                if found { return }
                if node.id == nodeID {
                    found = true
                    return
                }
                if changedFileIndex[node.id] != nil { count += 1 }
                if let children = node.children { visit(children) }
            }
        }
        visit(rootNodes)
        return count
    }
}

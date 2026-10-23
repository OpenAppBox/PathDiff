//
//  DiffViewModel+Diff.swift
//  PathDiff
//

import AppKit
import Foundation

/// Loading the selected file's diff, folding, change navigation and block-level sync.
extension DiffViewModel {
    var textDiff: TextDiff? {
        if case .text(let diff) = activeDiff { diff } else { nil }
    }

    var currentHunk: DiffHunk? {
        guard let diff = textDiff, let index = currentHunkIndex, diff.hunks.indices.contains(index) else { return nil }
        return diff.hunks[index]
    }

    /// Block-level sync needs a text file on both sides.
    var canApplyHunks: Bool {
        guard let diff = textDiff, let node = activeDiffNode else { return false }
        // Not while editing: the block would be written from the diff loaded before editing,
        // behind the editor's back.
        return diff.left != nil && diff.right != nil && node.existsOnLeft && node.existsOnRight && !isPerformingFileOperation
            && editSession == nil
    }

    /// The pair of files to compare for a node. A moved file is compared with its
    /// counterpart, so renamed-and-edited files show their real changes.
    func comparisonTarget(for node: DiffNode) -> (node: DiffNode, paths: Set<String>) {
        guard !node.isDirectory, let match = moves.match(for: node),
              let leftNode = DiffTree.node(at: match.leftPath, in: rootNodes),
              let rightNode = DiffTree.node(at: match.rightPath, in: rootNodes)
        else { return (node, [node.relativePath]) }
        let paired = DiffNode(
            name: node.name,
            relativePath: node.relativePath,
            leftURL: leftNode.leftURL,
            rightURL: rightNode.rightURL,
            leftMetadata: leftNode.leftMetadata,
            rightMetadata: rightNode.rightMetadata,
            status: match.isExact ? .identical : .modified,
            children: nil
        )
        return (paired, [match.leftPath, match.rightPath])
    }

    func loadDiff(for node: DiffNode, preservePosition: Bool) {
        diffTask?.cancel()
        let target = comparisonTarget(for: node)
        activeDiffNode = target.node
        activeDiffPaths = target.paths
        if !preservePosition {
            activeDiff = .loading
            activeDiffLines = []
            displayItems = []
            currentHunkIndex = nil
            diffScrollRequest = nil
            expandedFolds = []
        }
        let options = settings.diffOptions
        let highlightSyntax = settings.highlightsSyntax
        diffTask = Task { [weak self] in
            let content = await DiffEngine.computeDiff(for: target.node, options: options, highlightSyntax: highlightSyntax)
            guard let self, !Task.isCancelled, self.selectedNode?.id == node.id else { return }
            self.applyDiffContent(content, preservePosition: preservePosition)
        }
    }

    func clearDiff() {
        diffTask?.cancel()
        activeDiffNode = nil
        activeDiffPaths = []
        activeDiff = .none
        activeDiffLines = []
        displayItems = []
        currentHunkIndex = nil
        expandedFolds = []
    }

    private func applyDiffContent(_ content: FileDiffContent, preservePosition: Bool) {
        if preservePosition, content == activeDiff { return }
        activeDiff = content
        guard case .text(let diff) = content else {
            activeDiffLines = []
            displayItems = []
            currentHunkIndex = nil
            return
        }
        activeDiffLines = diff.lines
        if preservePosition, let current = currentHunkIndex {
            currentHunkIndex = diff.hunks.isEmpty ? nil : min(current, diff.hunks.count - 1)
        } else {
            currentHunkIndex = diff.hunks.isEmpty ? nil : 0
        }
        rebuildDisplayItems()
        if !preservePosition, let index = currentHunkIndex {
            diffScrollRequest = DiffScrollRequest(rowID: displayID(forHunk: index))
        }
    }

    /// Reloads the selected file, e.g. after toggling syntax highlighting.
    func reloadActiveDiff() {
        guard let node = selectedNode else { return }
        loadDiff(for: node, preservePosition: true)
    }

    /// The display item a change starts at, in the current layout.
    func displayID(forHunk index: Int) -> Int {
        guard let diff = textDiff, diff.hunks.indices.contains(index) else { return 0 }
        let rows = diff.hunks[index].rowRange
        guard settings.diffLayout == .unified else { return rows.lowerBound }
        if let removed = rows.first(where: { diff.lines[$0].leftContent != nil }) {
            return DiffDisplayItem.unified(row: removed, part: .removed).id
        }
        return DiffDisplayItem.unified(row: rows.lowerBound, part: .added).id
    }

    /// Rebuilds the visible rows, folding long unchanged stretches when enabled.
    func rebuildDisplayItems() {
        guard let diff = textDiff else {
            displayItems = []
            return
        }
        let sideBySide = sideBySideItems(diff)
        displayItems = settings.diffLayout == .unified ? Self.unifiedItems(from: sideBySide, diff: diff) : sideBySide
    }

    /// Converts side-by-side rows to the unified layout: each change lists all removed lines,
    /// then all added lines.
    static func unifiedItems(from items: [DiffDisplayItem], diff: TextDiff) -> [DiffDisplayItem] {
        var result: [DiffDisplayItem] = []
        result.reserveCapacity(items.count + items.count / 4)
        var emittedHunks = Set<Int>()
        for item in items {
            guard case .line(let row) = item else {
                result.append(item)
                continue
            }
            let line = diff.lines[row]
            guard let hunkIndex = line.hunkIndex else {
                result.append(.unified(row: row, part: .context))
                continue
            }
            guard emittedHunks.insert(hunkIndex).inserted else { continue }
            let rows = diff.hunks[hunkIndex].rowRange
            for removed in rows where diff.lines[removed].leftContent != nil {
                result.append(.unified(row: removed, part: .removed))
            }
            for added in rows where diff.lines[added].rightContent != nil {
                result.append(.unified(row: added, part: .added))
            }
        }
        return result
    }

    private func sideBySideItems(_ diff: TextDiff) -> [DiffDisplayItem] {
        let count = diff.lines.count
        guard settings.collapseUnchanged, !diff.hunks.isEmpty else {
            return (0..<count).map(DiffDisplayItem.line)
        }

        let context = max(0, settings.contextLines)
        let minimumFold = 4
        var items: [DiffDisplayItem] = []
        items.reserveCapacity(count)
        var index = 0
        while index < count {
            guard diff.lines[index].type == .unchanged else {
                items.append(.line(index))
                index += 1
                continue
            }
            var end = index
            while end < count, diff.lines[end].type == .unchanged { end += 1 }
            let foldStart = index == 0 ? 0 : index + context
            let foldEnd = end == count ? count : end - context
            if foldEnd - foldStart >= minimumFold, !expandedFolds.contains(foldStart) {
                items.append(contentsOf: (index..<foldStart).map(DiffDisplayItem.line))
                items.append(.fold(foldStart..<foldEnd))
                items.append(contentsOf: (foldEnd..<end).map(DiffDisplayItem.line))
            } else {
                items.append(contentsOf: (index..<end).map(DiffDisplayItem.line))
            }
            index = end
        }
        return items
    }

    func expandFold(_ range: Range<Int>) {
        expandedFolds.insert(range.lowerBound)
        rebuildDisplayItems()
    }

    // MARK: - Change navigation

    func goToNextChange() { moveHunk(by: 1) }
    func goToPreviousChange() { moveHunk(by: -1) }

    private func moveHunk(by delta: Int) {
        guard let diff = textDiff, !diff.hunks.isEmpty else {
            NSSound.beep()
            return
        }
        let target = currentHunkIndex.map { $0 + delta } ?? (delta > 0 ? 0 : diff.hunks.count - 1)
        guard diff.hunks.indices.contains(target) else {
            NSSound.beep()
            return
        }
        focusHunk(target)
    }

    func focusHunk(_ index: Int) {
        guard let diff = textDiff, diff.hunks.indices.contains(index) else { return }
        currentHunkIndex = index
        diffScrollRequest = DiffScrollRequest(rowID: displayID(forHunk: index))
    }

    // MARK: - Block sync

    func applyCurrentHunk(direction: SyncDirection) {
        guard let index = currentHunkIndex else {
            NSSound.beep()
            return
        }
        applyHunk(at: index, direction: direction)
    }

    /// Copies one change block to the other side and writes that file.
    func applyHunk(at index: Int, direction: SyncDirection) {
        guard canApplyHunks, let diff = textDiff, diff.hunks.indices.contains(index),
              let node = activeDiffNode, let leftDocument = diff.left, let rightDocument = diff.right,
              let leftURL = node.leftURL, let rightURL = node.rightURL
        else { return }

        let hunk = diff.hunks[index]
        let destinationURL: URL
        let original: TextDocument
        let updated: TextDocument
        switch direction {
        case .leftToRight:
            destinationURL = rightURL
            original = rightDocument
            updated = rightDocument.replacingLines(hunk.rightRange, withLinesFrom: leftDocument, sourceRange: hunk.leftRange)
        case .rightToLeft:
            destinationURL = leftURL
            original = leftDocument
            updated = leftDocument.replacingLines(hunk.leftRange, withLinesFrom: rightDocument, sourceRange: hunk.rightRange)
        }

        currentHunkIndex = index
        let service = fileService
        let history = HistoryContext(
            kind: .copyChange,
            title: String(localized: "Copy change to \(sideName(direction.destination)): \(destinationURL.lastPathComponent)"),
            direction: direction,
            side: direction.destination
        )
        let actionName = direction == .leftToRight ? String(localized: "Copy Change Left → Right") : String(localized: "Copy Change Right → Left")
        performFileOperation(actionName: actionName, refreshPaths: activeDiffPaths, history: history) {
            let snapshots = try await service.capture([destinationURL])
            try await service.write(updated, to: destinationURL, expecting: original)
            return snapshots
        }
    }
}

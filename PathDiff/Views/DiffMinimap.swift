//
//  DiffMinimap.swift
//  PathDiff
//

import SwiftUI

/// A miniature of the whole diff: each line drawn as a bar whose length follows the line's
/// length, colored by change, with the visible region outlined. Click or drag to scroll.
///
/// The line map is an equatable layer redrawn only when the diff changes; the viewport
/// overlay is the only part that updates while scrolling.
struct DiffMinimap: View {
    let items: [DiffDisplayItem]
    let lines: [LineDiff]
    let currentHunk: Int?
    let tracker: ScrollTracker
    let onScrub: (Double) -> Void

    /// At most this many points per line; short files don't stretch to fill the height.
    static let maximumLineHeight: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let contentHeight = min(geometry.size.height, CGFloat(max(items.count, 1)) * Self.maximumLineHeight)
            ZStack(alignment: .top) {
                MinimapLines(items: items, lines: lines, currentHunk: currentHunk)
                    .equatable()
                    .frame(height: contentHeight)
                MinimapViewport(tracker: tracker, contentHeight: contentHeight)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onScrub(min(1, max(0, value.location.y / max(contentHeight, 1))))
            })
        }
        .background(DiffPalette.gutterBackground)
        .help("Minimap — click or drag to scroll")
        .accessibilityLabel("Minimap")
    }
}

private struct MinimapViewport: View {
    let tracker: ScrollTracker
    let contentHeight: CGFloat

    var body: some View {
        let viewport = tracker.viewport
        let top = viewport.top * contentHeight
        let height = max(8, (viewport.bottom - viewport.top) * contentHeight)
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.primary.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.25)))
            .frame(height: height)
            .offset(y: top)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }
}

private struct MinimapLines: View, Equatable {
    let items: [DiffDisplayItem]
    let lines: [LineDiff]
    let currentHunk: Int?

    static func == (lhs: MinimapLines, rhs: MinimapLines) -> Bool {
        guard lhs.currentHunk == rhs.currentHunk, lhs.items == rhs.items else { return false }
        // Redrawing while scrolling passes the same array, which is equal without comparing
        // every line; a changed file (e.g. after copying a block) is compared in full.
        let sameStorage = lhs.lines.withUnsafeBufferPointer { left in
            rhs.lines.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress && left.count == right.count }
        }
        return sameStorage || lhs.lines == rhs.lines
    }

    /// What one lane shows in one pixel row; changes win over unchanged lines.
    private enum Mark: Int, Comparable {
        case empty, unchanged, fold, added, removed, current

        static func < (lhs: Mark, rhs: Mark) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct Bucket {
        var left = Mark.empty
        var right = Mark.empty
        var leftLength = 0
        var rightLength = 0
    }

    var body: some View {
        // Drawn on the main thread: the renderer reads main-actor state, and the layer is
        // equatable, so it only redraws when the diff changes.
        Canvas { context, size in
            let rowCount = max(1, Int(size.height))
            var buckets = [Bucket](repeating: Bucket(), count: rowCount)
            let total = max(items.count, 1)
            let unified = items.contains { if case .unified = $0 { true } else { false } }

            for (index, item) in items.enumerated() {
                let row = min(rowCount - 1, index * rowCount / total)
                switch item {
                case .fold:
                    buckets[row].left = max(buckets[row].left, .fold)
                    buckets[row].right = max(buckets[row].right, .fold)
                case .line(let lineIndex):
                    let line = lines[lineIndex]
                    let isCurrent = line.hunkIndex != nil && line.hunkIndex == currentHunk
                    if let content = line.leftContent {
                        let mark: Mark = line.type == .unchanged ? .unchanged : (isCurrent ? .current : .removed)
                        buckets[row].left = max(buckets[row].left, mark)
                        buckets[row].leftLength = max(buckets[row].leftLength, content.utf8.count)
                    }
                    if let content = line.rightContent {
                        let mark: Mark = line.type == .unchanged ? .unchanged : (isCurrent ? .current : .added)
                        buckets[row].right = max(buckets[row].right, mark)
                        buckets[row].rightLength = max(buckets[row].rightLength, content.utf8.count)
                    }
                case .unified(let lineIndex, let part):
                    let line = lines[lineIndex]
                    let isCurrent = line.hunkIndex != nil && line.hunkIndex == currentHunk
                    let content = (part == .added ? line.rightContent : line.leftContent) ?? ""
                    let mark: Mark = switch part {
                    case .context: .unchanged
                    case .removed: isCurrent ? .current : .removed
                    case .added: isCurrent ? .current : .added
                    }
                    buckets[row].left = max(buckets[row].left, mark)
                    buckets[row].leftLength = max(buckets[row].leftLength, content.utf8.count)
                }
            }

            let rowHeight = size.height / CGFloat(rowCount)
            let inset: CGFloat = 4
            let gap: CGFloat = 4
            let laneWidth = unified ? size.width - inset * 2 : (size.width - inset * 2 - gap) / 2
            for (row, bucket) in buckets.enumerated() {
                let y = CGFloat(row) * rowHeight
                draw(bucket.left, length: bucket.leftLength, x: inset, y: y, laneWidth: laneWidth, rowHeight: rowHeight, in: &context)
                if !unified {
                    draw(bucket.right, length: bucket.rightLength, x: inset + laneWidth + gap, y: y, laneWidth: laneWidth, rowHeight: rowHeight, in: &context)
                }
            }
        }
    }

    private func draw(_ mark: Mark, length: Int, x: CGFloat, y: CGFloat, laneWidth: CGFloat, rowHeight: CGFloat, in context: inout GraphicsContext) {
        let color: Color
        var width = laneWidth * min(1, max(0.08, CGFloat(length) / 100))
        switch mark {
        case .empty: return
        case .unchanged: color = Color.secondary.opacity(0.35)
        case .fold:
            color = Color.secondary.opacity(0.18)
            width = laneWidth
        case .added: color = DiffPalette.added.opacity(0.85)
        case .removed: color = DiffPalette.deleted.opacity(0.85)
        case .current: color = Color.accentColor
        }
        if mark == .added || mark == .removed || mark == .current { width = max(width, laneWidth * 0.5) }
        let height = max(1, rowHeight * 0.8)
        context.fill(Path(CGRect(x: x, y: y, width: width, height: height)), with: .color(color))
    }
}

//
//  SideBySideDiffView.swift
//  PathDiff
//

import SwiftUI

/// Left file vs. right file, line by line, side by side or unified, with a minimap.
///
/// In the side-by-side layout both panes live in the same row of a single lazily-rendered
/// scroll view, so vertical scrolling is synchronized by construction and paired lines
/// always share one height, even when long lines wrap.
struct SideBySideDiffView: View {
    let viewModel: DiffViewModel
    let node: DiffNode
    let diff: TextDiff

    @Environment(AppSettings.self) private var settings
    /// Scroll position for the minimap's viewport, kept out of this view's state so that
    /// scrolling doesn't re-evaluate the row list.
    @State private var scrollTracker = ScrollTracker()

    static let centerColumnWidth: CGFloat = 48
    static let minimapWidth: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            DiffHeaderBar(viewModel: viewModel, node: node, diff: diff)
            Divider()
            if let move = viewModel.moves.match(for: node) {
                MoveBanner(viewModel: viewModel, node: node, match: move)
                Divider()
            }
            PaneTitleBar(node: viewModel.activeDiffNode ?? node, diff: diff, viewModel: viewModel, showsMinimap: settings.showsMinimap)
            Divider()
            if let notice {
                NoticeBanner(text: notice.text, systemImage: notice.symbol)
                Divider()
            }
            ScrollViewReader { proxy in
                HStack(spacing: 0) {
                    rows
                    if settings.showsMinimap {
                        Divider()
                        DiffMinimap(
                            items: viewModel.displayItems,
                            lines: diff.lines,
                            currentHunk: viewModel.currentHunkIndex,
                            tracker: scrollTracker
                        ) { fraction in
                            let items = viewModel.displayItems
                            guard !items.isEmpty else { return }
                            let index = min(items.count - 1, max(0, Int(fraction * Double(items.count))))
                            proxy.scrollTo(items[index].id, anchor: .center)
                        }
                        .frame(width: Self.minimapWidth)
                    }
                }
                .task(id: viewModel.diffScrollRequest) {
                    guard let request = viewModel.diffScrollRequest else { return }
                    // Let the lazy stack lay out before jumping.
                    await Task.yield()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(request.rowID, anchor: UnitPoint(x: 0, y: 0.25))
                    }
                }
            }
        }
    }

    private var rows: some View {
        let gutterWidth = Self.gutterWidth(for: diff, fontSize: settings.fontSize)
        let canApply = viewModel.canApplyHunks
        let tracker = scrollTracker
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.displayItems) { item in
                    switch item {
                    case .line(let index):
                        let line = diff.lines[index]
                        DiffRowView(
                            line: line,
                            leftSyntax: diff.leftSyntax?.spans(forLine: line.leftLineNumber) ?? [],
                            rightSyntax: diff.rightSyntax?.spans(forLine: line.rightLineNumber) ?? [],
                            fontSize: settings.fontSize,
                            gutterWidth: gutterWidth,
                            wrapLines: settings.wrapLines,
                            isHunkStart: isHunkStart(line),
                            isCurrentHunk: line.hunkIndex != nil && line.hunkIndex == viewModel.currentHunkIndex,
                            canApply: canApply
                        ) { direction in
                            if let hunk = line.hunkIndex {
                                viewModel.applyHunk(at: hunk, direction: direction)
                            }
                        } onFocus: {
                            if let hunk = line.hunkIndex { viewModel.focusHunk(hunk) }
                        }
                        .equatable()
                    case .unified(let index, let part):
                        let line = diff.lines[index]
                        UnifiedRowView(
                            line: line,
                            part: part,
                            syntax: part == .added
                                ? diff.rightSyntax?.spans(forLine: line.rightLineNumber) ?? []
                                : diff.leftSyntax?.spans(forLine: line.leftLineNumber) ?? [],
                            fontSize: settings.fontSize,
                            gutterWidth: gutterWidth,
                            wrapLines: settings.wrapLines,
                            isHunkStart: item.id == hunkStartID(line),
                            isCurrentHunk: line.hunkIndex != nil && line.hunkIndex == viewModel.currentHunkIndex,
                            canApply: canApply
                        ) { direction in
                            if let hunk = line.hunkIndex {
                                viewModel.applyHunk(at: hunk, direction: direction)
                            }
                        } onFocus: {
                            if let hunk = line.hunkIndex { viewModel.focusHunk(hunk) }
                        }
                        .equatable()
                    case .fold(let range):
                        FoldRowView(lineCount: range.count) {
                            viewModel.expandFold(range)
                        }
                    }
                }
            }
        }
        .onScrollGeometryChange(for: ScrollTracker.Viewport.self) { geometry in
            let height = max(geometry.contentSize.height, 1)
            return ScrollTracker.Viewport(
                top: max(0, geometry.visibleRect.minY / height),
                bottom: min(1, geometry.visibleRect.maxY / height)
            )
        } action: { _, viewport in
            tracker.viewport = viewport
        }
    }

    private func isHunkStart(_ line: LineDiff) -> Bool {
        guard let hunk = line.hunkIndex, diff.hunks.indices.contains(hunk) else { return false }
        return diff.hunks[hunk].rowRange.lowerBound == line.id
    }

    private func hunkStartID(_ line: LineDiff) -> Int? {
        guard let hunk = line.hunkIndex else { return nil }
        return viewModel.displayID(forHunk: hunk)
    }

    private var notice: (text: String, symbol: String)? {
        if diff.left == nil {
            return (String(localized: "This file exists only in “\(viewModel.sideName(.right))”."), "plus.circle")
        }
        if diff.right == nil {
            return (String(localized: "This file exists only in “\(viewModel.sideName(.left))”."), "minus.circle")
        }
        guard !diff.hasTextualChanges else { return nil }
        if (viewModel.activeDiffNode ?? node).status == .identical {
            return (String(localized: "The files are identical."), "checkmark.circle")
        }
        if diff.options.ignoreWhitespace {
            return (String(localized: "No differences other than whitespace (Ignore Whitespace is on)."), "info.circle")
        }
        return (String(localized: "The text is the same; the files differ only in line endings, encoding, byte-order mark or a trailing newline."), "info.circle")
    }

    static func gutterWidth(for diff: TextDiff, fontSize: Double) -> CGFloat {
        let lineCount = max(diff.left?.lines.count ?? 0, diff.right?.lines.count ?? 0)
        let digits = max(3, String(lineCount).count)
        return CGFloat(digits) * fontSize * 0.62 + 8
    }
}

/// The visible part of the diff, as fractions of its full height.
@Observable
final class ScrollTracker {
    struct Viewport: Equatable {
        var top: Double
        var bottom: Double
    }

    var viewport = Viewport(top: 0, bottom: 1)
}

// MARK: - Header

private struct DiffHeaderBar: View {
    let viewModel: DiffViewModel
    let node: DiffNode
    let diff: TextDiff

    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        HStack(spacing: 10) {
            BadgedFileIcon(node: node, move: viewModel.moves.match(for: node), size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(node.name).font(.headline).lineLimit(1)
                    if let language = diff.leftSyntax?.languageName ?? diff.rightSyntax?.languageName {
                        TagLabel(text: language)
                    }
                }
                Text(DiffTree.parentPath(of: node.relativePath).isEmpty ? "/" : DiffTree.parentPath(of: node.relativePath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(node.relativePath)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            changeNavigator

            Divider().frame(height: 18)

            ControlGroup {
                Button {
                    viewModel.copy(node, direction: .rightToLeft)
                } label: {
                    Label("Copy to Left", systemImage: "arrow.left.square")
                }
                .disabled(!viewModel.canCopy(node, direction: .rightToLeft))
                .help("Copy this file from “\(viewModel.sideName(.right))” to the same path in “\(viewModel.sideName(.left))” (⇧⌥⌘←)")

                Button {
                    viewModel.copy(node, direction: .leftToRight)
                } label: {
                    Label("Copy to Right", systemImage: "arrow.right.square")
                }
                .disabled(!viewModel.canCopy(node, direction: .leftToRight))
                .help("Copy this file from “\(viewModel.sideName(.left))” to the same path in “\(viewModel.sideName(.right))” (⇧⌥⌘→)")
            }
            .controlGroupStyle(.navigation)
            .fixedSize()

            if DiffEngine.isImage(node.relativePath) {
                Button {
                    viewModel.showsImageComparison = true
                } label: {
                    Label("Compare as Image", systemImage: "photo")
                }
                .help("Show the visual image comparison")
            }

            Button {
                viewModel.beginEditing()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(!viewModel.canEdit)
            .help(viewModel.canEdit ? String(localized: "Edit both files here, then save (⌥⌘E)") : String(localized: "Files over 10 MB can’t be edited here"))

            Picker("Layout", selection: $settings.diffLayout) {
                Label("Side by Side", systemImage: "rectangle.split.2x1").tag(DiffLayout.sideBySide)
                Label("Unified", systemImage: "rectangle.grid.1x2").tag(DiffLayout.unified)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .fixedSize()
            .help("Side by side or unified (⌃⌘1 / ⌃⌘2)")

            Menu {
                Toggle("Wrap Long Lines", isOn: $settings.wrapLines)
                Toggle("Collapse Unchanged Lines", isOn: $settings.collapseUnchanged)
                Toggle("Syntax Highlighting", isOn: $settings.highlightsSyntax)
                Toggle("Show Minimap", isOn: $settings.showsMinimap)
                Divider()
                Button("Bigger Text") { settings.fontSize = min(settings.fontSize + 1, 28) }
                Button("Smaller Text") { settings.fontSize = max(settings.fontSize - 1, 8) }
                Button("Default Text Size") { settings.fontSize = 12 }
                Divider()
                Button("Copy Diff as Patch") { viewModel.copyPatchForCurrentFile() }
                    .disabled(!diff.hasTextualChanges && diff.left != nil && diff.right != nil)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("View Options")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var changeNavigator: some View {
        if diff.hunks.isEmpty {
            TagLabel(text: String(localized: "No Changes"), color: .secondary, systemImage: "checkmark")
        } else {
            HStack(spacing: 2) {
                Button {
                    viewModel.goToPreviousChange()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .help("Previous Change (⌥⌘↑)")

                positionText
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 64)
                    .contentTransition(.numericText())

                Button {
                    viewModel.goToNextChange()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .help("Next Change (⌥⌘↓)")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 3)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Palette.cardStroke))
            .fixedSize()
        }
    }

    private var positionText: Text {
        let total = diff.hunks.count
        guard let current = viewModel.currentHunkIndex else {
            return Text("\(total) changes")
        }
        let position = Text(verbatim: "\(current + 1)").fontWeight(.semibold).foregroundStyle(.primary)
        return Text("\(position) of \(total)")
    }
}

/// Per-pane file facts, aligned over the two columns.
private struct PaneTitleBar: View {
    let node: DiffNode
    let diff: TextDiff
    let viewModel: DiffViewModel
    let showsMinimap: Bool

    var body: some View {
        HStack(spacing: 0) {
            title(for: .left, document: diff.left)
            Divider()
            Color.clear.frame(width: SideBySideDiffView.centerColumnWidth)
            Divider()
            title(for: .right, document: diff.right)
            if showsMinimap {
                Color.clear.frame(width: SideBySideDiffView.minimapWidth)
            }
        }
        .frame(height: 28)
        .background(DiffPalette.gutterBackground)
    }

    private func title(for side: Side, document: TextDocument?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: side == .left ? "l.square.fill" : "r.square.fill")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(viewModel.sideName(side))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .layoutPriority(1)
            if let document, let metadata = node.metadata(on: side) {
                Text(details(document, metadata))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(node.url(on: side).map { $0.path(percentEncoded: false) } ?? "")
            } else {
                Text("Missing")
                    .font(.caption.italic())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }

    private func details(_ document: TextDocument, _ metadata: ItemMetadata) -> String {
        var parts = [
            DisplayFormat.byteCount(metadata.size),
            String(localized: "\(document.lines.count) lines"),
            document.encoding.shortName + (document.hasByteOrderMark ? " BOM" : ""),
        ]
        if let terminator = document.dominantTerminator {
            let mixed = Set(document.terminators.filter { $0 != .none }).count > 1
            parts.append(mixed ? String(localized: "Mixed line endings") : terminator.displayName)
        }
        if !document.lines.isEmpty && !document.hasTrailingNewline {
            parts.append(String(localized: "No final newline"))
        }
        parts.append(DisplayFormat.date(metadata.modificationDate))
        return parts.joined(separator: " · ")
    }
}

/// Explains a detected move and offers to make both trees agree on the path.
struct MoveBanner: View {
    let viewModel: DiffViewModel
    let node: DiffNode
    let match: MoveMatch
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let left = viewModel.sideName(.left)
        let right = viewModel.sideName(.right)
        HStack(alignment: .center, spacing: 12) {
            IconTile(systemName: "arrow.turn.down.right", color: ChangeKind.moved.color, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.callout.weight(.semibold))
                Text(verbatim: "\(left): \(match.leftPath)\n\(right): \(match.rightPath)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if match.isDirectory {
                Button("Compare in New Window") {
                    if let request = viewModel.comparisonRequest(for: node) { openWindow(value: request) }
                }
            }
            Menu("Apply Move") {
                Button("Move in “\(right)” to “\(match.leftPath)”") { viewModel.applyMove(match, on: .right) }
                Button("Move in “\(left)” to “\(match.rightPath)”") { viewModel.applyMove(match, on: .left) }
            }
            .fixedSize()
            .disabled(viewModel.isPerformingFileOperation)
            .help("Rename the item on one side so both folders have it at the same path. Undo with ⌘Z.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(ChangeKind.moved.color.opacity(0.07))
    }

    private var headline: String {
        if match.isDirectory {
            // One whole sentence per case, so each can be translated as a unit.
            let matched = match.matchedFiles
            let total = match.totalFiles
            if matched == total {
                if total == 1 {
                    return match.isExact
                        ? String(localized: "Folder moved — its file moved along unchanged")
                        : String(localized: "Folder moved — its file moved along, with edits")
                }
                return match.isExact
                    ? String(localized: "Folder moved — all \(total) files moved along unchanged")
                    : String(localized: "Folder moved — all \(total) files moved along; some changed or stayed behind")
            }
            if match.isExact {
                return String(localized: "Folder moved — \(matched) of \(total) files moved along unchanged")
            }
            return total == 1
                ? String(localized: "Folder moved — \(matched) of \(total) files moved along, with edits")
                : String(localized: "Folder moved — \(matched) of \(total) files moved along; some changed or stayed behind")
        }
        return match.isExact
            ? String(localized: "Moved with identical contents")
            : String(localized: "Moved and edited — showing the changes between both locations")
    }
}

private struct NoticeBanner: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(Color.accentColor)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.06))
    }
}

// MARK: - Rows

struct DiffRowView: View, Equatable {
    let line: LineDiff
    let leftSyntax: [SyntaxSpan]
    let rightSyntax: [SyntaxSpan]
    let fontSize: Double
    let gutterWidth: CGFloat
    let wrapLines: Bool
    let isHunkStart: Bool
    let isCurrentHunk: Bool
    let canApply: Bool
    let onApply: (SyncDirection) -> Void
    let onFocus: () -> Void

    static func == (lhs: DiffRowView, rhs: DiffRowView) -> Bool {
        lhs.line == rhs.line
            && lhs.leftSyntax == rhs.leftSyntax
            && lhs.rightSyntax == rhs.rightSyntax
            && lhs.fontSize == rhs.fontSize
            && lhs.gutterWidth == rhs.gutterWidth
            && lhs.wrapLines == rhs.wrapLines
            && lhs.isHunkStart == rhs.isHunkStart
            && lhs.isCurrentHunk == rhs.isCurrentHunk
            && lhs.canApply == rhs.canApply
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            half(.left)
            centerColumn
            half(.right)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) {
            if isHunkStart {
                Rectangle()
                    .fill(isCurrentHunk ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.18))
                    .frame(height: 1)
            }
        }
    }

    private func half(_ side: Side) -> some View {
        let number = side == .left ? line.leftLineNumber : line.rightLineNumber
        let content = side == .left ? line.leftContent : line.rightContent
        let isChanged = isChanged(side, hasContent: content != nil)
        return HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: max(fontSize - 1, 7), design: .monospaced))
                .foregroundStyle(isChanged ? AnyShapeStyle(markerColor(side)) : AnyShapeStyle(.tertiary))
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 5)
                .padding(.vertical, 1)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(isChanged ? (side == .left ? DiffPalette.deletedGutter : DiffPalette.addedGutter) : .clear)
            Rectangle()
                .fill(markerColor(side))
                .frame(width: 3)
            Group {
                if let content {
                    Text(attributedContent(content, side: side))
                        .lineLimit(wrapLines ? nil : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: wrapLines)
                        .textSelection(.enabled)
                } else {
                    Text(verbatim: " ")
                }
            }
            .font(.system(size: fontSize, design: .monospaced))
            .padding(.leading, 6)
            .padding(.trailing, 4)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background(side, hasContent: content != nil))
    }

    private var centerColumn: some View {
        ZStack {
            if line.type != .unchanged {
                Rectangle().fill(isCurrentHunk ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
            }
            if isHunkStart && canApply {
                HStack(spacing: 4) {
                    HunkApplyButton(direction: .rightToLeft, isCurrent: isCurrentHunk) { onApply(.rightToLeft) }
                    HunkApplyButton(direction: .leftToRight, isCurrent: isCurrentHunk) { onApply(.leftToRight) }
                }
                .padding(.top, 1)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: SideBySideDiffView.centerColumnWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
    }

    private func isChanged(_ side: Side, hasContent: Bool) -> Bool {
        guard hasContent else { return false }
        switch (line.type, side) {
        case (.deleted, .left), (.modified, .left), (.added, .right), (.modified, .right): return true
        default: return false
        }
    }

    private func markerColor(_ side: Side) -> Color {
        switch (line.type, side) {
        case (.deleted, .left), (.modified, .left): DiffPalette.deleted.opacity(0.8)
        case (.added, .right), (.modified, .right): DiffPalette.added.opacity(0.8)
        default: .clear
        }
    }

    private func background(_ side: Side, hasContent: Bool) -> Color {
        guard hasContent else { return DiffPalette.fillerBackground }
        switch (line.type, side) {
        case (.deleted, .left), (.modified, .left): return DiffPalette.deletedBackground
        case (.added, .right), (.modified, .right): return DiffPalette.addedBackground
        default: return .clear
        }
    }

    private func attributedContent(_ content: String, side: Side) -> AttributedString {
        let highlights = side == .left ? line.leftHighlights : line.rightHighlights
        let color = side == .left ? DiffPalette.deletedHighlight : DiffPalette.addedHighlight
        return DiffTextRenderer.attributed(content, highlights: highlights, highlightColor: color, syntax: side == .left ? leftSyntax : rightSyntax)
    }
}

struct FoldRowView: View {
    let lineCount: Int
    let action: () -> Void

    @State private var isHovered = false

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                rule
                Label("\(lineCount) unchanged lines", systemImage: "chevron.up.chevron.down")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isHovered ? Color.accentColor : .secondary)
                    .fixedSize()
                rule
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(isHovered ? Color.accentColor.opacity(0.07) : DiffPalette.fillerBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Show these lines")
    }
}

// MARK: - Unified rows

/// One line of the unified layout: removed and added lines are stacked, each with both
/// line-number columns.
struct UnifiedRowView: View, Equatable {
    let line: LineDiff
    let part: UnifiedPart
    let syntax: [SyntaxSpan]
    let fontSize: Double
    let gutterWidth: CGFloat
    let wrapLines: Bool
    let isHunkStart: Bool
    let isCurrentHunk: Bool
    let canApply: Bool
    let onApply: (SyncDirection) -> Void
    let onFocus: () -> Void

    static func == (lhs: UnifiedRowView, rhs: UnifiedRowView) -> Bool {
        lhs.line == rhs.line
            && lhs.part == rhs.part
            && lhs.syntax == rhs.syntax
            && lhs.fontSize == rhs.fontSize
            && lhs.gutterWidth == rhs.gutterWidth
            && lhs.wrapLines == rhs.wrapLines
            && lhs.isHunkStart == rhs.isHunkStart
            && lhs.isCurrentHunk == rhs.isCurrentHunk
            && lhs.canApply == rhs.canApply
    }

    private var content: String {
        (part == .added ? line.rightContent : line.leftContent) ?? ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(part == .added ? nil : line.leftLineNumber)
            number(part == .removed ? nil : line.rightLineNumber)
            ZStack {
                if line.type != .unchanged {
                    Rectangle().fill(isCurrentHunk ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
                }
                if isHunkStart && canApply {
                    HStack(spacing: 3) {
                        HunkApplyButton(direction: .rightToLeft, isCurrent: isCurrentHunk) { onApply(.rightToLeft) }
                        HunkApplyButton(direction: .leftToRight, isCurrent: isCurrentHunk) { onApply(.leftToRight) }
                    }
                } else {
                    Text(marker)
                        .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                        .foregroundStyle(markerColor)
                }
            }
            .frame(width: 48)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { onFocus() }

            Text(DiffTextRenderer.attributed(
                content,
                highlights: part == .removed ? line.leftHighlights : (part == .added ? line.rightHighlights : []),
                highlightColor: part == .removed ? DiffPalette.deletedHighlight : DiffPalette.addedHighlight,
                syntax: syntax
            ))
            .font(.system(size: fontSize, design: .monospaced))
            .lineLimit(wrapLines ? nil : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: wrapLines)
            .textSelection(.enabled)
            .padding(.leading, 6)
            .padding(.trailing, 4)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(background)
        .overlay(alignment: .top) {
            if isHunkStart {
                Rectangle()
                    .fill(isCurrentHunk ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.18))
                    .frame(height: 1)
            }
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: max(fontSize - 1, 7), design: .monospaced))
            .foregroundStyle(part == .context ? AnyShapeStyle(.tertiary) : AnyShapeStyle(markerColor))
            .frame(width: gutterWidth, alignment: .trailing)
            .padding(.trailing, 4)
            .padding(.vertical, 1)
    }

    private var marker: String {
        switch part {
        case .context: " "
        case .removed: "−"
        case .added: "+"
        }
    }

    private var markerColor: Color {
        part == .removed ? DiffPalette.deleted : DiffPalette.added
    }

    private var background: Color {
        switch part {
        case .context: .clear
        case .removed: DiffPalette.deletedBackground
        case .added: DiffPalette.addedBackground
        }
    }

}

/// The ← / → button that copies one change block to the other side.
struct HunkApplyButton: View {
    let direction: SyncDirection
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .leftToRight ? "arrow.right" : "arrow.left")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovered || isCurrent ? Color.white : Color.accentColor)
                .frame(width: 18, height: 16)
                .background {
                    Capsule().fill(isHovered ? Color.accentColor : (isCurrent ? Color.accentColor.opacity(0.85) : Color.accentColor.opacity(0.14)))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(direction == .leftToRight
            ? String(localized: "Copy this change to the right file (⌥⌘→)")
            : String(localized: "Copy this change to the left file (⌥⌘←)"))
        .accessibilityLabel(direction == .leftToRight ? String(localized: "Copy change to right") : String(localized: "Copy change to left"))
    }
}

//
//  SidebarTreeView.swift
//  PathDiff
//

import AppKit
import SwiftUI

/// The sidebar: a Changes list (grouped by kind of difference) or the merged folder tree,
/// with change-kind filter chips on top and summary/progress at the bottom.
///
/// Tree rows come pre-flattened from the view model rather than from `OutlineGroup`, which
/// lets the app control expansion (auto-expanding changed folders and search results,
/// expand all, reveal the next changed file) and keeps very large trees fast.
struct SidebarTreeView: View {
    let viewModel: DiffViewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 0) {
            SidebarHeader(viewModel: viewModel)
            Divider()
            switch viewModel.sidebarMode {
            case .changes:
                ChangesListView(viewModel: viewModel)
            case .tree:
                TreeListView(viewModel: viewModel)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SummaryStatusBar(viewModel: viewModel)
        }
    }
}

/// Selection shared by both sidebar modes; the IDs are node paths.
@MainActor
private func selectionBinding(_ viewModel: DiffViewModel) -> Binding<Set<String>> {
    Binding(
        get: { viewModel.selectedIDs },
        set: { viewModel.select(ids: $0) }
    )
}

@MainActor
private func nodes(for ids: Set<String>, in viewModel: DiffViewModel) -> [DiffNode] {
    ids.sorted().compactMap { DiffTree.node(at: $0, in: viewModel.rootNodes) }
}

// MARK: - Header

private struct SidebarHeader: View {
    let viewModel: DiffViewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Picker("View", selection: $viewModel.sidebarMode) {
                    ForEach(SidebarMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                FileTypeFilterMenu(viewModel: viewModel)
            }

            HStack(spacing: 6) {
                ForEach(ChangeKind.allCases) { kind in
                    FilterChip(
                        kind: kind,
                        count: viewModel.count(of: kind),
                        isActive: viewModel.kindFilter.contains(kind),
                        isFiltering: viewModel.isKindFilterActive,
                        title: kind.shortTitle(left: viewModel.sideName(.left), right: viewModel.sideName(.right))
                    ) {
                        viewModel.toggleKindFilter(kind)
                    }
                }
            }
            .disabled(!viewModel.hasScanned)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

/// Narrows the sidebar to one type of file, such as videos or photos.
private struct FileTypeFilterMenu: View {
    let viewModel: DiffViewModel

    var body: some View {
        Menu {
            Picker("Show", selection: Binding(get: { viewModel.typeFilter }, set: { viewModel.typeFilter = $0 })) {
                Label("All Files", systemImage: "doc.on.doc").tag(FileCategory?.none)
                Divider()
                ForEach(FileCategory.allCases) { category in
                    Label(category.title, systemImage: category.symbolName).tag(Optional(category))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: viewModel.typeFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(viewModel.typeFilter == nil ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(viewModel.typeFilter.map { String(localized: "Showing only \($0.title)", comment: "The argument is a file type such as Videos") }
              ?? String(localized: "Show only one type of file"))
        .accessibilityLabel("File type filter")
        .accessibilityValue(viewModel.typeFilter?.title ?? String(localized: "All files"))
    }
}

/// A count for one kind of change that doubles as a filter toggle.
struct FilterChip: View {
    let kind: ChangeKind
    let count: Int
    let isActive: Bool
    let isFiltering: Bool
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    private var isSelected: Bool { isFiltering && isActive }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ChangeKindDot(kind: kind, size: 14)
                    .opacity(count > 0 && isActive ? 1 : 0.4)
                Text(DisplayFormat.count(count))
                    .font(.callout.monospacedDigit())
                    .fontWeight(count > 0 ? .semibold : .regular)
                    .foregroundStyle(isActive && count > 0 ? .primary : .tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? kind.color.opacity(0.16) : Color.primary.opacity(isHovered ? 0.08 : 0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? kind.color.opacity(0.55) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .help("\(count) \(title) — click to show only these, click others to add them")
        .accessibilityLabel(Text(verbatim: "\(title): \(DisplayFormat.count(count))"))
        .accessibilityAddTraits(isFiltering && isActive ? .isSelected : [])
    }
}

/// A kind of change as a small colored circle with its symbol.
struct ChangeKindDot: View {
    let kind: ChangeKind
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: kind.symbolName)
            .font(.system(size: size * 0.55, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(kind.color.gradient))
            .accessibilityHidden(true)
    }
}

// MARK: - Tree

private struct TreeListView: View {
    let viewModel: DiffViewModel

    var body: some View {
        ScrollViewReader { proxy in
            List(viewModel.sidebarRows, selection: selectionBinding(viewModel)) { row in
                SidebarRowView(row: row) { recursively in
                    viewModel.toggleExpansion(of: row.node, recursively: recursively)
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: String.self) { ids in
                NodeContextMenu(nodes: nodes(for: ids, in: viewModel), viewModel: viewModel)
            } primaryAction: { ids in
                guard ids.count == 1, let node = nodes(for: ids, in: viewModel).first else { return }
                if node.hasChildren {
                    viewModel.toggleExpansion(of: node)
                } else if let url = node.rightURL ?? node.leftURL {
                    FinderActions.open(url)
                }
            }
            .onKeyPress(.rightArrow) {
                viewModel.expandSelection() ? .handled : .ignored
            }
            .onKeyPress(.leftArrow) {
                viewModel.collapseSelectionOrSelectParent() ? .handled : .ignored
            }
            .onChange(of: viewModel.sidebarScrollRequest) { _, request in
                guard let request else { return }
                withAnimation { proxy.scrollTo(request.nodeID, anchor: .center) }
            }
            .overlay {
                if viewModel.sidebarRows.isEmpty {
                    SidebarEmptyState(viewModel: viewModel)
                }
            }
        }
    }
}

struct SidebarRowView: View, Equatable {
    let row: SidebarRow
    let onToggle: (_ recursively: Bool) -> Void

    static func == (lhs: SidebarRowView, rhs: SidebarRowView) -> Bool {
        lhs.row == rhs.row
    }

    private var node: DiffNode { row.node }

    var body: some View {
        HStack(spacing: 5) {
            disclosure
            icon
                .opacity(node.status == .ignored ? 0.5 : 1)
            Text(node.name)
                .foregroundStyle(nameStyle)
                .italic(node.status == .ignored)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if node.isDirectory, node.differenceCount > 0, row.move == nil {
                Text(DisplayFormat.count(node.differenceCount))
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .help("\(node.differenceCount) differing items inside")
            }
            if let move = row.move {
                MoveBadge(match: move)
            } else {
                StatusBadge(status: node.status)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .help(helpText)
    }

    private var helpText: String {
        guard let move = row.move else { return "\(node.relativePath) — \(node.status.label)" }
        let counterpart = node.status == .leftOnly ? move.rightPath : move.leftPath
        return node.status == .leftOnly
            ? String(localized: "\(node.relativePath) — moved to \(counterpart)")
            : String(localized: "\(node.relativePath) — moved from \(counterpart)")
    }

    @ViewBuilder
    private var disclosure: some View {
        if node.hasChildren {
            Button {
                onToggle(NSEvent.modifierFlags.contains(.option))
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.isExpanded ? String(localized: "Collapse \(node.name)") : String(localized: "Expand \(node.name)"))
        } else {
            Color.clear.frame(width: 12, height: 16)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if node.hasKindMismatch {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.modified)
                .frame(width: 16)
        } else if node.isSymlink {
            Image(systemName: "arrow.up.right.square")
                .foregroundStyle(.secondary)
                .frame(width: 16)
        } else {
            FileIconView(name: node.name, isDirectory: node.isDirectory)
        }
    }

    private var nameStyle: HierarchicalShapeStyle {
        switch node.status {
        case .identical: .secondary
        case .ignored: .tertiary
        default: .primary
        }
    }
}

// MARK: - Changes list

private struct ChangesListView: View {
    let viewModel: DiffViewModel
    @State private var collapsedSections: Set<ChangeKind> = []

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selectionBinding(viewModel)) {
                ForEach(viewModel.changeSections) { section in
                    Section(isExpanded: expansion(for: section.kind)) {
                        ForEach(section.rows) { row in
                            ChangeRowView(row: row)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            ChangeKindDot(kind: section.kind, size: 13)
                            Text(section.kind.title(left: viewModel.sideName(.left), right: viewModel.sideName(.right)))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(DisplayFormat.count(section.rows.count))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(section.kind.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(section.kind.color.opacity(0.13)))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: String.self) { ids in
                NodeContextMenu(nodes: nodes(for: ids, in: viewModel), viewModel: viewModel)
            } primaryAction: { ids in
                guard ids.count == 1, let node = nodes(for: ids, in: viewModel).first else { return }
                viewModel.revealInTree(node.id)
            }
            .onChange(of: viewModel.sidebarScrollRequest) { _, request in
                guard let request else { return }
                withAnimation { proxy.scrollTo(request.nodeID, anchor: .center) }
            }
            .overlay {
                if viewModel.changeSections.isEmpty {
                    SidebarEmptyState(viewModel: viewModel)
                }
            }
        }
    }

    private func expansion(for kind: ChangeKind) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(kind) },
            set: { isExpanded in
                if isExpanded { collapsedSections.remove(kind) } else { collapsedSections.insert(kind) }
            }
        )
    }
}

struct ChangeRowView: View {
    let row: ChangeRow

    private var node: DiffNode { row.node }

    var body: some View {
        HStack(spacing: 8) {
            FileIconView(name: node.name, isDirectory: node.isDirectory, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if node.isDirectory {
                        Text("\(row.fileCount) files")
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                            .fixedSize()
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if let move = row.move {
                if !move.isExact {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(move.isDirectory ? String(localized: "Some files changed or were not moved along") : String(localized: "Moved and edited"))
                }
                MoveBadge(match: move)
            } else {
                StatusBadge(status: node.status)
            }
        }
        .padding(.vertical, 1)
        .help(helpText)
    }

    private var subtitle: String {
        if let move = row.move {
            return "→ " + move.rightPath
        }
        let parent = DiffTree.parentPath(of: node.relativePath)
        return parent.isEmpty ? "/" : parent
    }

    private var helpText: String {
        guard let move = row.move else { return node.relativePath }
        var text = "\(move.leftPath) → \(move.rightPath)"
        if move.isDirectory { text += " " + String(localized: "(\(move.matchedFiles) of \(move.totalFiles) files moved along)") }
        return text
    }
}

private struct SidebarEmptyState: View {
    let viewModel: DiffViewModel

    var body: some View {
        if viewModel.hasScanned && !viewModel.isScanning {
            if !viewModel.searchQuery.isEmpty {
                ContentUnavailableView.search(text: viewModel.searchText)
            } else if viewModel.isKindFilterActive || viewModel.typeFilter != nil {
                ContentUnavailableView {
                    Label("Nothing to Show", systemImage: "line.3.horizontal.decrease")
                } description: {
                    Text(viewModel.typeFilter.map { String(localized: "No \($0.title) match the selected filters.", comment: "The argument is a file type such as videos") }
                         ?? String(localized: "No items match the selected filters."))
                } actions: {
                    Button("Show All") { viewModel.resetFilters() }
                }
            } else if viewModel.summary.differences == 0 && !viewModel.rootNodes.isEmpty {
                ContentUnavailableView(
                    "No Differences",
                    systemImage: "checkmark.circle",
                    description: Text("Both folders have the same contents.")
                )
            } else if viewModel.rootNodes.isEmpty {
                ContentUnavailableView("Empty Folders", systemImage: "folder")
            }
        } else if !viewModel.hasBothFolders {
            ContentUnavailableView {
                Label("No Comparison", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Choose two folders to see their differences here.")
            }
        }
    }
}

// MARK: - Context menu

/// Actions for one or more selected items.
struct NodeContextMenu: View {
    let nodes: [DiffNode]
    let viewModel: DiffViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if nodes.count == 1, let node = nodes.first {
            singleNodeMenu(node)
        } else if !nodes.isEmpty {
            multipleNodesMenu
        }
    }

    @ViewBuilder
    private func singleNodeMenu(_ node: DiffNode) -> some View {
        let left = viewModel.sideName(.left)
        let right = viewModel.sideName(.right)

        if let move = viewModel.moves.match(for: node) {
            Button("Move in “\(right)” to Match “\(left)”") { viewModel.applyMove(move, on: .right) }
            Button("Move in “\(left)” to Match “\(right)”") { viewModel.applyMove(move, on: .left) }
            Button("Show Counterpart") {
                let counterpart = node.status == .leftOnly ? move.rightPath : move.leftPath
                viewModel.revealInTree(counterpart)
            }
            Divider()
        }

        Button("Copy to “\(right)”") { viewModel.copy(node, direction: .leftToRight) }
            .disabled(!viewModel.canCopy(node, direction: .leftToRight))
        Button("Copy to “\(left)”") { viewModel.copy(node, direction: .rightToLeft) }
            .disabled(!viewModel.canCopy(node, direction: .rightToLeft))
        Button("Sync…") { viewModel.beginBatchSync(ids: [node.id]) }

        if node.isDirectory {
            Button("Compare in New Window") {
                if let request = viewModel.comparisonRequest(for: node) { openWindow(value: request) }
            }
            .disabled(!(node.existsOnLeft && node.existsOnRight) && viewModel.moves.match(for: node)?.isDirectory != true)
        }

        Divider()

        if viewModel.sidebarMode == .changes {
            Button("Show in Tree") { viewModel.revealInTree(node.id) }
        }
        if let url = node.leftURL {
            Button("Reveal in “\(left)”") { FinderActions.reveal(url) }
        }
        if let url = node.rightURL {
            Button("Reveal in “\(right)”") { FinderActions.reveal(url) }
        }
        if !node.isDirectory {
            if let url = node.leftURL {
                Button("Open “\(left)” Version") { FinderActions.open(url) }
            }
            if let url = node.rightURL {
                Button("Open “\(right)” Version") { FinderActions.open(url) }
            }
        }
        Button("Copy Relative Path") { FinderActions.copyToPasteboard(node.relativePath) }

        if node.isDirectory && node.hasChildren && viewModel.sidebarMode == .tree {
            Divider()
            Button("Expand All Inside") { viewModel.setExpanded(true, node: node, recursively: true) }
            Button("Collapse All Inside") { viewModel.setExpanded(false, node: node, recursively: true) }
        }

        Divider()

        Button("Ignore Items Named “\(node.name)”") { viewModel.addIgnorePattern(for: node) }
            .disabled(node.status == .ignored)
        if node.isDirectory {
            Button("Ignore This Folder Path") { viewModel.addIgnorePattern("/" + node.relativePath + "/") }
                .disabled(node.status == .ignored)
        }

        Divider()

        if node.existsOnLeft {
            Button("Move “\(left)” Item to Trash…", role: .destructive) { viewModel.moveToTrash(node, side: .left) }
        }
        if node.existsOnRight {
            Button("Move “\(right)” Item to Trash…", role: .destructive) { viewModel.moveToTrash(node, side: .right) }
        }
    }

    @ViewBuilder
    private var multipleNodesMenu: some View {
        let left = viewModel.sideName(.left)
        let right = viewModel.sideName(.right)
        Button("Copy \(nodes.count) Items to “\(right)”") { viewModel.copy(nodes, direction: .leftToRight) }
            .disabled(!viewModel.canCopy(nodes, direction: .leftToRight))
        Button("Copy \(nodes.count) Items to “\(left)”") { viewModel.copy(nodes, direction: .rightToLeft) }
            .disabled(!viewModel.canCopy(nodes, direction: .rightToLeft))
        Button("Sync \(nodes.count) Items…") { viewModel.beginBatchSync(ids: Set(nodes.map(\.id))) }
        Divider()
        Button("Copy Relative Paths") {
            FinderActions.copyToPasteboard(nodes.map(\.relativePath).joined(separator: "\n"))
        }
        Divider()
        let leftItems = nodes.filter(\.existsOnLeft)
        let rightItems = nodes.filter(\.existsOnRight)
        if !leftItems.isEmpty {
            Button("Move \(leftItems.count) “\(left)” Items to Trash…", role: .destructive) { viewModel.moveToTrash(leftItems, side: .left) }
        }
        if !rightItems.isEmpty {
            Button("Move \(rightItems.count) “\(right)” Items to Trash…", role: .destructive) { viewModel.moveToTrash(rightItems, side: .right) }
        }
    }
}

// MARK: - Status bar

/// Lists folders and files that couldn't be read, so missing results aren't silent.
private struct ScanIssuesButton: View {
    let viewModel: DiffViewModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label {
                Text(DisplayFormat.count(viewModel.scanIssues.count))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .help("Some items couldn’t be read")
        .accessibilityLabel("\(viewModel.scanIssues.count) items couldn’t be read")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn’t Read \(viewModel.scanIssues.count) Items")
                    .font(.headline)
                Text("These items are missing from the comparison or shown as modified. Check their permissions, then refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                List(viewModel.scanIssues.prefix(200)) { issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.path.isEmpty ? "/" : issue.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: "\(issue.side.map { viewModel.sideName($0) } ?? String(localized: "Both sides")) — \(issue.message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(minHeight: 160)
            }
            .padding(14)
            .frame(width: 440, height: 340)
        }
    }
}

/// Scan progress, or what wasn't listed above (identical and ignored items).
struct SummaryStatusBar: View {
    let viewModel: DiffViewModel

    var body: some View {
        HStack(spacing: 8) {
            if viewModel.isScanning {
                ProgressView().controlSize(.small)
                Text(progressText)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Stop") { viewModel.cancelScan() }
                    .controlSize(.small)
            } else if viewModel.hasScanned {
                let summary = viewModel.summary
                VStack(alignment: .leading, spacing: 6) {
                    DistributionBar(segments: Self.segments(summary), height: 4)
                    Text([String(localized: "\(summary.identical) identical"), String(localized: "\(summary.ignored) ignored")].joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help(detailsHelp)
                Spacer(minLength: 0)
                if !viewModel.scanIssues.isEmpty {
                    ScanIssuesButton(viewModel: viewModel)
                }
                if viewModel.isDetectingMoves {
                    ProgressView().controlSize(.mini)
                    Text("Finding moves…").foregroundStyle(.tertiary)
                } else if viewModel.isPerformingFileOperation {
                    ProgressView().controlSize(.mini)
                }
            } else {
                Text("No comparison").foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    static func segments(_ summary: DiffSummary) -> [DistributionBar.Segment] {
        [
            .init(id: "modified", value: summary.modified, color: ChangeKind.modified.color),
            .init(id: "moved", value: summary.moved, color: ChangeKind.moved.color),
            .init(id: "left", value: summary.leftOnly, color: ChangeKind.leftOnly.color),
            .init(id: "right", value: summary.rightOnly, color: ChangeKind.rightOnly.color),
            .init(id: "identical", value: summary.identical, color: Palette.neutral.opacity(0.35)),
        ]
    }

    private var detailsHelp: String {
        var parts: [String] = []
        if let duration = viewModel.lastScanDuration {
            parts.append(String(localized: "Scanned in \(duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))"))
        }
        let resolved = viewModel.scanProgress.filesResolvedByGitIndex
        if resolved > 0 {
            parts.append(String(localized: "\(resolved) files verified from the git index without reading them"))
        }
        return parts.joined(separator: "\n")
    }

    private var progressText: String {
        let progress = viewModel.scanProgress
        switch progress.phase {
        case .comparing where progress.filesToCompare > 0:
            return String(localized: "Comparing \(DisplayFormat.count(progress.filesCompared)) of \(DisplayFormat.count(progress.filesToCompare))…")
        default:
            return String(localized: "Scanning… \(progress.itemsDiscovered) items")
        }
    }
}

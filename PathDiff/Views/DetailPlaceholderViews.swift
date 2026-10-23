//
//  DetailPlaceholderViews.swift
//  PathDiff
//

import AppKit
import SwiftUI

/// Shown when a folder is selected: what differs inside it, plus folder-level sync.
struct DirectorySummaryView: View {
    let viewModel: DiffViewModel
    let node: DiffNode
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let summary = viewModel.summary(inside: node)
        let left = viewModel.sideName(.left)
        let right = viewModel.sideName(.right)
        let move = viewModel.moves.match(for: node)
        VStack(spacing: 0) {
            if let move {
                MoveBanner(viewModel: viewModel, node: node, match: move)
                Divider()
            }
            CenteredScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 16) {
                        BadgedFileIcon(node: node, move: move, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.name)
                                .font(.title2.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(DiffTree.parentPath(of: node.relativePath).isEmpty
                                 ? String(localized: "Top level")
                                 : String(localized: "in \(DiffTree.parentPath(of: node.relativePath))", comment: "Location of a folder; the argument is its parent path"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            TagLabel(text: statusText(left: left, right: right, move: move), color: statusColor(move: move))
                        }
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        DistributionBar(segments: SummaryStatusBar.segments(summary), height: 6)
                        HStack(spacing: 10) {
                            ForEach(ChangeKind.allCases) { kind in
                                StatTile(title: kind.tileTitle(), subtitle: kind.tileSubtitle(right: right), value: summary.count(of: kind), bytes: summary.bytes(of: kind), color: kind.color, systemName: kind.symbolName)
                            }
                        }
                        Text(identicalAndIgnored(summary))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            viewModel.copy(node, direction: .rightToLeft)
                        } label: {
                            Label("Copy Changes to \(left)…", systemImage: "arrow.left")
                        }
                        .disabled(!viewModel.canCopy(node, direction: .rightToLeft))

                        Button {
                            viewModel.copy(node, direction: .leftToRight)
                        } label: {
                            Label("Copy Changes to \(right)…", systemImage: "arrow.right")
                        }
                        .disabled(!viewModel.canCopy(node, direction: .leftToRight))

                        Spacer(minLength: 0)

                        Button {
                            viewModel.beginBatchSync(ids: [node.id])
                        } label: {
                            Label("Sync…", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(node.status == .identical)
                    }
                    .controlSize(.large)

                    HStack(spacing: 16) {
                        if node.existsOnLeft && node.existsOnRight && !node.hasKindMismatch {
                            Button("Compare in New Window") {
                                if let request = viewModel.comparisonRequest(for: node) { openWindow(value: request) }
                            }
                        }
                        if viewModel.sidebarMode == .changes {
                            Button("Show in Tree") { viewModel.revealInTree(node.id) }
                        }
                        if let url = node.leftURL {
                            Button("Reveal in \(left)") { FinderActions.reveal(url) }
                        }
                        if let url = node.rightURL {
                            Button("Reveal in \(right)") { FinderActions.reveal(url) }
                        }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
                .frame(maxWidth: 680)
                .padding(36)
            }
        }
    }

    private func identicalAndIgnored(_ summary: DiffSummary) -> String {
        var parts = [String(localized: "\(summary.identical) identical")]
        if summary.ignored > 0 { parts.append(String(localized: "\(summary.ignored) ignored")) }
        return parts.joined(separator: " · ")
    }

    private func statusColor(move: MoveMatch?) -> Color {
        if move != nil { return ChangeKind.moved.color }
        return node.status == .identical ? .secondary : node.status.color
    }

    private func statusText(left: String, right: String, move: MoveMatch?) -> String {
        if let move {
            return node.status == .leftOnly
                ? String(localized: "Moved to \(move.rightPath) in \(right)")
                : String(localized: "Moved from \(move.leftPath) in \(left)")
        }
        return switch node.status {
        case .leftOnly: String(localized: "Missing from \(right)")
        case .rightOnly: String(localized: "Extra in \(right)")
        case .modified: String(localized: "Contains differences")
        default: node.status.label
        }
    }
}

/// Shown when several sidebar items are selected: batch sync and trash.
struct MultipleSelectionView: View {
    let viewModel: DiffViewModel

    var body: some View {
        let nodes = viewModel.selectedNodes
        let left = viewModel.sideName(.left)
        let right = viewModel.sideName(.right)
        let kinds = Dictionary(grouping: nodes) { viewModel.changeKind(of: $0) }
        CenteredScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    IconTile(systemName: "square.stack.3d.up.fill", color: .accentColor, size: 56)
                    Text("\(nodes.count) Items Selected").font(.title2.weight(.semibold))
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    ForEach(ChangeKind.allCases) { kind in
                        if let count = kinds[kind]?.count {
                            StatTile(title: kind.tileTitle(), subtitle: kind.tileSubtitle(right: right), value: count, color: kind.color, systemName: kind.symbolName)
                        }
                    }
                    if let unchanged = kinds[ChangeKind?.none]?.count {
                        StatTile(title: String(localized: "Other", comment: "Summary tile for selected items that are not changes"), value: unchanged, color: Palette.neutral, systemName: "equal")
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        viewModel.copy(nodes, direction: .rightToLeft)
                    } label: {
                        Label("Copy to \(left)…", systemImage: "arrow.left")
                    }
                    .disabled(!viewModel.canCopy(nodes, direction: .rightToLeft))

                    Button {
                        viewModel.copy(nodes, direction: .leftToRight)
                    } label: {
                        Label("Copy to \(right)…", systemImage: "arrow.right")
                    }
                    .disabled(!viewModel.canCopy(nodes, direction: .leftToRight))

                    Button {
                        viewModel.beginBatchSync()
                    } label: {
                        Label("Sync Selected Items…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)

                Text("Copy only copies differing items and never deletes anything. Sync shows a dry run first and can also apply moves or mirror the folders. Undo with ⌘Z.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .frame(maxWidth: 640)
            .padding(36)
        }
    }
}

/// "Binary files differ" with sizes and dates.
struct BinaryDiffView: View {
    let viewModel: DiffViewModel
    let node: DiffNode
    let comparison: BinaryComparison

    var body: some View {
        CenteredScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    BadgedFileIcon(node: node, move: viewModel.moves.match(for: node), size: 64)
                    Text(node.name).font(.title2.weight(.semibold))
                    TagLabel(
                        text: title,
                        color: comparison.areIdentical ? Palette.extra : node.status.color,
                        systemImage: comparison.areIdentical ? "checkmark" : "doc.badge.ellipsis"
                    )
                }

                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                    GridRow {
                        Text(verbatim: "")
                        Text(viewModel.sideName(.left)).font(.headline)
                        Text(viewModel.sideName(.right)).font(.headline)
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        Text(comparison.leftSize.map(DisplayFormat.byteCount) ?? String(localized: "size.missing", defaultValue: "Missing", comment: "Shown instead of a size when the file doesn't exist on that side"))
                        Text(comparison.rightSize.map(DisplayFormat.byteCount) ?? String(localized: "size.missing", defaultValue: "Missing", comment: "Shown instead of a size when the file doesn't exist on that side"))
                    }
                    GridRow {
                        Text(String(localized: "date.modified", defaultValue: "Modified", comment: "Label for a file's modification date")).foregroundStyle(.secondary)
                        modified(comparedNode.leftMetadata, other: comparedNode.rightMetadata)
                        modified(comparedNode.rightMetadata, other: comparedNode.leftMetadata)
                    }
                }
                .monospacedDigit()
                .padding(18)
                .cardBackground()

                if comparison.leftSize != nil || comparison.rightSize != nil {
                    ChecksumSection(viewModel: viewModel, node: comparedNode)
                }

                FileSyncButtons(viewModel: viewModel, node: node)
            }
            .padding(36)
        }
    }

    /// The pair actually compared (a moved file is compared with its counterpart).
    private var comparedNode: DiffNode { viewModel.activeDiffNode ?? node }

    private func modified(_ metadata: ItemMetadata?, other: ItemMetadata?) -> some View {
        HStack(spacing: 6) {
            Text(DisplayFormat.date(metadata?.modificationDate))
            if let date = metadata?.modificationDate, let otherDate = other?.modificationDate,
               date.timeIntervalSince(otherDate) > ComparisonMethod.modificationDateTolerance {
                TagLabel(text: String(localized: "Newer", comment: "Tag next to the more recent modification date"), color: Palette.extra)
            }
        }
    }

    private var title: String {
        if comparison.leftSize == nil { return String(localized: "Binary file only in \(viewModel.sideName(.right))") }
        if comparison.rightSize == nil { return String(localized: "Binary file only in \(viewModel.sideName(.left))") }
        return comparison.areIdentical ? String(localized: "Binary files are identical") : String(localized: "Binary files differ")
    }
}

/// File-level "copy to left / copy to right" buttons for non-text detail views.
struct FileSyncButtons: View {
    let viewModel: DiffViewModel
    let node: DiffNode

    var body: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.copy(node, direction: .rightToLeft)
            } label: {
                Label("Copy to \(viewModel.sideName(.left))", systemImage: "arrow.left")
            }
            .disabled(!viewModel.canCopy(node, direction: .rightToLeft))

            Button {
                viewModel.copy(node, direction: .leftToRight)
            } label: {
                Label("Copy to \(viewModel.sideName(.right))", systemImage: "arrow.right")
            }
            .disabled(!viewModel.canCopy(node, direction: .leftToRight))
        }
        .controlSize(.large)
    }
}

/// Generic message for selections that can't be diffed as text.
struct DetailMessageView: View {
    let viewModel: DiffViewModel
    let node: DiffNode
    let title: String
    let systemImage: String
    let message: String
    var showsSyncButtons = true

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if showsSyncButtons {
                FileSyncButtons(viewModel: viewModel, node: node)
            }
        }
    }
}

/// Avoids flashing a spinner for diffs that load instantly.
struct DelayedProgressView: View {
    @State private var isVisible = false

    var body: some View {
        ProgressView()
            .opacity(isVisible ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                isVisible = true
            }
    }
}

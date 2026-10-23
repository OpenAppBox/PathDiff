//
//  ToolbarView.swift
//  PathDiff
//

import AppKit
import SwiftUI

/// The folder bar above the diff: left folder, swap, right folder.
struct ToolbarView: View {
    let viewModel: DiffViewModel

    var body: some View {
        HStack(spacing: 8) {
            FolderPathControl(side: .left, url: viewModel.leftFolderURL) {
                Task { await viewModel.chooseFolder(for: .left) }
            } onDrop: { url in
                viewModel.setFolder(url, for: .left)
            }

            SwapFoldersButton(viewModel: viewModel)

            FolderPathControl(side: .right, url: viewModel.rightFolderURL) {
                Task { await viewModel.chooseFolder(for: .right) }
            } onDrop: { url in
                viewModel.setFolder(url, for: .right)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .comparisonLayout()
    }
}

private struct SwapFoldersButton: View {
    let viewModel: DiffViewModel
    @State private var isHovered = false
    @State private var turns = 0.0

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.35)) { turns += 1 }
            viewModel.swapFolders()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovered ? Color.accentColor : .secondary)
                .rotation3DEffect(.degrees(turns * 180), axis: (x: 0, y: 1, z: 0))
                .frame(width: 30, height: 30)
                .background(Circle().fill(isHovered ? Color.accentColor.opacity(0.12) : Palette.cardFill))
                .overlay(Circle().strokeBorder(Palette.cardStroke))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled((viewModel.leftFolderURL == nil && viewModel.rightFolderURL == nil) || !viewModel.canChangeFolders)
        .help("Swap Left and Right Folders (⌥⌘S)")
        .accessibilityLabel("Swap Left and Right Folders")
    }
}

/// Shows a chosen folder; click to choose another, or drop a folder from Finder onto it.
struct FolderPathControl: View {
    let side: Side
    let url: URL?
    let onChoose: () -> Void
    let onDrop: (URL) -> Void

    @State private var isDropTargeted = false
    @State private var isHovered = false

    var body: some View {
        Button(action: onChoose) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(url?.lastPathComponent ?? (side == .left ? String(localized: "Choose Left Folder…") : String(localized: "Choose Right Folder…")))
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(url == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Text(url.map { DisplayFormat.abbreviatedPath($0) } ?? String(localized: "Click or drop a folder here"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text(side == .left ? String(localized: "LEFT", comment: "Small capsule label on the left folder") : String(localized: "RIGHT", comment: "Small capsule label on the right folder"))
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .help(side == .left ? String(localized: "The reference side") : String(localized: "Compared against the left folder"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.16) : (isHovered ? Color.primary.opacity(0.07) : Palette.cardFill))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Palette.cardStroke, lineWidth: isDropTargeted ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(url.map { $0.path(percentEncoded: false) } ?? (side == .left ? String(localized: "Choose the left folder") : String(localized: "Choose the right folder")))
        .folderDropDestination(isTargeted: $isDropTargeted, onDrop: onDrop)
        .contextMenu {
            Button("Choose Folder…", action: onChoose)
            if let url {
                Button("Reveal in Finder") { FinderActions.reveal(url) }
                Button("Copy Path") { FinderActions.copyToPasteboard(url.path(percentEncoded: false)) }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable()
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: "folder.badge.plus")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }
}

extension View {
    /// Accepts a folder dropped from Finder.
    func folderDropDestination(isTargeted: Binding<Bool>, onDrop: @escaping (URL) -> Void) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: \.hasDirectoryPath) ?? urls.first(where: FolderDrop.isDirectory) else {
                return false
            }
            onDrop(folder)
            return true
        } isTargeted: { isTargeted.wrappedValue = $0 }
    }
}

private enum FolderDrop {
    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

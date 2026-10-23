//
//  MainView.swift
//  PathDiff
//

import AppKit
import SwiftUI

/// One comparison window: folder tree on the left, folder bar and diff on the right.
struct MainView: View {
    /// Folders to open when the window was created by "Compare in New Window".
    let request: ComparisonRequest?

    @State private var viewModel: DiffViewModel

    /// - Parameter viewModel: an existing comparison to show (previews and tests);
    ///   a new one is created otherwise.
    init(request: ComparisonRequest?, viewModel: DiffViewModel? = nil) {
        self.request = request
        _viewModel = State(initialValue: viewModel ?? DiffViewModel())
    }
    @Environment(AppSettings.self) private var settings
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationSplitView {
            SidebarTreeView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 600)
        } detail: {
            VStack(spacing: 0) {
                if viewModel.hasBothFolders {
                    ToolbarView(viewModel: viewModel)
                    Divider()
                }
                if let suggestion = viewModel.innerFolderSuggestion {
                    InnerFolderBanner(viewModel: viewModel, left: suggestion.left.name, right: suggestion.right.name)
                    Divider()
                }
                DetailView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $viewModel.searchText, placement: .sidebar, prompt: "Filter by name or path")
        .toolbar { MainToolbar(viewModel: viewModel) }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .focusedSceneValue(\.diffViewModel, viewModel)
        // Closing the window would silently drop unsaved edits; save or discard them first
        // (Done in the editor). Quitting asks instead.
        .windowDismissBehavior(viewModel.editSession?.isDirty == true ? .disabled : .automatic)
        .alert(
            viewModel.alert?.title ?? "",
            isPresented: Binding(
                get: { viewModel.alert != nil },
                set: { if !$0 { viewModel.alert = nil } }
            ),
            presenting: viewModel.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .confirmationDialog(
            viewModel.pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { viewModel.pendingConfirmation != nil },
                set: { if !$0 { viewModel.pendingConfirmation = nil } }
            ),
            presenting: viewModel.pendingConfirmation
        ) { confirmation in
            Button(confirmation.confirmTitle, role: confirmation.isDestructive ? .destructive : nil) {
                confirmation.action()
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .sheet(isPresented: Binding(
            get: { viewModel.batchSync != nil },
            set: { if !$0 { viewModel.cancelBatchSync() } }
        )) {
            BatchSyncSheet(viewModel: viewModel)
                .interactiveDismissDisabled(viewModel.batchSync?.isRunning == true)
        }
        .confirmationDialog(
            "Save changes to “\(viewModel.editGuard?.name ?? "")”?",
            isPresented: Binding(
                get: { viewModel.editGuard != nil },
                set: { if !$0 { viewModel.editGuard = nil } }
            ),
            presenting: viewModel.editGuard
        ) { guardRequest in
            Button("Save") { guardRequest.onSave() }
            Button("Don’t Save", role: .destructive) { guardRequest.onDiscard() }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your edits will be lost if you don’t save them.")
        }
        .onAppear {
            viewModel.undoManager = undoManager
            if let request {
                viewModel.open(request)
            } else {
                viewModel.restoreLastSessionIfNeeded()
            }
        }
        .onChange(of: undoManager) { _, newValue in
            viewModel.undoManager = newValue
        }
        .task(id: settings.scanConfiguration) {
            // Debounced so typing in the ignore-pattern editor doesn't rescan on every keystroke.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            viewModel.scanConfigurationDidChange()
        }
        .onChange(of: settings.collapseUnchanged) { viewModel.rebuildDisplayItems() }
        .onChange(of: settings.contextLines) { viewModel.rebuildDisplayItems() }
        .onChange(of: settings.watchForChanges) { viewModel.watchSettingDidChange() }
        .onChange(of: settings.detectsMoves) { viewModel.moveDetectionSettingDidChange() }
        .onChange(of: settings.diffLayout) {
            viewModel.rebuildDisplayItems()
            if let hunk = viewModel.currentHunkIndex { viewModel.focusHunk(hunk) }
        }
        .onChange(of: settings.highlightsSyntax) { viewModel.reloadActiveDiff() }
    }

    private var windowTitle: String {
        switch (viewModel.leftFolderURL, viewModel.rightFolderURL) {
        case let (left?, right?): "\(left.lastPathComponent) ↔ \(right.lastPathComponent)"
        default: "PathDiff"
        }
    }

    private var windowSubtitle: String {
        guard viewModel.hasScanned else { return "" }
        let summary = viewModel.summary
        guard summary.differences > 0 else { return String(localized: "No differences") }
        var parts = [String(localized: "\(summary.modified) modified")]
        if summary.moved > 0 { parts.append(String(localized: "\(summary.moved) moved")) }
        parts.append(String(localized: "\(summary.leftOnly) only in \(viewModel.sideName(.left))"))
        parts.append(String(localized: "\(summary.rightOnly) only in \(viewModel.sideName(.right))"))
        return parts.joined(separator: " · ")
    }
}

/// Offered when both folders only wrap one folder each, as extracted downloads often do.
private struct InnerFolderBanner: View {
    let viewModel: DiffViewModel
    let left: String
    let right: String

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: "folder.badge.questionmark", color: .accentColor, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Both folders wrap a single folder")
                    .font(.callout.weight(.semibold))
                Text("Compare “\(left)” with “\(right)” instead?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Compare Inner Folders") { viewModel.compareInnerFolders() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.07))
    }
}

private struct MainToolbar: ToolbarContent {
    let viewModel: DiffViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some ToolbarContent {
        @Bindable var viewModel = viewModel
        ToolbarItemGroup(placement: .primaryAction) {
            if viewModel.isScanning {
                Button {
                    viewModel.cancelScan()
                } label: {
                    Label("Stop", systemImage: "xmark")
                }
                .help("Stop Scanning")
            } else {
                Button {
                    viewModel.rescan()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!viewModel.hasBothFolders)
                .help("Rescan Both Folders (⌘R)")
            }

            Button {
                viewModel.beginBatchSync()
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!viewModel.hasScanned || viewModel.isPerformingFileOperation)
            .help("Sync the selection or everything, with a dry run first (⇧⌘Y)")

            Button {
                openWindow(id: HistoryView.windowID)
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .help("Sync History — see and revert past changes (⇧⌘H)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $viewModel.showOnlyDifferences) {
                Label("Only Differences", systemImage: "line.3.horizontal.decrease")
            }
            .help("Show Only Differences (⇧⌘D)")

            Toggle(isOn: $viewModel.showIgnored) {
                Label("Show Ignored", systemImage: "eye.slash")
            }
            .help("Show Ignored Items (⇧⌘I)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                viewModel.selectAdjacentChangedFile(forward: false)
            } label: {
                Label("Previous Changed File", systemImage: "chevron.up")
            }
            .disabled(!viewModel.hasScanned)
            .help("Previous Changed File (⌃⌘↑)")

            Button {
                viewModel.selectAdjacentChangedFile(forward: true)
            } label: {
                Label("Next Changed File", systemImage: "chevron.down")
            }
            .disabled(!viewModel.hasScanned)
            .help("Next Changed File (⌃⌘↓)")
        }
    }
}

/// Chooses what the detail area shows for the current state and selection.
private struct DetailView: View {
    let viewModel: DiffViewModel

    var body: some View {
        if !viewModel.hasBothFolders {
            WelcomeView(viewModel: viewModel)
        } else if viewModel.isScanning && !viewModel.hasScanned {
            ScanningView(progress: viewModel.scanProgress)
        } else if !viewModel.hasScanned {
            // The first scan was stopped or failed: there are no results, which must not
            // read as "the folders match".
            ContentUnavailableView {
                Label("Comparison Not Finished", systemImage: "exclamationmark.magnifyingglass")
            } description: {
                Text("The scan was stopped or couldn’t finish, so the folders haven’t been compared.")
            } actions: {
                Button("Refresh") { viewModel.rescan() }
            }
        } else if viewModel.selectedIDs.count > 1 {
            MultipleSelectionView(viewModel: viewModel)
        } else if let node = viewModel.selectedNode {
            content(for: node)
                .id(node.id)
        } else {
            noSelection
        }
    }

    @ViewBuilder
    private func content(for node: DiffNode) -> some View {
        switch viewModel.activeDiff {
        case .none:
            Color.clear
        case .loading:
            DelayedProgressView()
        case .directory:
            DirectorySummaryView(viewModel: viewModel, node: node)
        case .text(let diff):
            Group {
                if let session = viewModel.editSession, session.nodeID == node.id {
                    DiffEditorView(viewModel: viewModel, session: session)
                } else if DiffEngine.isImage(node.relativePath) && viewModel.showsImageComparison {
                    ImageDiffView(viewModel: viewModel, node: node, comparedNode: viewModel.activeDiffNode ?? node, canShowText: true)
                } else {
                    SideBySideDiffView(viewModel: viewModel, node: node, diff: diff)
                }
            }
            .comparisonLayout()
        case .binary(let comparison):
            Group {
                if comparison.isImage {
                    ImageDiffView(viewModel: viewModel, node: node, comparedNode: viewModel.activeDiffNode ?? node, canShowText: false)
                } else {
                    BinaryDiffView(viewModel: viewModel, node: node, comparison: comparison)
                }
            }
            .comparisonLayout()
        case .media(let comparison):
            MediaDiffView(viewModel: viewModel, node: node, comparedNode: viewModel.activeDiffNode ?? node, comparison: comparison)
                .comparisonLayout()
        case .ignored:
            DetailMessageView(
                viewModel: viewModel,
                node: node,
                title: String(localized: "Ignored"),
                systemImage: "eye.slash",
                message: String(localized: "“\(node.name)” matches an ignore pattern and isn’t compared. You can change the patterns in Settings."),
                showsSyncButtons: false
            )
        case .typeMismatch:
            DetailMessageView(
                viewModel: viewModel,
                node: node,
                title: String(localized: "Different Item Types"),
                systemImage: "exclamationmark.triangle",
                message: String(
                    localized: "“\(node.name)” is \(kindName(node.leftMetadata)) on the left and \(kindName(node.rightMetadata)) on the right.",
                    comment: "The second and third arguments are item kinds such as “a folder” or “a file”"
                ),
                showsSyncButtons: false
            )
        case .symlink(let left, let right):
            DetailMessageView(
                viewModel: viewModel,
                node: node,
                title: left == right ? String(localized: "Identical Symbolic Links") : String(localized: "Symbolic Links Differ"),
                systemImage: "arrow.up.right.square",
                message: String(localized: "Left → \(left ?? missing)\nRight → \(right ?? missing)", comment: "Symbolic link targets on each side")
            )
        case .tooLarge(let leftSize, let rightSize):
            DetailMessageView(
                viewModel: viewModel,
                node: node,
                title: String(localized: "File Too Large to Display"),
                systemImage: "doc.text.magnifyingglass",
                message: String(localized: "Left: \(leftSize.map(DisplayFormat.byteCount) ?? missing) · Right: \(rightSize.map(DisplayFormat.byteCount) ?? missing). Files over \(DisplayFormat.byteCount(DiffEngine.maximumTextFileSize)) are compared but not shown line by line.")
            )
        case .failed(let message):
            DetailMessageView(
                viewModel: viewModel,
                node: node,
                title: String(localized: "Couldn’t Read File"),
                systemImage: "exclamationmark.octagon",
                message: message,
                showsSyncButtons: false
            )
        }
    }

    /// An item kind with its article, used inside a sentence.
    private func kindName(_ metadata: ItemMetadata?) -> String {
        switch metadata?.kind {
        case .directory: String(localized: "a folder", comment: "Item kind inside “<name> is a folder on the left and a file on the right.”")
        case .symlink: String(localized: "a symbolic link", comment: "Item kind inside “<name> is a folder on the left and a file on the right.”")
        case .file: String(localized: "a file", comment: "Item kind inside “<name> is a folder on the left and a file on the right.”")
        case nil: String(localized: "a missing item", comment: "Item kind inside “<name> is a folder on the left and a file on the right.”")
        }
    }

    /// Stands in for a size or link target that doesn't exist on one side.
    private var missing: String {
        String(localized: "missing", comment: "Shown instead of a size or symbolic link target that doesn't exist on that side")
    }

    private var noSelection: some View {
        ComparisonOverviewView(viewModel: viewModel)
    }
}

private struct ScanningView: View {
    let progress: ScanProgress

    var body: some View {
        VStack(spacing: 18) {
            IconTile(systemName: isComparing ? "doc.on.doc" : "magnifyingglass", color: .accentColor, size: 56)
            VStack(spacing: 4) {
                Text(isComparing ? String(localized: "Comparing Files") : String(localized: "Scanning Folders"))
                    .font(.title3.weight(.semibold))
                Text(detail)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Group {
                if isComparing {
                    ProgressView(value: Double(progress.filesCompared), total: Double(progress.filesToCompare))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .frame(width: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isComparing: Bool {
        progress.phase == .comparing && progress.filesToCompare > 0
    }

    private var detail: String {
        if isComparing {
            return String(localized: "\(progress.filesCompared) of \(progress.filesToCompare) files")
        }
        return String(localized: "\(progress.itemsDiscovered) items found")
    }
}

/// What the comparison found, shown when nothing is selected.
private struct ComparisonOverviewView: View {
    let viewModel: DiffViewModel

    var body: some View {
        let summary = viewModel.summary
        let right = viewModel.sideName(.right)
        CenteredScrollView {
            VStack(spacing: 26) {
                FolderPairHeader(viewModel: viewModel)

                if summary.differences == 0 {
                    VStack(spacing: 12) {
                        IconTile(systemName: "checkmark", color: Palette.extra, size: 64)
                        Text("Folders Match")
                            .font(.title.weight(.semibold))
                        Text(viewModel.settings.comparisonMethod == .quick
                             ? String(localized: "All \(summary.identical) compared files match by size and date, or by contents.")
                             : String(localized: "All \(summary.identical) compared files are identical."))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                } else {
                    VStack(spacing: 6) {
                        Text("\(summary.differences) Differences")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(subtitle(summary))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    DistributionBar(segments: SummaryStatusBar.segments(summary), height: 8)

                    HStack(spacing: 12) {
                        ForEach(ChangeKind.allCases) { kind in
                            tile(kind, right: right, value: summary.count(of: kind), bytes: summary.bytes(of: kind))
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            viewModel.selectAdjacentChangedFile(forward: true)
                        } label: {
                            Label("Review First Change", systemImage: "arrow.down.forward.circle")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            viewModel.beginBatchSync()
                        } label: {
                            Label("Sync…", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(viewModel.isPerformingFileOperation)
                    }
                    .controlSize(.large)

                    HStack(spacing: 6) {
                        // One complete phrase before the keys, so translations don't depend on word order.
                        Text("Step through changed files:", comment: "Followed by the shortcuts for the next and previous changed file")
                        ShortcutKeys(shortcut: "⌃⌘↓")
                        Text(verbatim: "/")
                        ShortcutKeys(shortcut: "⌃⌘↑")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
        }
    }

    private func subtitle(_ summary: DiffSummary) -> String {
        var parts = [String(localized: "\(summary.identical) identical")]
        if summary.ignored > 0 { parts.append(String(localized: "\(summary.ignored) ignored")) }
        if viewModel.settings.comparisonMethod == .quick { parts.append(String(localized: "quick comparison by size and date")) }
        if let duration = viewModel.lastScanDuration {
            let time = duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 1))
            parts.append(String(localized: "scanned in \(time)"))
        }
        return parts.joined(separator: " · ")
    }

    private func tile(_ kind: ChangeKind, right: String, value: Int, bytes: Int64) -> some View {
        StatTile(title: kind.tileTitle(), subtitle: kind.tileSubtitle(right: right), value: value, bytes: bytes, color: kind.color, systemName: kind.symbolName) {
            viewModel.sidebarMode = .changes
            viewModel.kindFilter = [kind]
        }
        .disabled(value == 0)
        .help(value == 0 ? String(localized: "None") : String(localized: "Show only these in the sidebar"))
    }
}

/// The two compared folders with their roles.
private struct FolderPairHeader: View {
    let viewModel: DiffViewModel

    var body: some View {
        HStack(spacing: 14) {
            folder(viewModel.leftFolderURL, role: String(localized: "Reference", comment: "Role of the left folder"))
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.cardFill))
                .overlay(Circle().strokeBorder(Palette.cardStroke))
            folder(viewModel.rightFolderURL, role: String(localized: "Compared", comment: "Role of the right folder"))
        }
        .comparisonLayout()
    }

    private func folder(_ url: URL?, role: String) -> some View {
        HStack(spacing: 10) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(role.localizedUppercase)
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Text(url?.lastPathComponent ?? "—")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .help(url.map { DisplayFormat.abbreviatedPath($0) } ?? "")
    }
}

/// Centers its content vertically when it fits and scrolls when it doesn't.
struct CenteredScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct WelcomeView: View {
    let viewModel: DiffViewModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        CenteredScrollView {
            VStack(spacing: 30) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 92, height: 92)
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    Text("Compare Two Folders")
                        .font(.system(size: 28, weight: .bold))
                    Text("Drop a folder on each side or click to choose one. The left folder is the reference: the right is checked against it for changed, missing and extra files.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }

                HStack(spacing: 14) {
                    FolderDropZone(side: .left, url: viewModel.leftFolderURL) {
                        Task { await viewModel.chooseFolder(for: .left) }
                    } onDrop: { viewModel.setFolder($0, for: .left) }
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Palette.cardFill))
                        .overlay(Circle().strokeBorder(Palette.cardStroke))
                    FolderDropZone(side: .right, url: viewModel.rightFolderURL) {
                        Task { await viewModel.chooseFolder(for: .right) }
                    } onDrop: { viewModel.setFolder($0, for: .right) }
                }
                .comparisonLayout()
                .frame(maxWidth: 640)

                if !settings.recentComparisons.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent Comparisons")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                        VStack(spacing: 0) {
                            let recents = Array(settings.recentComparisons.prefix(6))
                            ForEach(recents) { recent in
                                RecentComparisonRow(recent: recent) {
                                    viewModel.openRecent(recent)
                                }
                                if recent.id != recents.last?.id {
                                    Divider().padding(.leading, 48)
                                }
                            }
                        }
                        .padding(4)
                        .cardBackground()
                    }
                    .frame(maxWidth: 640)
                }

                OpenAppBoxBadge()
            }
            .padding(40)
        }
    }
}

/// A large drop target for one side of the comparison.
private struct FolderDropZone: View {
    let side: Side
    let url: URL?
    let onChoose: () -> Void
    let onDrop: (URL) -> Void

    @State private var isTargeted = false
    @State private var isHovered = false

    var body: some View {
        Button(action: onChoose) {
            VStack(spacing: 12) {
                Group {
                    if let url {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                            .resizable()
                    } else {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(isTargeted || isHovered ? Color.accentColor : .secondary)
                    }
                }
                .frame(width: 56, height: 56)

                VStack(spacing: 3) {
                    Text(url?.lastPathComponent ?? (side == .left ? String(localized: "Left Folder") : String(localized: "Right Folder")))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(url.map { DisplayFormat.abbreviatedPath($0) } ?? (side == .left ? String(localized: "The reference copy") : String(localized: "Checked against the left")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                }

                Text(url == nil ? String(localized: "Choose…") : String(localized: "Change…"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 196)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.12) : (isHovered ? Color.primary.opacity(0.06) : Palette.cardFill))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : Color.primary.opacity(url == nil ? 0.16 : 0.08),
                        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.25, dash: url == nil ? [6, 4] : [])
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .folderDropDestination(isTargeted: $isTargeted, onDrop: onDrop)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch (side, url) {
        case (.left, let url?): String(localized: "Left folder: \(url.lastPathComponent)")
        case (.right, let url?): String(localized: "Right folder: \(url.lastPathComponent)")
        case (.left, nil): String(localized: "Choose Left Folder")
        case (.right, nil): String(localized: "Choose Right Folder")
        }
    }
}

private struct RecentComparisonRow: View {
    let recent: RecentComparison
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconTile(systemName: "clock.arrow.circlepath", color: Palette.neutral, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recent.title).fontWeight(.medium).lineLimit(1)
                    Text(verbatim: "\(DisplayFormat.abbreviatedPath(recent.leftPath))  ↔  \(DisplayFormat.abbreviatedPath(recent.rightPath))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text(recent.lastOpened, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovered ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

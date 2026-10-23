//
//  PathDiffCommands.swift
//  PathDiff
//

import SwiftUI

extension FocusedValues {
    /// The view model of the key comparison window.
    @Entry var diffViewModel: DiffViewModel?
}

struct PathDiffCommands: Commands {
    @FocusedValue(\.diffViewModel) private var viewModel
    @Environment(\.openWindow) private var openWindow
    let settings: AppSettings

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Choose Left Folder…") {
                if let viewModel { Task { await viewModel.chooseFolder(for: .left) } }
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(viewModel?.canChangeFolders != true)

            Button("Choose Right Folder…") {
                if let viewModel { Task { await viewModel.chooseFolder(for: .right) } }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(viewModel?.canChangeFolders != true)

            Menu("Open Recent Comparison") {
                ForEach(settings.recentComparisons) { recent in
                    Button(recent.title) { viewModel?.openRecent(recent) }
                }
                Divider()
                Button("Clear Menu") { settings.clearRecentComparisons() }
                    .disabled(settings.recentComparisons.isEmpty)
            }
            .disabled(viewModel?.canChangeFolders != true)

            Divider()

            Menu("Export Report") {
                ForEach(ReportFormat.allCases, id: \.self) { format in
                    Button {
                        if let viewModel { Task { await viewModel.exportReport(format: format) } }
                    } label: {
                        Text(verbatim: "\(format.title)…")
                    }
                }
            }
            .disabled(viewModel?.hasScanned != true)
            Button("Export Patch…") {
                if let viewModel { Task { await viewModel.exportPatch() } }
            }
            .keyboardShortcut("p", modifiers: [.command, .option, .shift])
            .disabled(viewModel?.hasScanned != true)
            Button("Copy Report as Markdown") { viewModel?.copyReportToPasteboard() }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                .disabled(viewModel?.hasScanned != true)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { viewModel?.saveEdits() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(viewModel?.editSession?.isDirty != true)
        }

        CommandGroup(replacing: .appInfo) {
            Button("About PathDiff") { OpenAppBox.showAboutPanel() }
        }

        CommandGroup(replacing: .help) {
            Button("PathDiff Help") { openWindow(id: HelpView.windowID) }
                .keyboardShortcut("?", modifiers: .command)
            Divider()
            Link("Visit OpenAppBox.com", destination: OpenAppBox.website)
        }

        CommandGroup(before: .sidebar) {
            Button("Show Changes List") { viewModel?.sidebarMode = .changes }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(viewModel == nil)
            Button("Show Folder Tree") { viewModel?.sidebarMode = .tree }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(viewModel == nil)
            Divider()
            Button("Side-by-Side Diff") { settings.diffLayout = .sideBySide }
                .keyboardShortcut("1", modifiers: [.command, .control])
            Button("Unified Diff") { settings.diffLayout = .unified }
                .keyboardShortcut("2", modifiers: [.command, .control])
            Toggle("Show Minimap", isOn: Binding(get: { settings.showsMinimap }, set: { settings.showsMinimap = $0 }))
            Toggle("Syntax Highlighting", isOn: Binding(get: { settings.highlightsSyntax }, set: { settings.highlightsSyntax = $0 }))
            Divider()
        }

        CommandMenu("Compare") {
            Button("Refresh") { viewModel?.rescan() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel?.hasBothFolders != true)
            Button("Rescan Ignoring Remembered Results") { viewModel?.rescanIgnoringCache() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(viewModel?.hasBothFolders != true)
            Button("Stop Scanning") { viewModel?.cancelScan() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(viewModel?.isScanning != true)
            Button("Swap Left and Right") { viewModel?.swapFolders() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(viewModel?.hasBothFolders != true || viewModel?.canChangeFolders != true)
            Picker("Compare Files By", selection: Binding(
                get: { settings.comparisonMethod },
                set: { settings.comparisonMethod = $0 }
            )) {
                ForEach(ComparisonMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }

            Divider()

            Toggle("Show Only Differences", isOn: binding(\.showOnlyDifferences))
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Toggle("Show Ignored Items", isOn: binding(\.showIgnored))
                .keyboardShortcut("i", modifiers: [.command, .shift])

            Divider()

            Button("Expand All") { viewModel?.expandAll() }
                .disabled(viewModel?.hasScanned != true)
            Button("Collapse All") { viewModel?.collapseAll() }
                .disabled(viewModel?.hasScanned != true)
        }

        CommandMenu("Navigate") {
            Button("Next Change") { viewModel?.goToNextChange() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Change") { viewModel?.goToPreviousChange() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Divider()

            Button("Next Changed File") { viewModel?.selectAdjacentChangedFile(forward: true) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(viewModel?.hasScanned != true)
            Button("Previous Changed File") { viewModel?.selectAdjacentChangedFile(forward: false) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(viewModel?.hasScanned != true)
        }

        CommandMenu("Merge") {
            Button("Sync…") { viewModel?.beginBatchSync() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(viewModel?.hasScanned != true)
            Button("Show Sync History") { openWindow(id: HistoryView.windowID) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button(viewModel?.editSession == nil ? String(localized: "Edit File") : String(localized: "Stop Editing")) { viewModel?.toggleEditing() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(viewModel.map { $0.editSession == nil && !$0.canEdit } ?? true)
            Divider()
            Button("Copy Change to Right") { viewModel?.applyCurrentHunk(direction: .leftToRight) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(viewModel?.canApplyHunks != true)
            Button("Copy Change to Left") { viewModel?.applyCurrentHunk(direction: .rightToLeft) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(viewModel?.canApplyHunks != true)

            Divider()

            Button("Copy Selection Left → Right") { viewModel?.copySelection(direction: .leftToRight) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
                .disabled(viewModel.map { !$0.canCopy($0.selectedNodes, direction: .leftToRight) } ?? true)
            Button("Copy Selection Right → Left") { viewModel?.copySelection(direction: .rightToLeft) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
                .disabled(viewModel.map { !$0.canCopy($0.selectedNodes, direction: .rightToLeft) } ?? true)
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<DiffViewModel, Bool>) -> Binding<Bool> {
        Binding(
            get: { viewModel?[keyPath: keyPath] ?? false },
            set: { viewModel?[keyPath: keyPath] = $0 }
        )
    }
}

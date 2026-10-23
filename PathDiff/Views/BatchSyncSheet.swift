//
//  BatchSyncSheet.swift
//  PathDiff
//

import AppKit
import SwiftUI

/// Sync with a dry run: choose what to sync, review (and untick) every planned operation,
/// then run it. The whole sync is one undo step.
struct BatchSyncSheet: View {
    let viewModel: DiffViewModel

    var body: some View {
        if let session = viewModel.batchSync {
            VStack(spacing: 0) {
                header(session)
                options(session)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                Divider()
                summary(session)
                OperationList(viewModel: viewModel, session: session)
                Divider()
                footer(session)
            }
            .frame(width: 760, height: 640)
        }
    }

    // MARK: Header and options

    private func header(_ session: BatchSyncSession) -> some View {
        HStack(spacing: 14) {
            IconTile(systemName: "arrow.triangle.2.circlepath", color: .accentColor, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync Folders").font(.title3.weight(.semibold))
                Text("This is a dry run: review every change below. Nothing is written until you click Sync.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private func options(_ session: BatchSyncSession) -> some View {
        let left = viewModel.sideName(.left)
        let right = viewModel.sideName(.right)
        let direction = session.options.direction
        let destination = viewModel.sideName(direction.destination)
        let source = direction == .leftToRight ? left : right
        let reversed = direction == .leftToRight ? "\(right) → \(left)" : "\(left) → \(right)"
        let isMerge = session.options.mode == .merge
        return VStack(alignment: .leading, spacing: 14) {
            Picker("Mode", selection: binding(\.options.mode)) {
                ForEach(BatchSyncMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if isMerge {
                mergeCard(left: left, right: right)
            } else {
                HStack(spacing: 12) {
                    endpoint(direction == .leftToRight ? .left : .right, role: String(localized: "From", comment: "Sync source folder"))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.accentColor.gradient))
                    endpoint(direction.destination, role: String(localized: "To", comment: "Sync destination folder"))
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(.snappy) {
                            viewModel.updateBatchSync { $0.options.direction = $0.options.direction == .leftToRight ? .rightToLeft : .leftToRight }
                        }
                    } label: {
                        Label("Reverse", systemImage: "arrow.left.arrow.right")
                    }
                    .help("Sync \(reversed) instead")
                }
                .padding(12)
                .cardBackground()
                .comparisonLayout()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Direction: \(source) to \(destination)")
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Scope").foregroundStyle(.secondary)
                    Picker("Scope", selection: scopeBinding(session)) {
                        Text("Everything").tag(false)
                        Text("Selected Items (\(session.selectionIDs.count))").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(session.selectionIDs.isEmpty)
                }
                GridRow(alignment: .top) {
                    Text("Include").foregroundStyle(.secondary)
                    if isMerge {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Replace the older copy of each modified file with the newer one", isOn: binding(\.options.copyModified))
                            Toggle("Copy items missing from either side", isOn: binding(\.options.copyMissing))
                            Text("Nothing is deleted or overwritten with an older copy. Moved and renamed items stay where they are.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Update modified files in “\(destination)”", isOn: binding(\.options.copyModified))
                            Toggle("Copy items missing from “\(destination)”", isOn: binding(\.options.copyMissing))
                            Toggle("Apply moves and renames instead of copying again", isOn: binding(\.options.applyMoves))
                                .disabled(viewModel.moves.isEmpty)
                            Toggle(isOn: binding(\.options.deleteExtras)) {
                                HStack(spacing: 4) {
                                    Text("Move extra items in “\(destination)” to the Trash")
                                    Text("(mirror)").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .disabled(session.isRunning)
    }

    /// Both folders with a two-way arrow: each receives what only the other has.
    private func mergeCard(left: String, right: String) -> some View {
        HStack(spacing: 12) {
            endpoint(.left, role: String(localized: "Folder"))
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.gradient))
            endpoint(.right, role: String(localized: "Folder"))
            Spacer(minLength: 8)
            Text("Each folder gets what only the other has; the newer copy of a changed file wins.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .cardBackground()
        .comparisonLayout()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Merge \(left) and \(right) in both directions")
    }

    private func endpoint(_ side: Side, role: String) -> some View {
        HStack(spacing: 8) {
            if let url = side == .left ? viewModel.leftFolderURL : viewModel.rightFolderURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(role.localizedUppercase)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Text(viewModel.sideName(side))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: 220, alignment: .leading)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<BatchSyncSession, Value>) -> Binding<Value> {
        // The sheet only renders while a session exists, so it is always available here.
        Self.sessionBinding(viewModel, keyPath, fallback: viewModel.batchSync ?? BatchSyncSession(selectionIDs: []))
    }

    /// A binding to a session value that stays readable after the session ends.
    ///
    /// Cancelling clears the session immediately, but SwiftUI still reads the controls'
    /// bindings while the sheet animates away; they then return the last value shown.
    static func sessionBinding<Value>(
        _ viewModel: DiffViewModel,
        _ keyPath: WritableKeyPath<BatchSyncSession, Value>,
        fallback: BatchSyncSession
    ) -> Binding<Value> {
        Binding(
            get: { viewModel.batchSync?[keyPath: keyPath] ?? fallback[keyPath: keyPath] },
            set: { value in viewModel.updateBatchSync { $0[keyPath: keyPath] = value } }
        )
    }

    private func scopeBinding(_ session: BatchSyncSession) -> Binding<Bool> {
        Binding(
            get: { viewModel.batchSync?.scopeIDs != nil },
            set: { selected in
                viewModel.updateBatchSync { $0.scopeIDs = selected ? $0.selectionIDs : nil }
            }
        )
    }

    // MARK: Summary

    private func summary(_ session: BatchSyncSession) -> some View {
        let totals = session.plan.totals(excluding: session.excluded)
        // Whole sentences for VoiceOver, one per kind of operation.
        var parts: [String] = []
        if totals.renames > 0 { parts.append(String(localized: "\(totals.renames) items will be renamed.")) }
        if totals.copiedFiles > 0 { parts.append(String(localized: "\(totals.copiedFiles) files (\(DisplayFormat.byteCount(totals.copiedBytes))) will be copied.")) }
        if totals.trashed > 0 { parts.append(String(localized: "\(totals.trashed) items (\(totals.trashedFiles) files) will be moved to the Trash.")) }
        let undoable = viewModel.batchSyncIsUndoable(session)
        return HStack(spacing: 8) {
            if parts.isEmpty {
                Label {
                    Text(session.options.mode == .merge
                        ? String(localized: "Nothing to do — neither folder is missing anything.")
                        : String(localized: "Nothing to do — the destination already matches."))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.extra)
                }
                .font(.callout.weight(.medium))
            } else {
                if totals.renames > 0 {
                    SummaryChip(systemImage: "arrow.turn.down.right", text: String(localized: "\(totals.renames) renames"), color: ChangeKind.moved.color)
                }
                if totals.copiedFiles > 0 {
                    SummaryChip(systemImage: "doc.on.doc", text: String(localized: "\(totals.copiedFiles) files") + " · " + DisplayFormat.byteCount(totals.copiedBytes), color: .accentColor)
                }
                if totals.trashed > 0 {
                    SummaryChip(systemImage: "trash", text: String(localized: "\(totals.trashed) to Trash (\(totals.trashedFiles) files)"), color: Palette.missing)
                }
            }
            Spacer()
            if !parts.isEmpty {
                Label(undoable ? String(localized: "Undo with ⌘Z") : String(localized: "Too large to undo"), systemImage: undoable ? "arrow.uturn.backward" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(undoable ? Color.secondary : Color.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Palette.barFill)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(parts.isEmpty ? String(localized: "Nothing to do") : parts.joined(separator: " "))
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(_ session: BatchSyncSession) -> some View {
        HStack(spacing: 12) {
            if let progress = session.progress, session.isRunning {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .frame(width: 180)
                Text("\(progress.completed) of \(progress.total) · \(progress.currentPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Button {
                    viewModel.copyBatchSyncPlan()
                } label: {
                    Label("Copy Dry Run", systemImage: "doc.on.clipboard")
                }
                .help("Copy the list of planned operations as text")
            }
            Spacer()
            Button(session.isRunning ? String(localized: "Stop") : String(localized: "Cancel")) { viewModel.cancelBatchSync() }
                .keyboardShortcut(.cancelAction)
            let included = session.plan.operations.count - session.excluded.count
            let trashes = !session.plan.operations(of: .trash, excluding: session.excluded).isEmpty
            Button(trashes ? String(localized: "Sync and Move to Trash") : String(localized: "Sync")) { viewModel.runBatchSync() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(trashes ? .red : .accentColor)
                .disabled(session.isRunning || included == 0)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// The dry run: every planned operation, grouped by kind, each individually excludable.
private struct OperationList: View {
    let viewModel: DiffViewModel
    let session: BatchSyncSession

    var body: some View {
        List {
            section(.rename, title: String(localized: "Rename"), systemImage: "arrow.turn.down.right", color: ChangeKind.moved.color)
            section(.copy, title: String(localized: "Copy"), systemImage: "doc.on.doc", color: .accentColor)
            section(.trash, title: String(localized: "Move to Trash"), systemImage: "trash", color: Palette.missing)
            if !session.plan.skipped.isEmpty {
                Section("Skipped") {
                    ForEach(session.plan.skipped, id: \.path) { item in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.path).font(.callout.monospaced())
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if session.plan.operations.isEmpty && session.plan.skipped.isEmpty {
                ContentUnavailableView("Nothing to Sync", systemImage: "checkmark.circle", description: Text(session.options.mode == .merge ? String(localized: "With these options, neither folder is missing anything.") : String(localized: "With these options, the destination already matches.")))
            }
        }
        .disabled(session.isRunning)
    }

    @ViewBuilder
    private func section(_ kind: SyncOperation.Kind, title: String, systemImage: String, color: Color) -> some View {
        let operations = session.plan.operations.filter { $0.kind == kind }
        if !operations.isEmpty {
            Section {
                ForEach(operations) { operation in
                    OperationRow(
                        operation: operation,
                        destinationName: session.options.mode == .merge ? viewModel.sideName(operation.destination) : nil,
                        color: color,
                        isIncluded: !session.excluded.contains(operation.id)
                    ) { included in
                        viewModel.setBatchOperation(operation.id, included: included)
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    IconTile(systemName: systemImage, color: color, size: 18)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(DisplayFormat.count(operations.count))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("All") { viewModel.setBatchOperations(of: kind, included: true) }
                    Button("None") { viewModel.setBatchOperations(of: kind, included: false) }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }
}

private struct OperationRow: View {
    let operation: SyncOperation
    /// Shown in merges, where operations go both ways.
    let destinationName: String?
    let color: Color
    let isIncluded: Bool
    let onToggle: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isIncluded }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()
            FileIconView(name: (operation.path as NSString).lastPathComponent, isDirectory: operation.isFolder, size: 20)
                .saturation(isIncluded ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryText)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                    .strikethrough(!isIncluded)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            TagLabel(text: badge, color: isIncluded ? color : .secondary)
        }
        .opacity(isIncluded ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    private var primaryText: String {
        operation.path + (operation.isFolder ? "/" : "")
    }

    private var detail: String {
        var parts: [String] = []
        if let destinationName {
            parts.append(operation.destination == .left ? String(localized: "← to \(destinationName)") : String(localized: "→ to \(destinationName)"))
        }
        if let previous = operation.previousPath { parts.append(String(localized: "from \(previous)")) }
        if operation.isFolder { parts.append(String(localized: "\(operation.fileCount) files")) }
        if operation.bytes > 0 { parts.append(DisplayFormat.byteCount(operation.bytes)) }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private var badge: String {
        switch operation.kind {
        case .rename: String(localized: "Rename")
        case .copy: operation.overwrites ? String(localized: "Update") : String(localized: "Add")
        case .trash: String(localized: "Trash", comment: "Badge: the item will be moved to the Trash")
        }
    }
}

/// One total in the dry-run summary.
private struct SummaryChip: View {
    let systemImage: String
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout.weight(.medium).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
            .lineLimit(1)
            .fixedSize()
    }
}

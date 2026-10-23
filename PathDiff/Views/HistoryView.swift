//
//  HistoryView.swift
//  PathDiff
//

import SwiftUI

/// The Sync History window: every change PathDiff made, with what, when and where, and a
/// way to revert one.
struct HistoryView: View {
    static let windowID = "history"

    @State private var history: SyncHistory
    @State private var selection: UUID?
    @State private var searchText = ""
    @State private var revertPreview: SyncHistory.RevertPreview?
    @State private var isReverting = false
    @State private var errorMessage: String?
    @State private var isConfirmingClear = false

    /// - Parameter selection: the entry to show first (previews and tests).
    init(history: SyncHistory = .shared, selection: UUID? = nil) {
        _history = State(initialValue: history)
        _selection = State(initialValue: selection)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(daySections, id: \.day) { section in
                    Section(section.title) {
                        ForEach(section.entries) { entry in
                            HistoryRow(entry: entry).tag(entry.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Filter by folder, file or action")
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
            .overlay {
                if history.isLoaded && filteredEntries.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView("No Changes Yet", systemImage: "clock.arrow.circlepath", description: Text("Syncs, copies, moves, edits and trash operations made with PathDiff appear here."))
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Label("\(DisplayFormat.byteCount(history.totalBackupBytes)) of backups", systemImage: "externaldrive")
                        .foregroundStyle(.secondary)
                        .help("Previous contents kept so changes can be reverted. The oldest backups are removed beyond 2 GB.")
                    Spacer()
                    Button("Clear History…") { isConfirmingClear = true }
                        .controlSize(.small)
                        .disabled(history.entries.isEmpty)
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        } detail: {
            if let entry = history.entries.first(where: { $0.id == selection }) {
                HistoryDetailView(entry: entry, isReverting: isReverting) {
                    requestRevert(entry)
                }
            } else {
                ContentUnavailableView {
                    Label("Select a Change", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Choose an entry to see what changed, when, and where — and to revert it.")
                }
            }
        }
        .navigationTitle("Sync History")
        .confirmationDialog(
            revertPreview.map { String(localized: "Revert “\($0.entry.title)”?") } ?? "",
            isPresented: Binding(get: { revertPreview != nil }, set: { if !$0 { revertPreview = nil } }),
            presenting: revertPreview
        ) { preview in
            Button(preview.changedSince.isEmpty ? String(localized: "Revert") : String(localized: "Revert and Overwrite Later Changes"), role: .destructive) {
                performRevert(preview.entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: { preview in
            Text(revertMessage(preview))
        }
        .alert("Couldn’t Revert", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Clear the sync history?", isPresented: $isConfirmingClear) {
            Button("Clear History", role: .destructive) {
                Task { await history.clear() }
            }
        } message: {
            Text("All entries and their backups are deleted. Changes can then no longer be reverted from here.")
        }
    }

    private struct DaySection {
        let day: Date
        let title: String
        let entries: [HistoryEntry]
    }

    /// Entries grouped by day, newest first.
    private var daySections: [DaySection] {
        let calendar = Calendar.current
        var groups: [(day: Date, entries: [HistoryEntry])] = []
        for entry in filteredEntries {
            let day = calendar.startOfDay(for: entry.date)
            if groups.last?.day == day {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((day, [entry]))
            }
        }
        return groups.map { DaySection(day: $0.day, title: Self.title(for: $0.day, calendar: calendar), entries: $0.entries) }
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        if calendar.isDate(day, equalTo: .now, toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return day.formatted(date: .long, time: .omitted)
    }

    private var filteredEntries: [HistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return history.entries }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return history.entries.filter { entry in
            entry.title.range(of: query, options: options) != nil
                || entry.leftRoot.range(of: query, options: options) != nil
                || entry.rightRoot.range(of: query, options: options) != nil
                || entry.items.contains { $0.path.range(of: query, options: options) != nil }
        }
    }

    private func requestRevert(_ entry: HistoryEntry) {
        Task {
            do {
                revertPreview = try await history.previewRevert(entry)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performRevert(_ entry: HistoryEntry) {
        isReverting = true
        Task {
            do {
                try await history.revert(entry)
            } catch {
                errorMessage = error.localizedDescription
            }
            isReverting = false
        }
    }

    private func revertMessage(_ preview: SyncHistory.RevertPreview) -> String {
        var message = String(localized: "Files in “\(preview.entry.leftName)” and “\(preview.entry.rightName)” are restored to how they were before this change. The revert is recorded in the history too.")
        if !preview.changedSince.isEmpty {
            let listed = preview.changedSince.prefix(8).joined(separator: "\n")
            let more = preview.changedSince.count > 8 ? "\n" + String(localized: "…and \(preview.changedSince.count - 8) more") : ""
            let changedAgain = String(localized: "\(preview.changedSince.count) items changed again after this change; reverting replaces those later changes:")
            message += "\n\n\(changedAgain)\n\(listed)\(more)"
        }
        return message
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            IconTile(systemName: entry.kind.symbolName, color: entry.state == .applied ? entry.kind.color : Palette.neutral, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(entry.state == .applied ? .primary : .secondary)
                HStack(spacing: 4) {
                    Text(entry.date, format: .dateTime.hour().minute())
                    Text(verbatim: "·")
                    Text("\(entry.itemCount) items")
                    Text(verbatim: "·")
                    Text(verbatim: "\(entry.leftName) ↔ \(entry.rightName)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            HistoryStateBadge(entry: entry)
        }
        .padding(.vertical, 3)
    }
}

private struct HistoryStateBadge: View {
    let entry: HistoryEntry

    var body: some View {
        switch entry.state {
        case .undone:
            badge(String(localized: "Undone"), color: Palette.edit)
        case .reverted:
            badge(String(localized: "Reverted"), color: Palette.history)
        case .applied:
            if !entry.hasBackup {
                Image(systemName: "externaldrive.badge.xmark")
                    .foregroundStyle(.secondary)
                    .help(entry.backupNote ?? String(localized: "No backup"))
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        TagLabel(text: text, color: color)
    }
}

private struct HistoryDetailView: View {
    let entry: HistoryEntry
    let isReverting: Bool
    let onRevert: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                Section("\(entry.itemCount) Items") {
                    ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                        HistoryItemRow(item: item, entry: entry)
                    }
                    if entry.itemCount > entry.items.count {
                        Text("…and \(entry.itemCount - entry.items.count) more")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemName: entry.kind.symbolName, color: entry.kind.color, size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        TagLabel(text: entry.kind.title, color: entry.kind.color)
                        if let direction = entry.direction {
                            TagLabel(
                                text: direction == .leftToRight ? "\(entry.leftName) → \(entry.rightName)" : "\(entry.rightName) → \(entry.leftName)",
                                color: .secondary
                            )
                        }
                        HistoryStateBadge(entry: entry)
                    }
                    Text(entry.date.formatted(date: .complete, time: .shortened))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Button {
                        FinderActions.copyToPasteboard(logText)
                    } label: {
                        Label("Copy Log", systemImage: "doc.on.clipboard")
                    }
                    .help("Copy a text log of this change")
                    Button {
                        onRevert()
                    } label: {
                        Label(isReverting ? String(localized: "Reverting…") : String(localized: "Revert…"), systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!entry.canRevert || isReverting)
                    .help(revertHelp)
                }
                .fixedSize()
            }

            if !actionCounts.isEmpty {
                HStack(spacing: 8) {
                    ForEach(actionCounts, id: \.action) { count in
                        Label(HistoryItemRow.countTitle(for: count.action, count: count.count), systemImage: HistoryItemRow.symbol(for: count.action))
                            .font(.callout.weight(.medium).monospacedDigit())
                            .foregroundStyle(HistoryItemRow.color(for: count.action))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(HistoryItemRow.color(for: count.action).opacity(0.12)))
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                infoRow(String(localized: "Left"), systemImage: "l.square", value: DisplayFormat.abbreviatedPath(entry.leftRoot))
                Divider().gridCellUnsizedAxes(.horizontal)
                infoRow(String(localized: "Right"), systemImage: "r.square", value: DisplayFormat.abbreviatedPath(entry.rightRoot))
                Divider().gridCellUnsizedAxes(.horizontal)
                infoRow(
                    String(localized: "Backup"),
                    systemImage: entry.hasBackup ? "externaldrive.badge.checkmark" : "externaldrive.badge.xmark",
                    value: entry.hasBackup
                        ? String(localized: "\(DisplayFormat.byteCount(entry.backupBytes)) of previous contents")
                        : (entry.backupNote ?? String(localized: "None"))
                )
            }
            .font(.callout)
            .padding(12)
            .cardBackground(cornerRadius: 10)
        }
        .padding(20)
    }

    private func infoRow(_ title: String, systemImage: String, value: String) -> some View {
        GridRow {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// How many listed items each action affected, in a stable order.
    private var actionCounts: [(action: HistoryItem.Action, count: Int)] {
        let order: [HistoryItem.Action] = [.added, .updated, .renamed, .trashed, .removed, .restored]
        let counts = Dictionary(grouping: entry.items, by: \.action).mapValues(\.count)
        return order.compactMap { action in counts[action].map { (action, $0) } }
    }

    private var revertHelp: String {
        switch entry.state {
        case .reverted: String(localized: "Already reverted")
        case .undone: String(localized: "Already undone with ⌘Z")
        case .applied: entry.hasBackup ? String(localized: "Restore the files to how they were before this change") : (entry.backupNote ?? String(localized: "No backup is available"))
        }
    }

    private var logText: String {
        var lines = [
            "\(entry.title)",
            entry.date.formatted(date: .complete, time: .standard),
            "Left: \(entry.leftRoot)",
            "Right: \(entry.rightRoot)",
            "",
        ]
        for item in entry.items {
            let side = item.side == .left ? entry.leftName : entry.rightName
            let previous = item.previousPath.map { "\($0) → " } ?? ""
            lines.append("\(item.action.rawValue.uppercased())\t\(side)\t\(previous)\(item.path)")
        }
        if entry.itemCount > entry.items.count {
            lines.append("…and \(entry.itemCount - entry.items.count) more")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct HistoryItemRow: View {
    let item: HistoryItem
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(for: item.action))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Self.color(for: item.action))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.path)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                if let previous = item.previousPath {
                    Text("from \(previous)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            Text(item.side == .left ? entry.leftName : entry.rightName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            TagLabel(text: Self.title(for: item.action), color: Self.color(for: item.action))
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }

    static func title(for action: HistoryItem.Action) -> String {
        switch action {
        case .added: String(localized: "Added")
        case .updated: String(localized: "Updated")
        case .renamed: String(localized: "Renamed")
        case .trashed: String(localized: "Trashed")
        case .restored: String(localized: "Restored")
        case .removed: String(localized: "Removed")
        }
    }

    /// "3 added", "1 renamed"… for the per-action totals.
    static func countTitle(for action: HistoryItem.Action, count: Int) -> String {
        switch action {
        case .added: String(localized: "\(count) added", comment: "Number of items added")
        case .updated: String(localized: "\(count) updated", comment: "Number of items updated")
        case .renamed: String(localized: "\(count) renamed", comment: "Number of items renamed")
        case .trashed: String(localized: "\(count) trashed", comment: "Number of items moved to the Trash")
        case .restored: String(localized: "\(count) restored", comment: "Number of items restored")
        case .removed: String(localized: "\(count) removed", comment: "Number of items removed")
        }
    }

    static func symbol(for action: HistoryItem.Action) -> String {
        switch action {
        case .added: "plus.circle.fill"
        case .updated: "pencil.circle.fill"
        case .renamed: "arrow.turn.down.right"
        case .trashed, .removed: "trash.circle.fill"
        case .restored: "arrow.uturn.backward.circle.fill"
        }
    }

    static func color(for action: HistoryItem.Action) -> Color {
        switch action {
        case .added: Palette.extra
        case .updated: Palette.modified
        case .renamed: Palette.moved
        case .trashed, .removed: Palette.missing
        case .restored: Palette.history
        }
    }
}

extension HistoryKind {
    var color: Color {
        switch self {
        case .sync: .accentColor
        case .copy: .teal
        case .copyChange: .indigo
        case .move: Palette.moved
        case .trash: Palette.missing
        case .edit: Palette.edit
        case .revert: Palette.history
        }
    }
}

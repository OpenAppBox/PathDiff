//
//  SyncHistory.swift
//  PathDiff
//

import AppKit
import Foundation
import Observation

extension Notification.Name {
    /// Posted after the history changed files outside a comparison window's own actions;
    /// `userInfo["roots"]` lists the affected folder paths.
    static let pathDiffFilesChanged = Notification.Name("PathDiffFilesChanged")
}

nonisolated enum HistoryError: LocalizedError {
    case backupMissing

    var errorDescription: String? {
        String(localized: "The backup for this change is no longer available, so it can’t be reverted.")
    }
}

/// The app-wide record of every change PathDiff made to files, with revert.
@Observable
final class SyncHistory {
    static let shared = SyncHistory(store: HistoryStore.defaultDirectory.map(HistoryStore.init(directory:)))

    /// Newest first.
    private(set) var entries: [HistoryEntry] = []
    private(set) var isLoaded = false

    @ObservationIgnored let store: HistoryStore?
    @ObservationIgnored private let fileService = FileManagerService()
    /// Store writes run one after another, in the order they were requested.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    init(store: HistoryStore?) {
        self.store = store
        Task { await reload() }
    }

    func reload() async {
        entries = await store?.entries() ?? []
        isLoaded = true
    }

    /// Waits until every recorded change has been written.
    func flush() async {
        await lastWrite?.value
    }

    private func enqueue(_ work: @escaping () async -> Void) {
        let previous = lastWrite
        lastWrite = Task {
            await previous?.value
            await work()
        }
    }

    var totalBackupBytes: Int64 {
        entries.reduce(0) { $0 + ($1.hasBackup ? $1.backupBytes : 0) }
    }

    // MARK: Recording

    /// Records an operation. `snapshots` are the previous states of the touched paths (an
    /// empty array is fine for pure renames); `nil` means no backup could be kept.
    @discardableResult
    func record(
        id: UUID = UUID(),
        _ draft: HistoryDraft,
        leftRoot: URL,
        rightRoot: URL,
        snapshots: [FileSnapshot]?,
        renames: [HistoryRename] = [],
        backupNote: String? = nil
    ) -> UUID {
        let entry = HistoryEntry(
            id: id,
            date: .now,
            kind: draft.kind,
            title: draft.title,
            leftRoot: leftRoot.path(percentEncoded: false),
            rightRoot: rightRoot.path(percentEncoded: false),
            leftBookmark: BookmarkStore.bookmark(for: leftRoot),
            rightBookmark: BookmarkStore.bookmark(for: rightRoot),
            direction: draft.direction,
            items: Array(draft.items.prefix(HistoryEntry.maximumStoredItems)),
            itemCount: draft.items.count,
            hasBackup: snapshots != nil,
            backupNote: snapshots == nil ? (backupNote ?? String(localized: "This change was too large to keep a backup.")) : backupNote
        )
        entries.insert(entry, at: 0)
        guard let store else { return id }
        enqueue { [weak self] in
            let stored = await store.record(entry, snapshots: snapshots, renames: renames)
            let persisted = Dictionary(await store.entries().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard let self else { return }
            // Recording may have pruned older entries or their backups; show that, so Revert
            // isn't offered for a backup that is gone.
            for index in self.entries.indices where self.entries[index].id != id {
                guard let current = persisted[self.entries[index].id] else { continue }
                self.entries[index].hasBackup = current.hasBackup
                self.entries[index].backupNote = current.backupNote
            }
            if self.entries.count > HistoryStore.maximumEntries {
                self.entries.removeLast(self.entries.count - HistoryStore.maximumEntries)
            }
            guard let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
            // Keep a state change made while the write was pending.
            var updated = stored
            updated.state = self.entries[index].state
            updated.revertedAt = self.entries[index].revertedAt
            self.entries[index] = updated
        }
        return id
    }

    /// Whether the entry was reverted from the History window. ⌘Z in the window that made it
    /// must not then put the same files back a second time.
    func wasReverted(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return entries.first { $0.id == id }?.state == .reverted
    }

    /// Marks an entry undone or applied again (⌘Z / ⇧⌘Z in the window that made it).
    func setState(_ id: UUID, _ state: HistoryEntry.State, revertedAt: Date? = nil) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].state = state
            entries[index].revertedAt = revertedAt
        }
        guard let store else { return }
        enqueue { _ = await store.setState(id, state, revertedAt: revertedAt) }
    }

    func clear() async {
        await flush()
        await store?.clear()
        entries = []
    }

    // MARK: Reverting

    struct RevertPreview {
        let entry: HistoryEntry
        /// Paths changed again since the entry was made; reverting overwrites those changes.
        let changedSince: [String]
    }

    func previewRevert(_ entry: HistoryEntry) async throws -> RevertPreview {
        await flush()
        guard let store, let data = await store.revertData(for: entry.id) else { throw HistoryError.backupMissing }
        let accesses = Self.access(for: entry)
        let changed = await Self.pathsChangedSince(data.after)
        withExtendedLifetime(accesses) {}
        return RevertPreview(entry: entry, changedSince: changed.map { Self.displayPath($0, entry: entry) }.sorted())
    }

    /// Restores the state from before `entry`, records the revert as its own entry, and lets
    /// open comparison windows refresh.
    func revert(_ entry: HistoryEntry) async throws {
        await flush()
        guard let store, let data = await store.revertData(for: entry.id) else { throw HistoryError.backupMissing }
        let accesses = Self.access(for: entry)
        defer { withExtendedLifetime(accesses) {} }

        // The current state becomes the revert's own backup, so a revert can be reverted too
        // (unless renames are involved, whose order can't be replayed safely).
        let current = data.renames.isEmpty
            ? try await fileService.capture(data.snapshots.map(\.url), limit: FileManagerService.undoSnapshotLimit)
            : nil
        try await fileService.restore(data.snapshots)
        for rename in data.renames.reversed() {
            _ = try await fileService.moveItem(from: URL(fileURLWithPath: rename.to), to: URL(fileURLWithPath: rename.from))
            await fileService.removeEmptyDirectories(rename.createdFolders.map { URL(fileURLWithPath: $0) })
        }

        let items = entry.items.map(Self.inverted)
        record(
            HistoryDraft(kind: .revert, title: String(localized: "Revert “\(entry.title)”"), direction: entry.direction, items: items),
            leftRoot: URL(fileURLWithPath: entry.leftRoot),
            rightRoot: URL(fileURLWithPath: entry.rightRoot),
            snapshots: current,
            backupNote: data.renames.isEmpty ? nil : String(localized: "Reverts that rename items can’t be reverted again.")
        )
        setState(entry.id, .reverted, revertedAt: .now)
        NotificationCenter.default.post(name: .pathDiffFilesChanged, object: nil, userInfo: ["roots": [entry.leftRoot, entry.rightRoot]])
    }

    // MARK: Helpers

    private static func access(for entry: HistoryEntry) -> [SecurityScopedAccess] {
        [entry.leftBookmark, entry.rightBookmark]
            .compactMap { $0.flatMap { BookmarkStore.resolve($0) } }
            .map(SecurityScopedAccess.init(url:))
    }

    @concurrent
    private static func pathsChangedSince(_ after: [String: HistoryAfterState]) async -> [String] {
        after.compactMap { path, state in
            HistoryAfterState.current(at: path) == state ? nil : path
        }
    }

    static func displayPath(_ path: String, entry: HistoryEntry) -> String {
        for (root, name) in [(entry.leftRoot, entry.leftName), (entry.rightRoot, entry.rightName)] {
            if let relative = PathUtilities.relativePath(path, to: root) {
                return "\(name)/\(relative)"
            }
        }
        return path
    }

    private static func inverted(_ item: HistoryItem) -> HistoryItem {
        switch item.action {
        case .added:
            HistoryItem(action: .removed, path: item.path, previousPath: nil, side: item.side)
        case .renamed:
            HistoryItem(action: .renamed, path: item.previousPath ?? item.path, previousPath: item.path, side: item.side)
        case .updated, .trashed, .removed:
            HistoryItem(action: .restored, path: item.path, previousPath: nil, side: item.side)
        case .restored:
            HistoryItem(action: .updated, path: item.path, previousPath: nil, side: item.side)
        }
    }
}

//
//  HistoryModels.swift
//  PathDiff
//

import Foundation

/// What kind of change a history entry records.
nonisolated enum HistoryKind: String, Codable, Sendable, CaseIterable {
    case sync
    case copy
    case copyChange
    case move
    case trash
    case edit
    case revert

    var title: String {
        switch self {
        case .sync: String(localized: "history.kind.sync", defaultValue: "Sync", comment: "Kind of a Sync History entry, shown as a label (a noun where the language prefers one)")
        case .copy: String(localized: "history.kind.copy", defaultValue: "Copy", comment: "Kind of a Sync History entry, shown as a label (a noun where the language prefers one)")
        case .copyChange: String(localized: "history.kind.copyChange", defaultValue: "Copy Change", comment: "Kind of a Sync History entry, shown as a label (a noun where the language prefers one)")
        case .move: String(localized: "history.kind.move", defaultValue: "Move", comment: "Kind of a Sync History entry, shown as a label (a noun where the language prefers one)")
        case .trash: String(localized: "history.kind.trash", defaultValue: "Move to Trash", comment: "Kind of a Sync History entry, shown as a label (a noun where the language prefers one)")
        case .edit: String(localized: "history.kind.edit", defaultValue: "Edit", comment: "Kind of a Sync History entry, shown as a label (a noun where the language prefers one)")
        case .revert: String(localized: "history.kind.revert", defaultValue: "Revert", comment: "Kind of a Sync History entry, shown as a label (a noun where the language prefers one)")
        }
    }

    var symbolName: String {
        switch self {
        case .sync: "arrow.triangle.2.circlepath"
        case .copy: "doc.on.doc"
        case .copyChange: "arrow.left.arrow.right"
        case .move: "arrow.turn.down.right"
        case .trash: "trash"
        case .edit: "pencil"
        case .revert: "arrow.uturn.backward"
        }
    }
}

/// One path an operation changed.
nonisolated struct HistoryItem: Codable, Sendable, Hashable {
    enum Action: String, Codable, Sendable {
        case added
        case updated
        case renamed
        case trashed
        case restored
        case removed
    }

    let action: Action
    /// Relative to the compared folder on `side`.
    let path: String
    let previousPath: String?
    let side: Side
}

/// A rename performed by an operation, with absolute paths, for reverting.
nonisolated struct HistoryRename: Codable, Sendable, Hashable {
    let from: String
    let to: String
    /// Folders the rename had to create, removed again when reverting if empty.
    let createdFolders: [String]
}

/// A recorded change, persisted between launches.
nonisolated struct HistoryEntry: Codable, Sendable, Identifiable, Hashable {
    enum State: String, Codable, Sendable {
        case applied
        /// Undone with ⌘Z in the session that made it.
        case undone
        /// Reverted from the history.
        case reverted
    }

    let id: UUID
    let date: Date
    let kind: HistoryKind
    let title: String
    let leftRoot: String
    let rightRoot: String
    let leftBookmark: Data?
    let rightBookmark: Data?
    let direction: SyncDirection?
    /// The first items (long lists are truncated); `itemCount` has the total.
    var items: [HistoryItem]
    var itemCount: Int
    var state: State = .applied
    var revertedAt: Date?
    /// Backups of the previous contents exist, so the entry can be reverted.
    var hasBackup = false
    var backupBytes: Int64 = 0
    /// Why there is no backup, when there isn't.
    var backupNote: String?

    static let maximumStoredItems = 2_000

    var leftName: String { (leftRoot as NSString).lastPathComponent }
    var rightName: String { (rightRoot as NSString).lastPathComponent }

    var canRevert: Bool { hasBackup && state == .applied }

    func root(for side: Side) -> String { side == .left ? leftRoot : rightRoot }
}

nonisolated extension HistoryEntry {
    private enum CodingKeys: String, CodingKey {
        case id, date, kind, title, leftRoot, rightRoot, leftBookmark, rightBookmark, direction
        case items, itemCount, state, revertedAt, hasBackup, backupBytes, backupNote
    }

    /// Fields with defaults may be missing, so indexes written by older versions stay readable
    /// when fields are added.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        kind = try container.decode(HistoryKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        leftRoot = try container.decode(String.self, forKey: .leftRoot)
        rightRoot = try container.decode(String.self, forKey: .rightRoot)
        leftBookmark = try container.decodeIfPresent(Data.self, forKey: .leftBookmark)
        rightBookmark = try container.decodeIfPresent(Data.self, forKey: .rightBookmark)
        direction = try container.decodeIfPresent(SyncDirection.self, forKey: .direction)
        items = try container.decodeIfPresent([HistoryItem].self, forKey: .items) ?? []
        itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? items.count
        state = try container.decodeIfPresent(State.self, forKey: .state) ?? .applied
        revertedAt = try container.decodeIfPresent(Date.self, forKey: .revertedAt)
        hasBackup = try container.decodeIfPresent(Bool.self, forKey: .hasBackup) ?? false
        backupBytes = try container.decodeIfPresent(Int64.self, forKey: .backupBytes) ?? 0
        backupNote = try container.decodeIfPresent(String.self, forKey: .backupNote)
    }
}

/// What a caller knows about an operation before it is recorded.
nonisolated struct HistoryDraft: Sendable {
    let kind: HistoryKind
    let title: String
    let direction: SyncDirection?
    let items: [HistoryItem]
}

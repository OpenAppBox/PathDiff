//
//  HistoryStore.swift
//  PathDiff
//

import Foundation
import OSLog

/// The state a path was left in by an operation, to detect later changes before reverting.
nonisolated struct HistoryAfterState: Codable, Sendable, Equatable {
    let exists: Bool
    let isDirectory: Bool
    let stamp: FileStamp?

    static func current(at path: String) -> HistoryAfterState {
        guard let metadata = ScanEngine.readMetadata(at: URL(fileURLWithPath: path)) else {
            return HistoryAfterState(exists: false, isDirectory: false, stamp: nil)
        }
        let isDirectory = metadata.kind == .directory
        return HistoryAfterState(exists: true, isDirectory: isDirectory, stamp: isDirectory ? nil : metadata.stamp)
    }
}

/// Everything needed to revert an entry.
nonisolated struct HistoryRevertData: Sendable {
    let snapshots: [FileSnapshot]
    let renames: [HistoryRename]
    let after: [String: HistoryAfterState]
}

/// Persists the sync history: `index.json` with all entries, plus one folder per entry with
/// a manifest and the backed-up previous file contents.
actor HistoryStore {
    let directory: URL

    static let maximumEntries = 300
    /// Older backups are deleted (their entries stay, but can't be reverted) beyond this.
    static let backupBudget: Int64 = 2 * 1024 * 1024 * 1024
    private static let logger = Logger(subsystem: "com.openappbox.pathdiff", category: "History")

    private var index: [HistoryEntry]?
    /// False after a damaged index was set aside: its backup folders are then not swept as
    /// orphans, so they can still be recovered by hand.
    private var indexIsTrusted = true

    /// Inside the app's container when sandboxed.
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: Bundle.main.bundleIdentifier ?? "PathDiff", directoryHint: .isDirectory)
            .appending(path: "History", directoryHint: .isDirectory)
    }

    init(directory: URL) {
        self.directory = directory
    }

    private var indexURL: URL { directory.appending(path: "index.json") }

    private func folder(for id: UUID) -> URL {
        directory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    // MARK: Reading

    func entries() -> [HistoryEntry] {
        if let index { return index }
        let loaded = loadIndex()
        index = loaded
        return loaded
    }

    /// Reads `index.json` one entry at a time, so an entry this version can't read (for example
    /// one written by a newer version) doesn't cost the whole history. An index that isn't
    /// readable at all is kept aside rather than overwritten by the next save.
    private func loadIndex() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        guard let decoded = try? Self.decoder.decode([Lenient<HistoryEntry>].self, from: data) else {
            Self.logger.error("History index is damaged; keeping it aside and starting a new one")
            indexIsTrusted = false
            let aside = directory.appending(path: "index-damaged-\(Int(Date.now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: indexURL, to: aside)
            return []
        }
        let entries = decoded.compactMap(\.value)
        if entries.count < decoded.count {
            Self.logger.error("Skipped \(decoded.count - entries.count) unreadable history entries")
        }
        return entries
    }

    func revertData(for id: UUID) -> HistoryRevertData? {
        let entryFolder = folder(for: id)
        guard let data = try? Data(contentsOf: entryFolder.appending(path: "manifest.json")),
              let manifest = try? Self.decoder.decode(Manifest.self, from: data)
        else { return nil }
        var snapshots: [FileSnapshot] = []
        for snapshot in manifest.snapshots {
            let url = URL(fileURLWithPath: snapshot.path)
            switch snapshot.kind {
            case .file:
                guard let blob = snapshot.blob,
                      let contents = try? Data(contentsOf: entryFolder.appending(path: "blobs").appending(path: blob))
                else { return nil }
                snapshots.append(FileSnapshot(url: url, state: .file(contents, permissions: snapshot.permissions)))
            case .symlink:
                snapshots.append(FileSnapshot(url: url, state: .symlink(destination: snapshot.symlinkDestination ?? "")))
            case .directory:
                snapshots.append(FileSnapshot(url: url, state: .directory))
            case .missing:
                snapshots.append(FileSnapshot(url: url, state: .missing))
            }
        }
        return HistoryRevertData(snapshots: snapshots, renames: manifest.renames, after: manifest.after)
    }

    func totalBackupBytes() -> Int64 {
        entries().reduce(0) { $0 + ($1.hasBackup ? $1.backupBytes : 0) }
    }

    // MARK: Writing

    /// Stores an entry with its backups (`nil` snapshots means no backup could be kept) and
    /// returns the stored version.
    func record(_ entry: HistoryEntry, snapshots: [FileSnapshot]?, renames: [HistoryRename]) -> HistoryEntry {
        var entry = entry
        var entries = entries()
        if let snapshots {
            do {
                entry.backupBytes = try writeBackup(for: entry.id, snapshots: snapshots, renames: renames)
                entry.hasBackup = true
            } catch {
                Self.logger.error("Couldn’t store history backup: \(error.localizedDescription, privacy: .public)")
                entry.hasBackup = false
                entry.backupNote = String(localized: "The backup couldn’t be saved: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: folder(for: entry.id))
            }
        }
        entries.insert(entry, at: 0)
        entries = prune(entries)
        save(entries)
        return entries.first { $0.id == entry.id } ?? entry
    }

    func setState(_ id: UUID, _ state: HistoryEntry.State, revertedAt: Date? = nil) -> HistoryEntry? {
        var entries = entries()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        entries[index].state = state
        entries[index].revertedAt = revertedAt
        save(entries)
        return entries[index]
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        index = []
    }

    // MARK: Internals

    private struct Manifest: Codable {
        struct Snapshot: Codable {
            enum Kind: String, Codable { case file, symlink, directory, missing }
            let path: String
            let kind: Kind
            let blob: String?
            let permissions: Int?
            let symlinkDestination: String?
        }

        var snapshots: [Snapshot]
        var renames: [HistoryRename]
        var after: [String: HistoryAfterState]
    }

    /// Decodes a value or, when it can't, nothing (instead of failing the whole array).
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Writes the previous contents and the after-state of every touched path.
    private func writeBackup(for id: UUID, snapshots: [FileSnapshot], renames: [HistoryRename]) throws -> Int64 {
        let fileManager = FileManager()
        let entryFolder = folder(for: id)
        let blobs = entryFolder.appending(path: "blobs", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: blobs, withIntermediateDirectories: true)

        var bytes: Int64 = 0
        var records: [Manifest.Snapshot] = []
        for (index, snapshot) in snapshots.enumerated() {
            let path = snapshot.url.path(percentEncoded: false)
            switch snapshot.state {
            case .file(let data, let permissions):
                let name = "\(index)"
                try data.write(to: blobs.appending(path: name))
                bytes += Int64(data.count)
                records.append(.init(path: path, kind: .file, blob: name, permissions: permissions, symlinkDestination: nil))
            case .symlink(let destination):
                records.append(.init(path: path, kind: .symlink, blob: nil, permissions: nil, symlinkDestination: destination))
            case .directory:
                records.append(.init(path: path, kind: .directory, blob: nil, permissions: nil, symlinkDestination: nil))
            case .missing:
                records.append(.init(path: path, kind: .missing, blob: nil, permissions: nil, symlinkDestination: nil))
            }
        }

        var after: [String: HistoryAfterState] = [:]
        for path in records.map(\.path) + renames.flatMap({ [$0.from, $0.to] }) {
            after[path] = HistoryAfterState.current(at: path)
        }
        let manifest = Manifest(snapshots: records, renames: renames, after: after)
        try Self.encoder.encode(manifest).write(to: entryFolder.appending(path: "manifest.json"), options: .atomic)
        return bytes
    }

    /// Keeps the newest entries and drops the oldest backups once over budget.
    private func prune(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        var kept = Array(entries.prefix(Self.maximumEntries))
        for dropped in entries.dropFirst(Self.maximumEntries) {
            try? FileManager.default.removeItem(at: folder(for: dropped.id))
        }
        removeOrphanedBackups(keeping: Set(kept.map(\.id)))
        var total = kept.reduce(Int64(0)) { $0 + ($1.hasBackup ? $1.backupBytes : 0) }
        var index = kept.count - 1
        while total > Self.backupBudget, index > 0 {
            if kept[index].hasBackup {
                try? FileManager.default.removeItem(at: folder(for: kept[index].id))
                total -= kept[index].backupBytes
                kept[index].hasBackup = false
                kept[index].backupNote = String(localized: "The backup was removed to save space.")
            }
            index -= 1
        }
        return kept
    }

    /// Deletes backup folders no entry refers to (left by entries that were skipped or lost),
    /// which the backup budget would otherwise never count.
    private func removeOrphanedBackups(keeping ids: Set<UUID>) {
        guard indexIsTrusted,
              let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent), !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func save(_ entries: [HistoryEntry]) {
        index = entries
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(entries).write(to: indexURL, options: .atomic)
        } catch {
            Self.logger.error("Couldn’t save history: \(error.localizedDescription, privacy: .public)")
        }
    }
}

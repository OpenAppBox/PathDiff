//
//  DiffNode.swift
//  PathDiff
//

import Foundation

/// The comparison outcome for a single item in the merged folder tree.
nonisolated enum FileStatus: String, Sendable, Hashable, CaseIterable {
    case identical
    case modified
    case leftOnly
    case rightOnly
    case ignored

    var isDifference: Bool {
        switch self {
        case .modified, .leftOnly, .rightOnly: true
        case .identical, .ignored: false
        }
    }

    /// The status as seen after swapping the left and right folders.
    var mirrored: FileStatus {
        switch self {
        case .leftOnly: .rightOnly
        case .rightOnly: .leftOnly
        default: self
        }
    }
}

/// One of the two compared folders.
nonisolated enum Side: String, Sendable, Hashable, CaseIterable, Codable {
    case left
    case right

    var opposite: Side { self == .left ? .right : .left }
    var title: String { self == .left ? String(localized: "Left", comment: "Left folder") : String(localized: "Right", comment: "Right folder") }
}

nonisolated enum ItemKind: String, Sendable, Hashable {
    case file
    case directory
    case symlink
}

/// File-system facts captured for one side of a node during a scan.
nonisolated struct ItemMetadata: Sendable, Hashable {
    var kind: ItemKind
    var size: Int64
    var modificationDate: Date?
    var symlinkDestination: String?
    /// The file system's identifier (inode); changes when a file is replaced.
    var fileIdentifier: UInt64?

    /// Identifies this exact version of a file for caching comparison results.
    var stamp: FileStamp? {
        guard let modificationDate else { return nil }
        return FileStamp(size: size, modified: modificationDate.timeIntervalSinceReferenceDate, identifier: fileIdentifier)
    }
}

nonisolated struct FileStamp: Sendable, Hashable, Codable {
    let size: Int64
    let modified: Double
    let identifier: UInt64?
}

/// A file or folder in the merged left/right tree.
///
/// `id` is the item's path relative to the compared roots, which keeps identity stable
/// across rescans and partial refreshes.
nonisolated struct DiffNode: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let relativePath: String
    var leftURL: URL?
    var rightURL: URL?
    var isDirectory: Bool
    var status: FileStatus
    var children: [DiffNode]?
    var leftMetadata: ItemMetadata?
    var rightMetadata: ItemMetadata?
    /// Number of differing files at or below this node (ignored items excluded).
    private(set) var differenceCount: Int

    init(
        name: String,
        relativePath: String,
        leftURL: URL?,
        rightURL: URL?,
        leftMetadata: ItemMetadata?,
        rightMetadata: ItemMetadata?,
        status: FileStatus,
        children: [DiffNode]?
    ) {
        self.id = relativePath
        self.name = name
        self.relativePath = relativePath
        self.leftURL = leftURL
        self.rightURL = rightURL
        self.leftMetadata = leftMetadata
        self.rightMetadata = rightMetadata
        self.isDirectory = leftMetadata?.kind == .directory || rightMetadata?.kind == .directory
        self.status = status
        self.children = children
        self.differenceCount = 0
        recomputeAggregates()
    }

    var existsOnLeft: Bool { leftURL != nil }
    var existsOnRight: Bool { rightURL != nil }
    var hasChildren: Bool { !(children?.isEmpty ?? true) }

    /// True when one side is a folder and the other a file (or a file and a symlink).
    var hasKindMismatch: Bool {
        guard let left = leftMetadata, let right = rightMetadata else { return false }
        return left.kind != right.kind
    }

    var isSymlink: Bool {
        leftMetadata?.kind == .symlink || rightMetadata?.kind == .symlink
    }

    func exists(on side: Side) -> Bool { url(on: side) != nil }

    func url(on side: Side) -> URL? {
        side == .left ? leftURL : rightURL
    }

    func metadata(on side: Side) -> ItemMetadata? {
        side == .left ? leftMetadata : rightMetadata
    }

    /// Both files and their versions. Changes when a file is copied over, edited or replaced
    /// at the same path, so views that show file contents know to load them again.
    var contentIdentity: ContentIdentity {
        ContentIdentity(left: leftURL, right: rightURL, leftStamp: leftMetadata?.stamp, rightStamp: rightMetadata?.stamp)
    }

    struct ContentIdentity: Hashable, Sendable {
        let left: URL?
        let right: URL?
        let leftStamp: FileStamp?
        let rightStamp: FileStamp?
    }

    /// Re-derives a folder's status and difference count from its children.
    mutating func recomputeAggregates() {
        guard isDirectory, status != .ignored else {
            differenceCount = status.isDifference ? 1 : 0
            return
        }
        let kids = children ?? []
        let childDifferences = kids.reduce(0) { $0 + $1.differenceCount }
        if hasKindMismatch {
            status = .modified
            differenceCount = max(1, childDifferences)
        } else {
            differenceCount = childDifferences
            if existsOnLeft && existsOnRight {
                status = kids.contains { $0.status.isDifference } ? .modified : .identical
            }
        }
    }

    /// The same node as seen with the left and right folders swapped.
    func mirrored() -> DiffNode {
        var copy = self
        copy.leftURL = rightURL
        copy.rightURL = leftURL
        copy.leftMetadata = rightMetadata
        copy.rightMetadata = leftMetadata
        copy.status = status.mirrored
        copy.children = children?.map { $0.mirrored() }
        return copy
    }

    /// Folders first, then a case-insensitive natural name order (`file2` before `file10`).
    static func sortPrecedes(_ lhs: DiffNode, _ rhs: DiffNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return NaturalOrder.precedes(lhs.name, rhs.name)
    }

    // Equality deliberately skips a deep comparison of `children`: every child is compared on
    // its own when it is displayed, and changes below a folder surface in `differenceCount`.
    static func == (lhs: DiffNode, rhs: DiffNode) -> Bool {
        lhs.id == rhs.id
            && lhs.status == rhs.status
            && lhs.isDirectory == rhs.isDirectory
            && lhs.leftURL == rhs.leftURL
            && lhs.rightURL == rhs.rightURL
            && lhs.leftMetadata == rhs.leftMetadata
            && lhs.rightMetadata == rhs.rightMetadata
            && lhs.differenceCount == rhs.differenceCount
            && lhs.children?.count == rhs.children?.count
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// File-level counts for a tree or subtree.
nonisolated struct DiffSummary: Sendable, Equatable {
    var modified = 0
    var leftOnly = 0
    var rightOnly = 0
    var identical = 0
    var ignored = 0
    /// Matched moves; their files are not counted in `leftOnly` / `rightOnly`.
    var moved = 0

    /// Bytes involved per kind: the larger version of modified files, the left copy of
    /// moved and missing files, the right copy of extra files.
    var modifiedBytes: Int64 = 0
    var movedBytes: Int64 = 0
    var leftOnlyBytes: Int64 = 0
    var rightOnlyBytes: Int64 = 0

    var differences: Int { modified + leftOnly + rightOnly + moved }

    init() {}

    init(nodes: [DiffNode]) {
        for node in nodes { accumulate(node) }
    }

    func count(of kind: ChangeKind) -> Int {
        switch kind {
        case .modified: modified
        case .moved: moved
        case .leftOnly: leftOnly
        case .rightOnly: rightOnly
        }
    }

    func bytes(of kind: ChangeKind) -> Int64 {
        switch kind {
        case .modified: modifiedBytes
        case .moved: movedBytes
        case .leftOnly: leftOnlyBytes
        case .rightOnly: rightOnlyBytes
        }
    }

    /// Reclassifies one-sided files that were matched as moves. With `tree`, their bytes
    /// are moved over too.
    mutating func apply(_ moves: MoveMap, in tree: [DiffNode] = []) {
        let count = moves.fileMoveCount
        moved = count
        leftOnly = max(0, leftOnly - count)
        rightOnly = max(0, rightOnly - count)
        guard !tree.isEmpty else { return }
        for match in moves.allMatches where !match.isDirectory {
            reclassifyBytes(of: match, in: tree)
        }
    }

    /// Moves one file move's bytes from missing/extra to moved.
    mutating func reclassifyBytes(of match: MoveMatch, in tree: [DiffNode], countsLeft: Bool = true, countsRight: Bool = true) {
        if countsLeft, let size = DiffTree.node(at: match.leftPath, in: tree)?.leftMetadata?.size {
            leftOnlyBytes = max(0, leftOnlyBytes - size)
            movedBytes += size
        }
        if countsRight, let size = DiffTree.node(at: match.rightPath, in: tree)?.rightMetadata?.size {
            rightOnlyBytes = max(0, rightOnlyBytes - size)
            if !countsLeft { movedBytes += size }
        }
    }

    private mutating func accumulate(_ node: DiffNode) {
        if node.status == .ignored {
            ignored += 1
            return
        }
        if node.isDirectory && !node.hasKindMismatch {
            for child in node.children ?? [] { accumulate(child) }
            return
        }
        switch node.status {
        case .identical: identical += 1
        case .modified:
            modified += 1
            modifiedBytes += max(node.leftMetadata?.size ?? 0, node.rightMetadata?.size ?? 0)
        case .leftOnly:
            leftOnly += 1
            leftOnlyBytes += node.leftMetadata?.size ?? 0
        case .rightOnly:
            rightOnly += 1
            rightOnlyBytes += node.rightMetadata?.size ?? 0
        case .ignored: ignored += 1
        }
    }
}

/// Case-insensitive natural ordering, much cheaper than `localizedStandardCompare` when
/// sorting hundreds of thousands of names.
nonisolated enum NaturalOrder {
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) < 0
    }

    static func compare(_ lhs: String, _ rhs: String) -> Int {
        var left = lhs.unicodeScalars.makeIterator()
        var right = rhs.unicodeScalars.makeIterator()
        var leftScalar = left.next()
        var rightScalar = right.next()
        var tieBreak = 0

        while let l = leftScalar, let r = rightScalar {
            if isDigit(l) && isDigit(r) {
                // Compare whole digit runs by numeric value.
                var leftDigits: [UInt32] = []
                var rightDigits: [UInt32] = []
                while let scalar = leftScalar, isDigit(scalar) { leftDigits.append(scalar.value); leftScalar = left.next() }
                while let scalar = rightScalar, isDigit(scalar) { rightDigits.append(scalar.value); rightScalar = right.next() }
                let leftTrimmed = leftDigits.drop { $0 == 48 }
                let rightTrimmed = rightDigits.drop { $0 == 48 }
                if leftTrimmed.count != rightTrimmed.count { return leftTrimmed.count < rightTrimmed.count ? -1 : 1 }
                for (a, b) in zip(leftTrimmed, rightTrimmed) where a != b { return a < b ? -1 : 1 }
                if tieBreak == 0, leftDigits.count != rightDigits.count { tieBreak = leftDigits.count < rightDigits.count ? -1 : 1 }
                continue
            }
            let lowerLeft = lowercase(l)
            let lowerRight = lowercase(r)
            if lowerLeft != lowerRight { return lowerLeft < lowerRight ? -1 : 1 }
            if tieBreak == 0, l.value != r.value { tieBreak = l.value < r.value ? -1 : 1 }
            leftScalar = left.next()
            rightScalar = right.next()
        }
        if leftScalar != nil { return 1 }
        if rightScalar != nil { return -1 }
        return tieBreak
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }

    private static func lowercase(_ scalar: Unicode.Scalar) -> UInt32 {
        if scalar.value >= 65 && scalar.value <= 90 { return scalar.value + 32 }
        if scalar.isASCII { return scalar.value }
        return scalar.properties.lowercaseMapping.unicodeScalars.first?.value ?? scalar.value
    }
}

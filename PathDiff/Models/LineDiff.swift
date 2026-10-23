//
//  LineDiff.swift
//  PathDiff
//

import Foundation

nonisolated enum LineDiffType: String, Sendable, Hashable {
    case unchanged
    case added
    case deleted
    case modified
}

/// One row of the side-by-side view. A row pairs a left line with a right line; either side
/// is `nil` when the row is a pure insertion or deletion.
nonisolated struct LineDiff: Identifiable, Hashable, Sendable {
    /// Row index within `TextDiff.lines`.
    let id: Int
    let leftLineNumber: Int?
    let rightLineNumber: Int?
    let leftContent: String?
    let rightContent: String?
    let type: LineDiffType
    /// Index into `TextDiff.hunks` for changed rows.
    let hunkIndex: Int?
    /// Changed character ranges (in `Character` offsets) inside a modified line.
    var leftHighlights: [Range<Int>] = []
    var rightHighlights: [Range<Int>] = []
}

/// A contiguous block of changed rows, which is the unit for block-level sync.
nonisolated struct DiffHunk: Identifiable, Hashable, Sendable {
    let id: Int
    /// Zero-based line indices in the left document.
    let leftRange: Range<Int>
    /// Zero-based line indices in the right document.
    let rightRange: Range<Int>
    /// Indices into `TextDiff.lines`.
    let rowRange: Range<Int>

    var deletedCount: Int { leftRange.count }
    var addedCount: Int { rightRange.count }
}

/// How a scan decides whether two files at the same path are equal.
nonisolated enum ComparisonMethod: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// Every byte is compared (files of different sizes differ without being read).
    case contents
    /// Files with the same size and modification date count as equal without being read;
    /// all others are compared byte by byte. Much faster for large photo and video backups.
    case quick

    var id: Self { self }

    var title: String {
        switch self {
        case .contents: String(localized: "Contents (byte by byte)")
        case .quick: String(localized: "Quick (size and date)")
        }
    }

    /// FAT and exFAT drives store modification times with 2-second precision, so a copy on
    /// a backup drive can be up to that far off.
    static let modificationDateTolerance: TimeInterval = 2

    static func haveSameModificationDate(_ lhs: ItemMetadata, _ rhs: ItemMetadata) -> Bool {
        guard let left = lhs.modificationDate, let right = rhs.modificationDate else { return false }
        return abs(left.timeIntervalSince(right)) <= modificationDateTolerance
    }
}

nonisolated struct DiffOptions: Sendable, Hashable {
    var ignoreWhitespace = false
    var ignoreLineEndings = false
    var comparisonMethod = ComparisonMethod.contents

    /// Whether files whose bytes differ still need a text-level comparison.
    var isTextAware: Bool { ignoreWhitespace || ignoreLineEndings }
}

nonisolated struct TextDiff: Sendable, Equatable {
    /// `nil` when the file does not exist on that side.
    let left: TextDocument?
    let right: TextDocument?
    let options: DiffOptions
    let lines: [LineDiff]
    let hunks: [DiffHunk]
    /// Syntax spans per line, when the language is recognized and highlighting is on.
    var leftSyntax: SyntaxHighlights?
    var rightSyntax: SyntaxHighlights?

    var hasTextualChanges: Bool { !hunks.isEmpty }

    // Rows and hunks are derived from the documents and options. Whether syntax colors are
    // present counts too, so turning highlighting on or off reloads the open file.
    static func == (lhs: TextDiff, rhs: TextDiff) -> Bool {
        lhs.left == rhs.left && lhs.right == rhs.right && lhs.options == rhs.options
            && (lhs.leftSyntax == nil) == (rhs.leftSyntax == nil) && (lhs.rightSyntax == nil) == (rhs.rightSyntax == nil)
    }
}

nonisolated struct BinaryComparison: Sendable, Equatable {
    let leftSize: Int64?
    let rightSize: Int64?
    let areIdentical: Bool
    let isImage: Bool
}

/// A video or audio file on one or both sides, compared by playing it and by its details.
nonisolated struct MediaComparison: Sendable, Equatable {
    let kind: MediaKind
    let leftSize: Int64?
    let rightSize: Int64?
    let areIdentical: Bool
}

/// What the detail pane shows for the selected node.
nonisolated enum FileDiffContent: Sendable, Equatable {
    case none
    case loading
    case directory
    case ignored
    case typeMismatch
    case text(TextDiff)
    case binary(BinaryComparison)
    case media(MediaComparison)
    case symlink(left: String?, right: String?)
    case tooLarge(leftSize: Int64?, rightSize: Int64?)
    case failed(String)
}

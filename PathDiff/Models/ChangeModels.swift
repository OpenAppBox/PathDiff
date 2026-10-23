//
//  ChangeModels.swift
//  PathDiff
//

import Foundation

/// How an item differs, as presented to the user. The left folder is treated as the
/// reference ("main") side: left-only items are missing from the right, right-only items
/// are extra in the right.
nonisolated enum ChangeKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case modified
    case moved
    case leftOnly
    case rightOnly

    var id: Self { self }
}

/// A one-sided item on the left matched with a one-sided item on the right at another path.
nonisolated struct MoveMatch: Sendable, Hashable {
    let leftPath: String
    let rightPath: String
    /// Identical contents. Otherwise the files share a name and mostly the same lines.
    let isExact: Bool
    let isDirectory: Bool
    /// For folders: how many files moved along, out of how many in the larger side.
    var matchedFiles = 1
    var totalFiles = 1

    func counterpartPath(from side: Side) -> String {
        side == .left ? rightPath : leftPath
    }
}

/// All detected moves, indexed by the path on either side.
nonisolated struct MoveMap: Sendable, Equatable {
    private(set) var byLeftPath: [String: MoveMatch] = [:]
    private(set) var byRightPath: [String: MoveMatch] = [:]
    private(set) var fileMoveCount = 0

    var isEmpty: Bool { byLeftPath.isEmpty }

    var allMatches: [MoveMatch] { Array(byLeftPath.values) }

    mutating func insert(_ match: MoveMatch) {
        byLeftPath[match.leftPath] = match
        byRightPath[match.rightPath] = match
        if !match.isDirectory { fileMoveCount += 1 }
    }

    /// The same moves as seen with the left and right folders swapped.
    func mirrored() -> MoveMap {
        var result = MoveMap()
        for match in byLeftPath.values {
            var swapped = MoveMatch(leftPath: match.rightPath, rightPath: match.leftPath, isExact: match.isExact, isDirectory: match.isDirectory)
            swapped.matchedFiles = match.matchedFiles
            swapped.totalFiles = match.totalFiles
            result.insert(swapped)
        }
        return result
    }

    /// Every folder that contains a moved item on the given side (used to keep such folders
    /// expanded rather than collapsed in the Changes list).
    func ancestorsOfMoves(on side: Side) -> Set<String> {
        var result = Set<String>()
        for path in (side == .left ? byLeftPath.keys : byRightPath.keys) {
            result.formUnion(DiffTree.ancestorPaths(of: path))
        }
        return result
    }

    /// The move a one-sided node takes part in, if any.
    func match(for node: DiffNode) -> MoveMatch? {
        switch node.status {
        case .leftOnly: byLeftPath[node.relativePath]
        case .rightOnly: byRightPath[node.relativePath]
        default: nil
        }
    }
}

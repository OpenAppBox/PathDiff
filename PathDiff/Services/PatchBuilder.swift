//
//  PatchBuilder.swift
//  PathDiff
//

import Foundation

/// Writes differences in the unified diff format used by `git diff`, so a patch can be
/// reviewed elsewhere or applied with `git apply` / `patch -p1` (left = old, right = new).
nonisolated enum PatchBuilder {
    static let contextLines = 3

    /// The unified diff of one text file. Returns an empty string when nothing differs.
    static func unifiedDiff(oldPath: String?, newPath: String?, diff: TextDiff, rename: Bool = false) -> String {
        let headerOld = oldPath ?? newPath ?? ""
        let headerNew = newPath ?? oldPath ?? ""
        var lines = ["diff --git a/\(headerOld) b/\(headerNew)"]
        if oldPath == nil {
            lines.append("new file mode 100644")
        } else if newPath == nil {
            lines.append("deleted file mode 100644")
        } else if rename && oldPath != newPath {
            lines.append("similarity index \(diff.hunks.isEmpty ? 100 : 90)%")
            lines.append("rename from \(headerOld)")
            lines.append("rename to \(headerNew)")
        }
        guard !diff.hunks.isEmpty else {
            return rename || oldPath == nil || newPath == nil ? lines.joined(separator: "\n") + "\n" : ""
        }
        lines.append(oldPath.map { "--- a/\($0)" } ?? "--- /dev/null")
        lines.append(newPath.map { "+++ b/\($0)" } ?? "+++ /dev/null")

        let leftCount = diff.left?.lines.count ?? 0
        let rightCount = diff.right?.lines.count ?? 0
        let leftMissingNewline = !(diff.left?.hasTrailingNewline ?? true)
        let rightMissingNewline = !(diff.right?.hasTrailingNewline ?? true)

        // Lines of each side that come before each row, for the `@@` headers.
        var leftBefore = [0]
        var rightBefore = [0]
        leftBefore.reserveCapacity(diff.lines.count + 1)
        rightBefore.reserveCapacity(diff.lines.count + 1)
        for line in diff.lines {
            leftBefore.append(leftBefore[leftBefore.count - 1] + (line.leftContent == nil ? 0 : 1))
            rightBefore.append(rightBefore[rightBefore.count - 1] + (line.rightContent == nil ? 0 : 1))
        }

        for group in hunkGroups(diff) {
            let oldCount = leftBefore[group.upperBound] - leftBefore[group.lowerBound]
            let newCount = rightBefore[group.upperBound] - rightBefore[group.lowerBound]
            // An empty range is addressed by the line before it.
            let oldStart = leftBefore[group.lowerBound] + (oldCount == 0 ? 0 : 1)
            let newStart = rightBefore[group.lowerBound] + (newCount == 0 ? 0 : 1)
            lines.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")

            var row = group.lowerBound
            while row < group.upperBound {
                let line = diff.lines[row]
                guard let hunkIndex = line.hunkIndex else {
                    lines.append(" " + (line.leftContent ?? ""))
                    if line.leftLineNumber == leftCount && leftMissingNewline && line.rightLineNumber == rightCount && rightMissingNewline {
                        lines.append("\\ No newline at end of file")
                    }
                    row += 1
                    continue
                }
                let hunk = diff.hunks[hunkIndex]
                let rows = diff.lines[hunk.rowRange]
                for removed in rows where removed.leftContent != nil {
                    lines.append("-" + (removed.leftContent ?? ""))
                    if removed.leftLineNumber == leftCount && leftMissingNewline { lines.append("\\ No newline at end of file") }
                }
                for added in rows where added.rightContent != nil {
                    lines.append("+" + (added.rightContent ?? ""))
                    if added.rightLineNumber == rightCount && rightMissingNewline { lines.append("\\ No newline at end of file") }
                }
                row = hunk.rowRange.upperBound
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Row ranges to print: each change with its context, merging changes that are close.
    static func hunkGroups(_ diff: TextDiff) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        for hunk in diff.hunks {
            let start = max(0, hunk.rowRange.lowerBound - contextLines)
            let end = min(diff.lines.count, hunk.rowRange.upperBound + contextLines)
            if let last = groups.last, start <= last.upperBound {
                groups[groups.count - 1] = last.lowerBound..<max(last.upperBound, end)
            } else {
                groups.append(start..<end)
            }
        }
        return groups
    }

    /// The patch line for a binary file pair.
    static func binaryNotice(oldPath: String?, newPath: String?) -> String {
        let old = oldPath ?? newPath ?? ""
        let new = newPath ?? oldPath ?? ""
        return "diff --git a/\(old) b/\(new)\nBinary files \(oldPath.map { "a/\($0)" } ?? "/dev/null") and \(newPath.map { "b/\($0)" } ?? "/dev/null") differ\n"
    }

    /// One entry of a whole-comparison patch.
    nonisolated struct Entry: Sendable {
        let oldPath: String?
        let newPath: String?
        let leftURL: URL?
        let rightURL: URL?
        let isRename: Bool
    }

    /// Builds a patch for many files, reading them off the main actor.
    @concurrent
    static func patch(for entries: [Entry], options: DiffOptions) async throws -> String {
        var output = ""
        for entry in entries {
            try Task.checkCancellation()
            let leftData = try entry.leftURL.map { try Data(contentsOf: $0) }
            let rightData = try entry.rightURL.map { try Data(contentsOf: $0) }
            let leftDocument = leftData.flatMap(TextDocument.decode)
            let rightDocument = rightData.flatMap(TextDocument.decode)
            if (leftData != nil && leftDocument == nil) || (rightData != nil && rightDocument == nil) {
                if leftData != rightData { output += binaryNotice(oldPath: entry.oldPath, newPath: entry.newPath) }
                continue
            }
            let diff = DiffEngine.makeTextDiff(left: leftDocument, right: rightDocument, options: options)
            output += unifiedDiff(oldPath: entry.oldPath, newPath: entry.newPath, diff: diff, rename: entry.isRename)
        }
        return output
    }
}

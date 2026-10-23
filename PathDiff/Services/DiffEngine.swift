//
//  DiffEngine.swift
//  PathDiff
//

import Foundation
import UniformTypeIdentifiers

/// Loads two files and produces the side-by-side diff for the detail pane.
nonisolated enum DiffEngine {
    /// Files larger than this are not loaded into the text diff view.
    static let maximumTextFileSize: Int64 = 32 * 1024 * 1024
    /// Lines longer than this skip word-level highlighting.
    static let maximumIntraLineLength = 2_000
    /// Word-level highlights are only shown when at least this share of a line is unchanged.
    static let minimumIntraLineSimilarity = 0.35

    @concurrent
    static func computeDiff(for node: DiffNode, options: DiffOptions, highlightSyntax: Bool = false) async -> FileDiffContent {
        if node.status == .ignored { return .ignored }
        if node.hasKindMismatch { return .typeMismatch }
        if node.isDirectory { return .directory }
        if node.isSymlink {
            return .symlink(left: node.leftMetadata?.symlinkDestination, right: node.rightMetadata?.symlinkDestination)
        }

        let leftSize = node.leftMetadata?.size
        let rightSize = node.rightMetadata?.size
        // Photos, videos and audio open in their own views, which read only what they need,
        // so large files (a RAW photo, an hour of video) are never loaded whole here.
        if let kind = MediaKind(path: node.relativePath) {
            let existingLeft = node.leftURL == nil ? nil : leftSize
            let existingRight = node.rightURL == nil ? nil : rightSize
            let identical = node.status == .identical
            if kind == .image {
                return .binary(BinaryComparison(leftSize: existingLeft, rightSize: existingRight, areIdentical: identical, isImage: true))
            }
            return .media(MediaComparison(kind: kind, leftSize: existingLeft, rightSize: existingRight, areIdentical: identical))
        }
        if (leftSize ?? 0) > maximumTextFileSize || (rightSize ?? 0) > maximumTextFileSize {
            return .tooLarge(leftSize: leftSize, rightSize: rightSize)
        }

        do {
            let leftData = try node.leftURL.map { try Data(contentsOf: $0) }
            let rightData = try node.rightURL.map { try Data(contentsOf: $0) }
            try Task.checkCancellation()

            let leftDocument = leftData.flatMap(TextDocument.decode)
            let rightDocument = rightData.flatMap(TextDocument.decode)
            let leftIsBinary = leftData != nil && leftDocument == nil
            let rightIsBinary = rightData != nil && rightDocument == nil
            if leftIsBinary || rightIsBinary {
                return .binary(BinaryComparison(
                    leftSize: leftData.map { Int64($0.count) },
                    rightSize: rightData.map { Int64($0.count) },
                    areIdentical: leftData == rightData,
                    isImage: isImage(node.relativePath)
                ))
            }

            var diff = makeTextDiff(left: leftDocument, right: rightDocument, options: options)
            try Task.checkCancellation()
            if highlightSyntax, let language = SyntaxLanguage.detect(path: node.relativePath),
               max(leftSize ?? 0, rightSize ?? 0) <= SyntaxLanguage.maximumHighlightedBytes {
                diff.leftSyntax = leftDocument.map { SyntaxHighlighter.highlight($0, language: language) }
                diff.rightSyntax = rightDocument.map { SyntaxHighlighter.highlight($0, language: language) }
            }
            return .text(diff)
        } catch is CancellationError {
            return .none
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Images, plus PDFs and SVGs, which are shown with the visual image comparison.
    static func isImage(_ path: String) -> Bool {
        let fileExtension = (path as NSString).pathExtension
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    // MARK: Line diff

    /// The string each line is compared by.
    static func comparisonKey(for line: String, options: DiffOptions) -> String {
        guard options.ignoreWhitespace else { return line }
        var scalars = String.UnicodeScalarView()
        for scalar in line.unicodeScalars where !scalar.properties.isWhitespace {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    static func comparisonKeys(for lines: [String], options: DiffOptions) -> [String] {
        lines.map { comparisonKey(for: $0, options: options) }
    }

    static func makeTextDiff(left: TextDocument?, right: TextDocument?, options: DiffOptions) -> TextDiff {
        let leftLines = left?.lines ?? []
        let rightLines = right?.lines ?? []

        var symbols: [String: Int] = [:]
        func symbol(for line: String) -> Int {
            let key = comparisonKey(for: line, options: options)
            if let existing = symbols[key] { return existing }
            let next = symbols.count
            symbols[key] = next
            return next
        }
        let leftSymbols = leftLines.map(symbol(for:))
        let rightSymbols = rightLines.map(symbol(for:))
        let runs = MyersDiff.diff(leftSymbols, rightSymbols)

        var rows: [LineDiff] = []
        rows.reserveCapacity(max(leftLines.count, rightLines.count))
        var hunks: [DiffHunk] = []
        var leftIndex = 0
        var rightIndex = 0
        var runIndex = 0

        while runIndex < runs.count {
            let run = runs[runIndex]
            if run.operation == .equal {
                for offset in 0..<run.count {
                    rows.append(LineDiff(
                        id: rows.count,
                        leftLineNumber: leftIndex + offset + 1,
                        rightLineNumber: rightIndex + offset + 1,
                        leftContent: leftLines[leftIndex + offset],
                        rightContent: rightLines[rightIndex + offset],
                        type: .unchanged,
                        hunkIndex: nil
                    ))
                }
                leftIndex += run.count
                rightIndex += run.count
                runIndex += 1
                continue
            }

            // Gather the whole change region between two equal runs.
            var deleted = 0
            var inserted = 0
            while runIndex < runs.count, runs[runIndex].operation != .equal {
                if runs[runIndex].operation == .delete {
                    deleted += runs[runIndex].count
                } else {
                    inserted += runs[runIndex].count
                }
                runIndex += 1
            }

            let hunkIndex = hunks.count
            let firstRow = rows.count
            let pairs = alignChangedLines(
                Array(leftLines[leftIndex..<(leftIndex + deleted)]),
                Array(rightLines[rightIndex..<(rightIndex + inserted)]),
                options: options
            )
            for (leftOffset, rightOffset) in pairs {
                let left = leftOffset.map { leftIndex + $0 }
                let right = rightOffset.map { rightIndex + $0 }
                let type: LineDiffType = left != nil && right != nil ? .modified : (left != nil ? .deleted : .added)
                var row = LineDiff(
                    id: rows.count,
                    leftLineNumber: left.map { $0 + 1 },
                    rightLineNumber: right.map { $0 + 1 },
                    leftContent: left.map { leftLines[$0] },
                    rightContent: right.map { rightLines[$0] },
                    type: type,
                    hunkIndex: hunkIndex
                )
                if let left, let right, let highlights = intraLineHighlights(leftLines[left], rightLines[right]) {
                    row.leftHighlights = highlights.left
                    row.rightHighlights = highlights.right
                }
                rows.append(row)
            }
            hunks.append(DiffHunk(
                id: hunkIndex,
                leftRange: leftIndex..<(leftIndex + deleted),
                rightRange: rightIndex..<(rightIndex + inserted),
                rowRange: firstRow..<rows.count
            ))
            leftIndex += deleted
            rightIndex += inserted
        }

        return TextDiff(left: left, right: right, options: options, lines: rows, hunks: hunks)
    }

    // MARK: Row alignment

    /// Lines at least this similar are placed on the same row inside a change block.
    static let minimumPairSimilarity = 0.5
    /// Blocks larger than this (deleted × inserted lines) are paired positionally.
    static let maximumAlignmentCells = 40_000

    /// Lays out one change block as side-by-side rows of (old offset, new offset).
    ///
    /// Similar lines are anchored onto the same row using an order-preserving best match
    /// (a small LCS-style dynamic program over line similarity); the lines between anchors
    /// are paired positionally.
    static func alignChangedLines(_ old: [String], _ new: [String], options: DiffOptions) -> [(Int?, Int?)] {
        var anchors: [(Int, Int)] = []
        if !old.isEmpty, !new.isEmpty, old.count * new.count <= maximumAlignmentCells {
            let similarityOptions = DiffOptions(ignoreWhitespace: true)
            // Very long lines (minified code) aren't paired by similarity: comparing their
            // bigrams for every cell would take minutes.
            func lineBigrams(_ line: String) -> [Int: Int]? {
                line.utf8.count <= maximumIntraLineLength ? bigrams(comparisonKey(for: line, options: similarityOptions)) : nil
            }
            let oldBigrams = old.map(lineBigrams)
            let newBigrams = new.map(lineBigrams)
            let columns = new.count + 1
            var score = [Double](repeating: 0, count: (old.count + 1) * columns)
            for i in 1...old.count {
                for j in 1...new.count {
                    var best = max(score[(i - 1) * columns + j], score[i * columns + j - 1])
                    var similarity = 0.0
                    if let oldLine = oldBigrams[i - 1], let newLine = newBigrams[j - 1] {
                        similarity = diceCoefficient(oldLine, newLine)
                    }
                    if similarity >= minimumPairSimilarity {
                        best = max(best, score[(i - 1) * columns + j - 1] + similarity)
                    }
                    score[i * columns + j] = best
                }
            }
            var i = old.count
            var j = new.count
            while i > 0, j > 0 {
                let current = score[i * columns + j]
                if current == score[(i - 1) * columns + j] {
                    i -= 1
                } else if current == score[i * columns + j - 1] {
                    j -= 1
                } else {
                    anchors.append((i - 1, j - 1))
                    i -= 1
                    j -= 1
                }
            }
            anchors.reverse()
        }

        var rows: [(Int?, Int?)] = []
        rows.reserveCapacity(max(old.count, new.count))
        var oldCursor = 0
        var newCursor = 0
        func appendGap(upToOld oldEnd: Int, new newEnd: Int) {
            let oldGap = oldEnd - oldCursor
            let newGap = newEnd - newCursor
            for offset in 0..<max(oldGap, newGap) {
                rows.append((offset < oldGap ? oldCursor + offset : nil, offset < newGap ? newCursor + offset : nil))
            }
        }
        for (oldAnchor, newAnchor) in anchors {
            appendGap(upToOld: oldAnchor, new: newAnchor)
            rows.append((oldAnchor, newAnchor))
            oldCursor = oldAnchor + 1
            newCursor = newAnchor + 1
        }
        appendGap(upToOld: old.count, new: new.count)
        return rows
    }

    /// Multiset of adjacent scalar pairs, used for a cheap line-similarity measure.
    static func bigrams(_ text: String) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var previous: UInt32?
        for scalar in text.unicodeScalars {
            if let previous {
                result[Int(previous) << 21 | Int(scalar.value), default: 0] += 1
            }
            previous = scalar.value
        }
        if result.isEmpty, let previous {
            result[Int(previous), default: 0] = 1
        }
        return result
    }

    static func diceCoefficient(_ lhs: [Int: Int], _ rhs: [Int: Int]) -> Double {
        let lhsTotal = lhs.values.reduce(0, +)
        let rhsTotal = rhs.values.reduce(0, +)
        guard lhsTotal + rhsTotal > 0 else { return 1 }
        var shared = 0
        for (gram, count) in lhs {
            shared += min(count, rhs[gram] ?? 0)
        }
        return Double(2 * shared) / Double(lhsTotal + rhsTotal)
    }

    // MARK: Word-level highlights

    /// Character ranges that differ between two versions of a line, or `nil` when the lines
    /// are too different (or too long) for word highlighting to be useful.
    static func intraLineHighlights(_ old: String, _ new: String) -> (left: [Range<Int>], right: [Range<Int>])? {
        let oldLength = old.count
        let newLength = new.count
        guard oldLength <= maximumIntraLineLength, newLength <= maximumIntraLineLength else { return nil }
        guard oldLength > 0, newLength > 0 else { return nil }

        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        var symbols: [Substring: Int] = [:]
        func symbol(for token: Substring) -> Int {
            if let existing = symbols[token] { return existing }
            let next = symbols.count
            symbols[token] = next
            return next
        }
        let runs = MyersDiff.diff(oldTokens.map(symbol(for:)), newTokens.map(symbol(for:)), budget: 250_000)

        var leftRanges: [Range<Int>] = []
        var rightRanges: [Range<Int>] = []
        var oldIndex = 0
        var newIndex = 0
        var oldOffset = 0
        var newOffset = 0
        var unchangedCharacters = 0

        func append(_ range: Range<Int>, to ranges: inout [Range<Int>]) {
            guard !range.isEmpty else { return }
            if let last = ranges.last, last.upperBound == range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }

        for run in runs {
            switch run.operation {
            case .equal:
                for _ in 0..<run.count {
                    let length = oldTokens[oldIndex].count
                    unchangedCharacters += length
                    oldOffset += length
                    newOffset += newTokens[newIndex].count
                    oldIndex += 1
                    newIndex += 1
                }
            case .delete:
                let start = oldOffset
                for _ in 0..<run.count {
                    oldOffset += oldTokens[oldIndex].count
                    oldIndex += 1
                }
                append(start..<oldOffset, to: &leftRanges)
            case .insert:
                let start = newOffset
                for _ in 0..<run.count {
                    newOffset += newTokens[newIndex].count
                    newIndex += 1
                }
                append(start..<newOffset, to: &rightRanges)
            }
        }

        let similarity = Double(unchangedCharacters) / Double(max(oldLength, newLength))
        guard similarity >= minimumIntraLineSimilarity else { return nil }
        return (leftRanges, rightRanges)
    }

    /// Splits a line into identifier runs, whitespace runs and single punctuation characters.
    static func tokenize(_ text: String) -> [Substring] {
        var tokens: [Substring] = []
        var start = text.startIndex
        var currentClass: Int?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let characterClass: Int
            if character.isLetter || character.isNumber || character == "_" {
                characterClass = 0
            } else if character.isWhitespace {
                characterClass = 1
            } else {
                characterClass = 2
            }
            if let currentClass, currentClass != characterClass || characterClass == 2 {
                tokens.append(text[start..<index])
                start = index
            }
            currentClass = characterClass
            index = text.index(after: index)
        }
        if start < text.endIndex {
            tokens.append(text[start...])
        }
        return tokens
    }
}

// MARK: - Myers diff

/// Eugene Myers' O(ND) difference algorithm, using the linear-space "middle snake"
/// bisection so memory stays proportional to the input size.
///
/// Inputs are sequences of integer symbols (interned lines or tokens). A work budget bounds
/// pathological inputs: once it is exhausted, remaining sub-problems are reported as a plain
/// replacement, which is still a correct (if less minimal) edit script.
nonisolated enum MyersDiff {
    enum Operation: Sendable, Equatable {
        case equal
        case delete
        case insert
    }

    struct Run: Sendable, Equatable {
        var operation: Operation
        var count: Int
    }

    static func diff(_ a: [Int], _ b: [Int], budget: Int = 40_000_000) -> [Run] {
        var state = State(a: a, b: b, budget: budget)
        state.compute(aLow: 0, aHigh: a.count, bLow: 0, bHigh: b.count)
        return state.runs
    }

    private struct State {
        let a: [Int]
        let b: [Int]
        var budget: Int
        var runs: [Run] = []

        mutating func append(_ operation: Operation, _ count: Int) {
            guard count > 0 else { return }
            if let last = runs.last, last.operation == operation {
                runs[runs.count - 1].count += count
            } else {
                runs.append(Run(operation: operation, count: count))
            }
        }

        mutating func compute(aLow: Int, aHigh: Int, bLow: Int, bHigh: Int) {
            var aLow = aLow, aHigh = aHigh, bLow = bLow, bHigh = bHigh

            var prefix = 0
            while aLow < aHigh, bLow < bHigh, a[aLow] == b[bLow] {
                aLow += 1
                bLow += 1
                prefix += 1
            }
            append(.equal, prefix)

            var suffix = 0
            while aLow < aHigh, bLow < bHigh, a[aHigh - 1] == b[bHigh - 1] {
                aHigh -= 1
                bHigh -= 1
                suffix += 1
            }

            if aLow == aHigh {
                append(.insert, bHigh - bLow)
            } else if bLow == bHigh {
                append(.delete, aHigh - aLow)
            } else if let (x, y) = bisect(aLow: aLow, aHigh: aHigh, bLow: bLow, bHigh: bHigh) {
                compute(aLow: aLow, aHigh: x, bLow: bLow, bHigh: y)
                compute(aLow: x, aHigh: aHigh, bLow: y, bHigh: bHigh)
            } else {
                append(.delete, aHigh - aLow)
                append(.insert, bHigh - bLow)
            }

            append(.equal, suffix)
        }

        /// Finds the middle snake and returns the split point (absolute indices), or `nil`
        /// when the sequences share nothing or the work budget is exhausted.
        mutating func bisect(aLow: Int, aHigh: Int, bLow: Int, bHigh: Int) -> (Int, Int)? {
            let n = aHigh - aLow
            let m = bHigh - bLow
            let maxD = (n + m + 1) / 2
            let offset = maxD
            let length = 2 * maxD + 2
            var forward = [Int](repeating: -1, count: length)
            var reverse = [Int](repeating: -1, count: length)
            forward[offset + 1] = 0
            reverse[offset + 1] = 0
            let delta = n - m
            let deltaIsOdd = delta % 2 != 0
            var forwardStart = 0, forwardEnd = 0
            var reverseStart = 0, reverseEnd = 0

            for d in 0..<maxD {
                budget -= 2 * d + 2
                if budget < 0 { return nil }

                var k1 = -d + forwardStart
                while k1 <= d - forwardEnd {
                    let k1Offset = offset + k1
                    var x1 = (k1 == -d || (k1 != d && forward[k1Offset - 1] < forward[k1Offset + 1]))
                        ? forward[k1Offset + 1]
                        : forward[k1Offset - 1] + 1
                    var y1 = x1 - k1
                    while x1 < n, y1 < m, a[aLow + x1] == b[bLow + y1] {
                        x1 += 1
                        y1 += 1
                    }
                    forward[k1Offset] = x1
                    if x1 > n {
                        forwardEnd += 2
                    } else if y1 > m {
                        forwardStart += 2
                    } else if deltaIsOdd {
                        let k2Offset = offset + delta - k1
                        if k2Offset >= 0, k2Offset < length, reverse[k2Offset] != -1 {
                            let x2 = n - reverse[k2Offset]
                            if x1 >= x2 { return (aLow + x1, bLow + y1) }
                        }
                    }
                    k1 += 2
                }

                var k2 = -d + reverseStart
                while k2 <= d - reverseEnd {
                    let k2Offset = offset + k2
                    var x2 = (k2 == -d || (k2 != d && reverse[k2Offset - 1] < reverse[k2Offset + 1]))
                        ? reverse[k2Offset + 1]
                        : reverse[k2Offset - 1] + 1
                    var y2 = x2 - k2
                    while x2 < n, y2 < m, a[aHigh - x2 - 1] == b[bHigh - y2 - 1] {
                        x2 += 1
                        y2 += 1
                    }
                    reverse[k2Offset] = x2
                    if x2 > n {
                        reverseEnd += 2
                    } else if y2 > m {
                        reverseStart += 2
                    } else if !deltaIsOdd {
                        let k1Offset = offset + delta - k2
                        if k1Offset >= 0, k1Offset < length, forward[k1Offset] != -1 {
                            let x1 = forward[k1Offset]
                            let y1 = offset + x1 - k1Offset
                            if x1 >= n - x2 { return (aLow + x1, bLow + y1) }
                        }
                    }
                    k2 += 2
                }
            }
            return nil
        }
    }
}

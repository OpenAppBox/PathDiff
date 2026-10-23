//
//  DiffEngineTests.swift
//  PathDiffTests
//

import Foundation
import Testing

@Suite("Myers diff and line diff")
struct DiffEngineTests {
    /// Length of the longest common subsequence, by dynamic programming.
    private func lcsLength(_ a: [Int], _ b: [Int]) -> Int {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0..<a.count {
            for j in 0..<b.count {
                table[i + 1][j + 1] = a[i] == b[j] ? table[i][j] + 1 : max(table[i][j + 1], table[i + 1][j])
            }
        }
        return table[a.count][b.count]
    }

    @Test func editScriptIsValidAndMinimal() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<3_000 {
            let alphabet = Int.random(in: 1...5, using: &generator)
            let a = (0..<Int.random(in: 0...14, using: &generator)).map { _ in Int.random(in: 0..<alphabet, using: &generator) }
            let b = (0..<Int.random(in: 0...14, using: &generator)).map { _ in Int.random(in: 0..<alphabet, using: &generator) }
            let runs = MyersDiff.diff(a, b)

            var aIndex = 0, bIndex = 0, equalCount = 0
            var rebuilt: [Int] = []
            for run in runs {
                switch run.operation {
                case .equal:
                    for _ in 0..<run.count {
                        #expect(a[aIndex] == b[bIndex])
                        rebuilt.append(a[aIndex])
                        aIndex += 1
                        bIndex += 1
                        equalCount += 1
                    }
                case .delete:
                    aIndex += run.count
                case .insert:
                    rebuilt.append(contentsOf: b[bIndex..<(bIndex + run.count)])
                    bIndex += run.count
                }
            }
            #expect(aIndex == a.count && bIndex == b.count)
            #expect(rebuilt == b)
            #expect(equalCount == lcsLength(a, b), "not minimal for \(a) → \(b)")
        }
    }

    @Test func exhaustedBudgetStillProducesValidScript() {
        let a = (0..<2_000).map { _ in Int.random(in: 0..<40) }
        let b = (0..<2_000).map { _ in Int.random(in: 0..<40) }
        var aCount = 0, bCount = 0
        for run in MyersDiff.diff(a, b, budget: 500) {
            switch run.operation {
            case .equal: aCount += run.count; bCount += run.count
            case .delete: aCount += run.count
            case .insert: bCount += run.count
            }
        }
        #expect(aCount == a.count && bCount == b.count)
    }

    @Test func largeFileWithScatteredEditsIsFast() {
        let original = (0..<20_000).map { "line \($0) with some content" }
        var edited = original
        for index in stride(from: 100, to: 20_000, by: 397) { edited[index] = "changed \(index)" }
        let clock = ContinuousClock()
        let start = clock.now
        let diff = DiffEngine.makeTextDiff(
            left: TextDocument(text: original.joined(separator: "\n")),
            right: TextDocument(text: edited.joined(separator: "\n")),
            options: DiffOptions()
        )
        #expect(diff.hunks.count == 51)
        #expect(clock.now - start < .seconds(1))
    }

    @Test func everyLineAppearsOnceInOrder() {
        let words = ["let", "var", "x", "y", "return", "foo()", "}", "{", "", "// note"]
        func randomText() -> String {
            (0..<Int.random(in: 0...12)).map { _ in
                (0..<Int.random(in: 1...3)).map { _ in words.randomElement()! }.joined(separator: " ")
            }.joined(separator: "\n")
        }
        for _ in 0..<1_000 {
            let left = TextDocument(text: randomText())
            let right = TextDocument(text: randomText())
            let diff = DiffEngine.makeTextDiff(left: left, right: right, options: DiffOptions())
            #expect(diff.lines.compactMap(\.leftLineNumber) == Array(0..<left.lines.count).map { $0 + 1 })
            #expect(diff.lines.compactMap(\.rightLineNumber) == Array(0..<right.lines.count).map { $0 + 1 })
            for hunk in diff.hunks {
                let rows = diff.lines[hunk.rowRange]
                #expect(rows.compactMap(\.leftLineNumber).count == hunk.leftRange.count)
                #expect(rows.compactMap(\.rightLineNumber).count == hunk.rightRange.count)
            }
        }
    }

    @Test func similarLinesShareARow() {
        let diff = DiffEngine.makeTextDiff(
            left: TextDocument(text: "a\nvar email: String\nz"),
            right: TextDocument(text: "a\nlet isAdmin: Bool\nvar email: String?\nz"),
            options: DiffOptions()
        )
        let changed = diff.lines.filter { $0.type != .unchanged }
        #expect(changed.map(\.type) == [.added, .modified])
        #expect(changed[1].leftContent == "var email: String" && changed[1].rightContent == "var email: String?")
        #expect(changed[1].rightHighlights == [17..<18])
    }

    @Test func ignoringWhitespaceHidesWhitespaceOnlyChanges() {
        let left = TextDocument(text: "if (a)  {\n\treturn 1\n}\n")
        let right = TextDocument(text: "if (a) {\n    return 1\n}\n")
        #expect(DiffEngine.makeTextDiff(left: left, right: right, options: DiffOptions()).hunks.count == 1)
        #expect(DiffEngine.makeTextDiff(left: left, right: right, options: DiffOptions(ignoreWhitespace: true)).hunks.isEmpty)
    }

    @Test func naturalOrderSortsNumbersByValue() {
        let names = ["file10", "File2", "file1", "a", "B", "file02"]
        #expect(names.sorted(by: NaturalOrder.precedes) == ["a", "B", "file1", "File2", "file02", "file10"])
    }
}

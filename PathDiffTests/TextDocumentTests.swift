//
//  TextDocumentTests.swift
//  PathDiffTests
//

import Foundation
import Testing

@Suite("Text documents and block transfer")
struct TextDocumentTests {
    @Test(arguments: ["", "a", "a\n", "a\r\nb\r\n", "a\nb", "\n\n", "x\ry\r\nz\n", "é🙂\r\n\t tab\n"])
    func roundTripsExactly(_ text: String) throws {
        let document = TextDocument(text: text)
        #expect(document.text == text)
        let data = try document.encodedData()
        #expect(TextDocument.decode(data) == document)
    }

    @Test func preservesUTF16AndByteOrderMark() throws {
        let data = Data([0xFF, 0xFE]) + "hi\r\nyo".data(using: .utf16LittleEndian)!
        let document = try #require(TextDocument.decode(data))
        #expect(document.lines == ["hi", "yo"])
        #expect(document.terminators == [.crlf, .none])
        #expect(try document.encodedData() == data)
    }

    @Test func preservesUTF8ByteOrderMark() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("x\n".utf8)
        let document = try #require(TextDocument.decode(data))
        #expect(document.hasByteOrderMark)
        #expect(try document.encodedData() == data)
    }

    @Test func detectsBinaryContent() {
        #expect(TextDocument.decode(Data([0x41, 0x00, 0x42])) == nil)
        #expect(TextDocument.decode(Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00])) == nil)
    }

    /// Applies every hunk in one direction until the documents match.
    private func syncAll(_ left: String, _ right: String, leftToRight: Bool) -> (left: TextDocument, right: TextDocument) {
        var leftDocument = TextDocument(text: left)
        var rightDocument = TextDocument(text: right)
        while let hunk = DiffEngine.makeTextDiff(left: leftDocument, right: rightDocument, options: DiffOptions()).hunks.first {
            if leftToRight {
                rightDocument = rightDocument.replacingLines(hunk.rightRange, withLinesFrom: leftDocument, sourceRange: hunk.leftRange)
            } else {
                leftDocument = leftDocument.replacingLines(hunk.leftRange, withLinesFrom: rightDocument, sourceRange: hunk.rightRange)
            }
        }
        return (leftDocument, rightDocument)
    }

    @Test(arguments: [
        ("a\nb\nc\n", "a\nX\nc\n"),
        ("a\nb\nc", "a\nb\nc\nd\ne"),
        ("a\nb\nc\nd\n", "a\nb"),
        ("", "x\ny\n"),
        ("x\ny\n", ""),
        ("1\n2\n3", "0\n1\n3\n4\n"),
    ])
    func blockTransferConvergesWithTrailingNewlineFromSource(_ left: String, _ right: String) {
        let toRight = syncAll(left, right, leftToRight: true)
        #expect(toRight.right.text == left)
        let toLeft = syncAll(left, right, leftToRight: false)
        #expect(toLeft.left.text == right)
    }

    @Test func insertedLinesUseTheDestinationLineEnding() {
        let result = syncAll("a\r\nb\r\nc\r\n", "a\nZ\nc\nq\n", leftToRight: true)
        #expect(result.right.text == "a\nb\nc\n")
        let reverse = syncAll("a\r\nb\r\nc\r\n", "a\nZ\nc\nq\n", leftToRight: false)
        #expect(reverse.left.text == "a\r\nZ\r\nc\r\nq\r\n")
    }
}

//
//  TextDocument.swift
//  PathDiff
//

import Foundation

nonisolated enum LineTerminator: String, Sendable, Hashable {
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"
    case none = ""

    var displayName: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        case .none: String(localized: "None", comment: "Line ending: none")
        }
    }
}

nonisolated enum TextDocumentError: LocalizedError {
    case unencodable(String.Encoding)

    var errorDescription: String? {
        switch self {
        case .unencodable(let encoding):
            String(localized: "The text can’t be saved in the file’s encoding (\(String.localizedName(of: encoding))).")
        }
    }
}

/// A decoded text file that remembers everything needed to write it back byte-for-byte:
/// per-line terminators (so mixed line endings survive), encoding and byte-order mark.
nonisolated struct TextDocument: Sendable, Equatable {
    var lines: [String]
    /// One terminator per line; only the last line may have `.none`.
    var terminators: [LineTerminator]
    var encoding: String.Encoding
    var hasByteOrderMark: Bool

    static let empty = TextDocument(lines: [], terminators: [], encoding: .utf8, hasByteOrderMark: false)

    /// How many leading bytes are inspected when sniffing for binary content.
    static let binarySniffLength = 8_192

    var hasTrailingNewline: Bool {
        guard let last = terminators.last else { return false }
        return last != .none
    }

    /// The most common terminator, or `nil` for a document without any line breaks.
    var dominantTerminator: LineTerminator? {
        var counts: [LineTerminator: Int] = [:]
        for terminator in terminators where terminator != .none {
            counts[terminator, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    // MARK: Decoding

    static func isBinary(_ data: Data) -> Bool {
        data.prefix(binarySniffLength).contains(0)
    }

    /// Decodes text, returning `nil` for binary content.
    static func decode(_ data: Data) -> TextDocument? {
        let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
        let utf16LEBOM: [UInt8] = [0xFF, 0xFE]
        let utf16BEBOM: [UInt8] = [0xFE, 0xFF]

        // A NUL code unit after decoding means a binary file that happens to start like a BOM.
        if data.starts(with: utf16LEBOM), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian),
           !text.unicodeScalars.contains("\0") {
            return TextDocument(text: text, encoding: .utf16LittleEndian, hasByteOrderMark: true)
        }
        if data.starts(with: utf16BEBOM), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian),
           !text.unicodeScalars.contains("\0") {
            return TextDocument(text: text, encoding: .utf16BigEndian, hasByteOrderMark: true)
        }
        if isBinary(data) { return nil }
        if data.starts(with: utf8BOM), let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return TextDocument(text: text, encoding: .utf8, hasByteOrderMark: true)
        }
        if let text = String(data: data, encoding: .utf8) {
            return TextDocument(text: text, encoding: .utf8, hasByteOrderMark: false)
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return TextDocument(text: text, encoding: .windowsCP1252, hasByteOrderMark: false)
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return TextDocument(text: text, encoding: .isoLatin1, hasByteOrderMark: false)
        }
        return nil
    }

    init(lines: [String], terminators: [LineTerminator], encoding: String.Encoding, hasByteOrderMark: Bool) {
        self.lines = lines
        self.terminators = terminators
        self.encoding = encoding
        self.hasByteOrderMark = hasByteOrderMark
    }

    init(text: String, encoding: String.Encoding = .utf8, hasByteOrderMark: Bool = false) {
        let parsed = Self.parseLines(text)
        self.init(lines: parsed.lines, terminators: parsed.terminators, encoding: encoding, hasByteOrderMark: hasByteOrderMark)
    }

    /// Splits on `\n`, `\r\n` and `\r` only, so other control characters round-trip untouched.
    static func parseLines(_ text: String) -> (lines: [String], terminators: [LineTerminator]) {
        var text = text
        text.makeContiguousUTF8()
        var lines: [String] = []
        var terminators: [LineTerminator] = []
        let utf8 = text.utf8
        var lineStart = utf8.startIndex
        var index = utf8.startIndex

        while index < utf8.endIndex {
            let byte = utf8[index]
            guard byte == 0x0A || byte == 0x0D else {
                index = utf8.index(after: index)
                continue
            }
            lines.append(String(text[lineStart..<index]))
            var next = utf8.index(after: index)
            if byte == 0x0D, next < utf8.endIndex, utf8[next] == 0x0A {
                terminators.append(.crlf)
                next = utf8.index(after: next)
            } else {
                terminators.append(byte == 0x0A ? .lf : .cr)
            }
            lineStart = next
            index = next
        }
        if lineStart < utf8.endIndex {
            lines.append(String(text[lineStart...]))
            terminators.append(.none)
        }
        return (lines, terminators)
    }

    // MARK: Encoding

    var text: String {
        var result = ""
        result.reserveCapacity(lines.reduce(0) { $0 + $1.utf8.count + 2 })
        for (line, terminator) in zip(lines, terminators) {
            result += line
            result += terminator.rawValue
        }
        return result
    }

    func encodedData() throws -> Data {
        guard let body = text.data(using: encoding, allowLossyConversion: false) else {
            throw TextDocumentError.unencodable(encoding)
        }
        guard hasByteOrderMark else { return body }
        let bom: [UInt8] = switch encoding {
        case .utf8: [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian: [0xFF, 0xFE]
        case .utf16BigEndian: [0xFE, 0xFF]
        default: []
        }
        return Data(bom) + body
    }

    // MARK: Editing

    /// Returns a copy where `range` is replaced by `sourceRange` of `source`.
    ///
    /// Inserted lines adopt this document's dominant line ending. When the edit reaches the
    /// end of both documents, the presence of a trailing newline follows the source.
    func replacingLines(_ range: Range<Int>, withLinesFrom source: TextDocument, sourceRange: Range<Int>) -> TextDocument {
        let lineEnding = dominantTerminator ?? source.dominantTerminator ?? .lf
        let insertedLines = Array(source.lines[sourceRange])
        let wantsTrailingNewline: Bool
        if range.upperBound == lines.count {
            wantsTrailingNewline = sourceRange.upperBound == source.lines.count
                ? source.hasTrailingNewline
                : hasTrailingNewline
        } else {
            wantsTrailingNewline = hasTrailingNewline
        }

        var result = self
        result.lines.replaceSubrange(range, with: insertedLines)
        result.terminators.replaceSubrange(range, with: Array(repeating: lineEnding, count: insertedLines.count))

        guard !result.lines.isEmpty else { return result }
        // Every line except the last must end with a line break.
        for index in result.terminators.indices.dropLast() where result.terminators[index] == .none {
            result.terminators[index] = lineEnding
        }
        let last = result.terminators.count - 1
        if !wantsTrailingNewline {
            result.terminators[last] = .none
        } else if result.terminators[last] == .none {
            result.terminators[last] = lineEnding
        }
        return result
    }
}

// MARK: - Editing

extension TextDocument {
    /// The text shown in an editor: lines joined with `\n`, whatever the file uses.
    var editorText: String {
        var result = lines.joined(separator: "\n")
        if hasTrailingNewline { result += "\n" }
        return result
    }

    /// A document with edited text, keeping this document's encoding, byte-order mark and
    /// line endings: new and edited lines get the dominant line ending, and in a file that
    /// mixes them, unchanged lines keep their own.
    func replacingText(_ text: String) -> TextDocument {
        let parsed = Self.parseLines(text)
        let lineEnding = dominantTerminator ?? parsed.terminators.first { $0 != .none } ?? .lf
        var terminators = Array(repeating: lineEnding, count: parsed.lines.count)
        if Set(self.terminators.filter { $0 != .none }).count > 1 {
            var symbols: [String: Int] = [:]
            func symbol(_ line: String) -> Int {
                if let existing = symbols[line] { return existing }
                symbols[line] = symbols.count
                return symbols.count - 1
            }
            let old = lines.map(symbol)
            let new = parsed.lines.map(symbol)
            var oldIndex = 0, newIndex = 0
            for run in MyersDiff.diff(old, new) {
                switch run.operation {
                case .equal:
                    for offset in 0..<run.count where self.terminators[oldIndex + offset] != .none {
                        terminators[newIndex + offset] = self.terminators[oldIndex + offset]
                    }
                    oldIndex += run.count
                    newIndex += run.count
                case .delete:
                    oldIndex += run.count
                case .insert:
                    newIndex += run.count
                }
            }
        }
        if let last = parsed.terminators.last, last == .none, !terminators.isEmpty {
            terminators[terminators.count - 1] = .none
        }
        return TextDocument(lines: parsed.lines, terminators: terminators, encoding: encoding, hasByteOrderMark: hasByteOrderMark)
    }
}

extension String.Encoding {
    nonisolated var shortName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .windowsCP1252: "Windows-1252"
        case .isoLatin1: "ISO Latin 1"
        default: String.localizedName(of: self)
        }
    }
}

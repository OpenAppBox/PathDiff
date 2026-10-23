//
//  EditAnalysis.swift
//  PathDiff
//

import Foundation

/// Live comparison of the text being edited: which lines differ on each side, and syntax
/// colors, computed off the main actor after each pause in typing.
nonisolated struct EditAnalysis: Sendable {
    /// Zero-based line indices that differ from the other side.
    var leftChangedLines = IndexSet()
    var rightChangedLines = IndexSet()
    var changeCount = 0
    var leftSyntax: SyntaxHighlights?
    var rightSyntax: SyntaxHighlights?

    /// Above this size, editors show no syntax colors (they would lag behind typing).
    static let maximumHighlightedCharacters = 1_000_000

    @concurrent
    static func analyze(left: String?, right: String?, options: DiffOptions, language: SyntaxLanguage?) async -> EditAnalysis {
        let leftDocument = left.map { TextDocument(text: $0) }
        let rightDocument = right.map { TextDocument(text: $0) }
        var analysis = EditAnalysis()
        if let leftDocument, let rightDocument {
            let diff = DiffEngine.makeTextDiff(left: leftDocument, right: rightDocument, options: options)
            for line in diff.lines where line.type != .unchanged {
                if let number = line.leftLineNumber { analysis.leftChangedLines.insert(number - 1) }
                if let number = line.rightLineNumber { analysis.rightChangedLines.insert(number - 1) }
            }
            analysis.changeCount = diff.hunks.count
        }
        if let language {
            if let leftDocument, (left?.utf16.count ?? 0) <= maximumHighlightedCharacters {
                analysis.leftSyntax = SyntaxHighlighter.highlight(leftDocument, language: language)
            }
            if let rightDocument, (right?.utf16.count ?? 0) <= maximumHighlightedCharacters {
                analysis.rightSyntax = SyntaxHighlighter.highlight(rightDocument, language: language)
            }
        }
        return analysis
    }
}

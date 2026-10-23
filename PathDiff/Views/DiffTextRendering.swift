//
//  DiffTextRendering.swift
//  PathDiff
//

import AppKit
import SwiftUI

/// Syntax colors that follow the system appearance (Xcode-like defaults).
enum SyntaxPalette {
    static func color(for kind: SyntaxKind) -> Color {
        colors[Int(kind.rawValue)]
    }

    /// The same colors for AppKit text views.
    static func nsColor(for kind: SyntaxKind) -> NSColor {
        nsColors[Int(kind.rawValue)]
    }

    private static let nsColors: [NSColor] = [
        dynamic(light: 0xAD3DA4, dark: 0xFF7AB2),   // keyword
        dynamic(light: 0x0B6E7E, dark: 0x5DD8FF),   // type
        dynamic(light: 0xC41A16, dark: 0xFF8170),   // string
        dynamic(light: 0x1C00CF, dark: 0xD9C97C),   // number
        dynamic(light: 0x6C7986, dark: 0x7F8C98),   // comment
        dynamic(light: 0x815F03, dark: 0xFFA14F),   // attribute
        dynamic(light: 0x1C64B8, dark: 0x6BAFFF),   // tag
        dynamic(light: 0x326D74, dark: 0x67B7A4),   // property
        dynamic(light: 0x643820, dark: 0xFD8F3F),   // preprocessor
    ]

    private static let colors: [Color] = nsColors.map { Color(nsColor: $0) }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        .adaptive(light: light, dark: dark)
    }
}

enum DiffTextRenderer {
    static let tabReplacement = "    "

    static func displayString<S: StringProtocol>(_ text: S) -> String {
        text.replacingOccurrences(of: "\t", with: tabReplacement)
    }

    /// Builds a line's text with tabs expanded, syntax colors applied and changed ranges
    /// highlighted. Ranges are in `Character` offsets.
    /// Longer lines (minified files) are cut off when shown: laying out megabytes of text in
    /// one row would stall the window. The comparison itself always uses the whole line.
    static let maximumDisplayedCharacters = 10_000

    static func attributed(_ content: String, highlights: [Range<Int>], highlightColor: Color, syntax: [SyntaxSpan] = []) -> AttributedString {
        guard !content.isEmpty else { return AttributedString(" ") }
        let content = content.utf8.count > maximumDisplayedCharacters
            ? String(content.prefix(maximumDisplayedCharacters)) + " …"
            : content
        guard !highlights.isEmpty || !syntax.isEmpty else { return AttributedString(displayString(content)) }

        let characters = Array(content)
        // Every position where the styling may change.
        var boundaries = Set([0, characters.count])
        for range in highlights {
            boundaries.insert(min(range.lowerBound, characters.count))
            boundaries.insert(min(range.upperBound, characters.count))
        }
        for span in syntax {
            boundaries.insert(min(span.range.lowerBound, characters.count))
            boundaries.insert(min(span.range.upperBound, characters.count))
        }
        let points = boundaries.sorted()

        var result = AttributedString()
        var highlightIndex = 0
        var syntaxIndex = 0
        for (start, end) in zip(points, points.dropFirst()) where end > start {
            var segment = AttributedString(displayString(String(characters[start..<end])))
            while highlightIndex < highlights.count, highlights[highlightIndex].upperBound <= start { highlightIndex += 1 }
            if highlightIndex < highlights.count, highlights[highlightIndex].contains(start) {
                segment.swiftUI.backgroundColor = highlightColor
            }
            while syntaxIndex < syntax.count, syntax[syntaxIndex].range.upperBound <= start { syntaxIndex += 1 }
            if syntaxIndex < syntax.count, syntax[syntaxIndex].range.contains(start) {
                segment.swiftUI.foregroundColor = SyntaxPalette.color(for: syntax[syntaxIndex].kind)
            }
            result += segment
        }
        return result
    }
}

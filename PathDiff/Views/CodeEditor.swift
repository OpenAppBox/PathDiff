//
//  CodeEditor.swift
//  PathDiff
//

import AppKit
import SwiftUI

/// A plain-text code editor for one side of the diff: monospaced, line numbers, changed
/// lines tinted across the full width, syntax colors, and scrolling kept in step with the
/// other side.
struct CodeEditor: NSViewRepresentable {
    let text: String
    /// Replace the editor's text only when this changes (load, revert, save normalization).
    let revision: Int
    /// Zero-based lines that differ from the other side.
    let changedLines: IndexSet
    let changeColor: NSColor
    let syntax: SyntaxHighlights?
    let analysisRevision: Int
    let fontSize: Double
    let scrollSync: EditorScrollSync
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> EditorContainerView {
        let container = EditorContainerView()
        let textView = container.textView
        textView.applyFont(size: fontSize)
        textView.string = text
        textView.recomputeLineStarts()
        textView.delegate = context.coordinator
        context.coordinator.revision = revision
        scrollSync.register(container.scrollView)
        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        let textView = container.textView
        let coordinator = context.coordinator
        coordinator.onChange = onChange
        if coordinator.revision != revision {
            coordinator.revision = revision
            textView.string = text
            textView.recomputeLineStarts()
        }
        textView.applyFont(size: fontSize)
        textView.changeColor = changeColor
        textView.changedLines = changedLines
        if coordinator.analysisRevision != analysisRevision {
            coordinator.analysisRevision = analysisRevision
            textView.applySyntax(syntax)
        }
        container.gutter.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        var revision = 0
        var analysisRevision = -1

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onChange(textView.string)
        }
    }
}

/// A line-number gutter beside a plain scroll view holding the text view. (A separate
/// gutter avoids `NSRulerView`'s floating-ruler offsets, which can slide text under it.)
final class EditorContainerView: NSView {
    let textView = EditorTextView(usingTextLayoutManager: false)
    let scrollView = NSScrollView()
    let gutter = LineNumberGutter()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        // Classic non-wrapping layout: fill at least the visible area, grow with the text.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.gutter = gutter

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // Both editors must use the same coordinates for synchronized scrolling.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewDidScroll(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        gutter.textView = textView
        addSubview(gutter)
        addSubview(scrollView)
    }

    @objc private func clipViewDidScroll(_ notification: Notification) {
        gutter.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let gutterWidth = gutter.preferredWidth
        gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height)
        textView.fillVisibleArea()
    }
}

/// The text view behind `CodeEditor`.
final class EditorTextView: NSTextView {
    weak var gutter: LineNumberGutter?

    var changedLines = IndexSet() {
        didSet {
            guard changedLines != oldValue else { return }
            needsDisplay = true
            gutter?.needsDisplay = true
        }
    }
    var changeColor = NSColor.systemRed.withAlphaComponent(0.13)
    /// UTF-16 offset where each line starts.
    private(set) var lineStarts: [Int] = [0]
    private var fontSize: Double = 0

    func applyFont(size: Double) {
        guard size != fontSize else { return }
        fontSize = size
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        self.font = font
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: font]).width
        defaultParagraphStyle = style
        typingAttributes = [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.textColor]
        if let storage = textStorage, storage.length > 0 {
            storage.addAttributes([.font: font, .paragraphStyle: style], range: NSRange(location: 0, length: storage.length))
        }
        gutterNeedsLayout()
    }

    /// Makes the text view cover the whole visible area (it only grows with the text).
    func fillVisibleArea() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let visible = clip.bounds.size
        if minSize != visible {
            minSize = visible
        }
        let size = NSSize(width: max(frame.width, visible.width), height: max(frame.height, visible.height))
        if frame.size != size {
            setFrameSize(size)
        }
    }

    func recomputeLineStarts() {
        let string = self.string as NSString
        let length = string.length
        var starts = [0]
        var buffer = [unichar](repeating: 0, count: 8_192)
        var location = 0
        while location < length {
            let count = min(buffer.count, length - location)
            string.getCharacters(&buffer, range: NSRange(location: location, length: count))
            for index in 0..<count where buffer[index] == 10 {
                starts.append(location + index + 1)
            }
            location += count
        }
        let digitsChanged = String(starts.count).count != String(lineStarts.count).count
        lineStarts = starts
        if digitsChanged { gutterNeedsLayout() }
        gutter?.needsDisplay = true
    }

    private func gutterNeedsLayout() {
        gutter?.superview?.needsLayout = true
        gutter?.needsDisplay = true
    }

    /// The zero-based line containing the UTF-16 offset.
    func lineIndex(forCharacter offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    override func didChangeText() {
        super.didChangeText()
        recomputeLineStarts()
    }

    /// The rectangle (in this view's coordinates) covering a whole line.
    func rect(forLine line: Int) -> NSRect? {
        guard let layoutManager, line < lineStarts.count else { return nil }
        let length = (string as NSString).length
        let start = lineStarts[line]
        var lineRect = NSRect.null
        if start >= length {
            lineRect = layoutManager.extraLineFragmentRect
            if lineRect.isEmpty { return nil }
        } else {
            let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: start, length: max(1, end - start)), actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                lineRect = lineRect.union(rect)
            }
        }
        guard !lineRect.isNull else { return nil }
        return lineRect.offsetBy(dx: 0, dy: textContainerOrigin.y)
    }

    /// The zero-based lines intersecting a rectangle of this view.
    func visibleLines(in rect: NSRect) -> ClosedRange<Int>? {
        guard let layoutManager, let textContainer else { return nil }
        let containerRect = rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = lineIndex(forCharacter: characters.location)
        let last = max(first, lineIndex(forCharacter: NSMaxRange(characters)))
        return first...last
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !changedLines.isEmpty, let lines = visibleLines(in: rect) else { return }
        changeColor.setFill()
        for line in changedLines[changedLines.indexRange(in: lines.lowerBound..<(lines.upperBound + 1))] {
            guard var lineRect = self.rect(forLine: line) else { continue }
            lineRect.origin.x = 0
            lineRect.size.width = bounds.width
            lineRect.fill()
        }
    }

    /// Colors tokens without touching the text storage (so undo and saving are unaffected).
    func applySyntax(_ syntax: SyntaxHighlights?) {
        guard let layoutManager else { return }
        let string = self.string as NSString
        let full = NSRange(location: 0, length: string.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        guard let syntax else { return }
        // The analysis must describe the current text line for line.
        let lineCount = string.hasSuffix("\n") ? lineStarts.count - 1 : lineStarts.count
        guard syntax.lines.count == lineCount else { return }
        for (line, spans) in syntax.lines.enumerated() where !spans.isEmpty {
            let start = lineStarts[line]
            let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : string.length
            let lineText = string.substring(with: NSRange(location: start, length: end - start))
            // Character offsets → UTF-16 offsets within the line.
            var offsets = [0]
            offsets.reserveCapacity(lineText.count + 1)
            for character in lineText { offsets.append(offsets[offsets.count - 1] + character.utf16.count) }
            for span in spans {
                let lower = offsets[min(span.range.lowerBound, offsets.count - 1)]
                let upper = offsets[min(span.range.upperBound, offsets.count - 1)]
                guard upper > lower else { continue }
                layoutManager.addTemporaryAttribute(.foregroundColor, value: SyntaxPalette.nsColor(for: span.kind), forCharacterRange: NSRange(location: start + lower, length: upper - lower))
            }
        }
    }
}

/// Line numbers for an `EditorTextView`, following its vertical scroll position; changed
/// lines get a colored mark.
final class LineNumberGutter: NSView {
    weak var textView: EditorTextView?

    override var isFlipped: Bool { true }

    private var labelFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(9, (textView?.font?.pointSize ?? 12) - 1), weight: .regular)
    }

    var preferredWidth: CGFloat {
        let digits = max(3, String(textView?.lineStarts.count ?? 1).count)
        return ceil(("8" as NSString).size(withAttributes: [.font: labelFont]).width * CGFloat(digits) + 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        guard let textView, let lines = textView.visibleLines(in: textView.visibleRect) else { return }

        let normal: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]
        let changed: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.labelColor]
        // Text view coordinates → this view: both are flipped, offset by the scroll position.
        let offset = textView.visibleRect.minY
        for line in lines {
            guard let lineRect = textView.rect(forLine: line) else { continue }
            let y = lineRect.minY - offset
            let isChanged = textView.changedLines.contains(line)
            let label = "\(line + 1)" as NSString
            let attributes = isChanged ? changed : normal
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: bounds.width - size.width - 8, y: y + (min(lineRect.height, size.height * 1.6) - size.height) / 2), withAttributes: attributes)
            if isChanged {
                textView.changeColor.withAlphaComponent(0.9).setFill()
                NSRect(x: bounds.width - 4, y: y, width: 3, height: lineRect.height).fill()
            }
        }
    }
}

/// Keeps the vertical scroll positions of several editors in step.
final class EditorScrollSync: NSObject {
    private final class Entry {
        weak var scrollView: NSScrollView?
        init(_ scrollView: NSScrollView) { self.scrollView = scrollView }
    }

    private var entries: [Entry] = []
    private var isSyncing = false
    var isEnabled = true

    func register(_ scrollView: NSScrollView) {
        entries.removeAll { $0.scrollView == nil || $0.scrollView === scrollView }
        entries.append(Entry(scrollView))
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        guard isEnabled, !isSyncing, let source = notification.object as? NSClipView else { return }
        isSyncing = true
        defer { isSyncing = false }
        for entry in entries {
            guard let other = entry.scrollView, other.contentView !== source else { continue }
            let maximum = max(0, (other.documentView?.frame.height ?? 0) - other.contentView.bounds.height)
            var origin = other.contentView.bounds.origin
            origin.y = min(max(0, source.bounds.origin.y), maximum)
            guard origin != other.contentView.bounds.origin else { continue }
            other.contentView.scroll(to: origin)
            other.reflectScrolledClipView(other.contentView)
        }
    }
}

//
//  SyntaxAndPatchTests.swift
//  PathDiffTests
//

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing

@Suite("Syntax highlighting")
struct SyntaxHighlighterTests {
    private func kinds(_ line: String, in text: String, language: SyntaxLanguage) -> [(String, SyntaxKind)] {
        let document = TextDocument(text: text)
        let highlights = SyntaxHighlighter.highlight(document, language: language)
        guard let index = document.lines.firstIndex(of: line) else { return [] }
        let characters = Array(line)
        return highlights.lines[index].map { (String(characters[$0.range]), $0.kind) }
    }

    @Test func swiftTokens() {
        let line = #"    @MainActor func load(_ url: URL) -> Int { return 42 } // done"#
        let result = kinds(line, in: line, language: .swift)
        #expect(result.contains { $0 == ("@MainActor", .attribute) })
        #expect(result.contains { $0 == ("func", .keyword) })
        #expect(result.contains { $0 == ("URL", .type) })
        #expect(result.contains { $0 == ("Int", .type) })
        #expect(result.contains { $0 == ("42", .number) })
        #expect(result.contains { $0 == ("// done", .comment) })
        let strings = kinds(#"let s = "a \"b\" c""#, in: #"let s = "a \"b\" c""#, language: .swift)
        #expect(strings.contains { $0 == (#""a \"b\" c""#, .string) })
    }

    @Test func blockCommentsAndMultilineStringsSpanLines() {
        let text = "a /* start\nmiddle\nend */ b\nlet s = \"\"\"\ninside\n\"\"\"\nlet x = 1"
        #expect(kinds("middle", in: text, language: .swift).map(\.1) == [.comment])
        #expect(kinds("end */ b", in: text, language: .swift).first?.1 == .comment)
        #expect(kinds("inside", in: text, language: .swift).map(\.1) == [.string])
        #expect(kinds("let x = 1", in: text, language: .swift).map(\.1) == [.keyword, .number])
    }

    @Test func jsonMarkupAndYAML() {
        let json = #"  "name": "PathDiff", "count": 3, "ok": true"#
        let jsonKinds = kinds(json, in: json, language: .json)
        #expect(jsonKinds.map(\.1) == [.property, .string, .property, .number, .property, .keyword])

        let xml = #"<key attr="v">text</key> <!-- note -->"#
        let xmlKinds = kinds(xml, in: xml, language: .markup)
        #expect(xmlKinds.first! == ("<key", .tag))
        #expect(xmlKinds.contains { $0 == ("attr", .attribute) })
        #expect(xmlKinds.contains { $0 == (#""v""#, .string) })
        #expect(xmlKinds.last! == ("<!-- note -->", .comment))

        let yaml = "  image: \"nginx\" # web"
        #expect(kinds(yaml, in: yaml, language: .yaml).map(\.1) == [.property, .string, .comment])
    }

    @Test func detectsLanguagesByName() {
        #expect(SyntaxLanguage.detect(path: "src/App.swift")?.name == "Swift")
        #expect(SyntaxLanguage.detect(path: "web/index.tsx")?.name == "JavaScript / TypeScript")
        #expect(SyntaxLanguage.detect(path: "Dockerfile")?.name == "Dockerfile")
        #expect(SyntaxLanguage.detect(path: "Info.plist")?.name == "XML / HTML")
        #expect(SyntaxLanguage.detect(path: "notes.unknownext") == nil)
    }

    @Test func rendererMergesSyntaxAndChangeHighlights() {
        let text = DiffTextRenderer.attributed(
            "let\tvalue = 1",
            highlights: [4..<9],
            highlightColor: .red,
            syntax: [SyntaxSpan(range: 0..<3, kind: .keyword), SyntaxSpan(range: 12..<13, kind: .number)]
        )
        #expect(String(text.characters) == "let    value = 1")
        #expect(text.runs.count == 5)
    }
}

@Suite("Patches")
struct PatchBuilderTests {
    nonisolated private static let gitPath = "/usr/bin/git"

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.gitPath)
        process.arguments = ["-C", directory.path(percentEncoded: false)] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test func hunkHeadersFollowUnifiedFormat() {
        let left = TextDocument(text: (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n")
        let right = TextDocument(text: (1...10).map { $0 == 5 ? "changed" : "line \($0)" }.joined(separator: "\n") + "\n")
        let patch = PatchBuilder.unifiedDiff(oldPath: "a.txt", newPath: "a.txt", diff: DiffEngine.makeTextDiff(left: left, right: right, options: DiffOptions()))
        #expect(patch.contains("@@ -2,7 +2,7 @@"))
        #expect(patch.contains("-line 5\n+changed\n"))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: gitPath)))
    func exportedPatchAppliesWithGit() async throws {
        let fixture = try FolderFixture()
        try fixture.writeBoth("same.txt", "unchanged\n")
        try fixture.write(.left, "edit.txt", (1...30).map { "row \($0)" }.joined(separator: "\n") + "\n")
        try fixture.write(.right, "edit.txt", (1...30).map { $0 % 10 == 0 ? "ROW \($0)" : "row \($0)" }.joined(separator: "\n") + "\nextra\n")
        try fixture.write(.left, "eof.txt", "a\nb")
        try fixture.write(.right, "eof.txt", "a\nc")
        try fixture.write(.left, "gone.txt", "bye\n")
        try fixture.write(.right, "added/new.txt", "hello\n")
        let body = (0..<20).map { "body \($0)\n" }.joined()
        try fixture.write(.left, "old/Moved.swift", body)
        try fixture.write(.right, "new/Moved.swift", body.replacingOccurrences(of: "body 4\n", with: "body four\n"))

        let settings = AppSettings(defaults: UserDefaults(suiteName: "PathDiffTests-\(UUID().uuidString)")!)
        settings.watchForChanges = false
        let viewModel = DiffViewModel(settings: settings, scanner: FolderScanner(cacheDirectory: nil))
        viewModel.setFolder(fixture.left, for: .left)
        viewModel.setFolder(fixture.right, for: .right)
        try await waitUntil("scan") { viewModel.hasScanned && !viewModel.isScanning && !viewModel.isDetectingMoves && viewModel.summary.moved == 1 }

        let patch = try await PatchBuilder.patch(for: viewModel.patchEntries(), options: DiffOptions())
        #expect(patch.contains("rename from old/Moved.swift"))
        let patchURL = fixture.root.appending(path: "changes.patch")
        try Data(patch.utf8).write(to: patchURL)

        // Apply to a git repository holding the left folder; the result must equal the right.
        try git(["init", "-q"], in: fixture.left)
        let check = try git(["apply", "--check", patchURL.path(percentEncoded: false)], in: fixture.left)
        #expect(check.status == 0, "git apply --check: \(check.output)\n\(patch)")
        try git(["apply", patchURL.path(percentEncoded: false)], in: fixture.left)
        try FileManager.default.removeItem(at: fixture.left.appending(path: ".git"))

        let rescan = try await FolderScanner(cacheDirectory: nil).scan(
            leftRoot: fixture.left, rightRoot: fixture.right,
            rules: ScanRules(matcher: IgnoreMatcher(patterns: []), respectsGitIgnore: false), options: DiffOptions()
        )
        #expect(DiffSummary(nodes: rescan.nodes).differences == 0)
    }
}

@Suite("Image comparison")
struct ImageComparatorTests {
    private func writePNG(_ url: URL, width: Int, height: Int, changed: Set<Int> = []) throws {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let isChanged = changed.contains(index)
            pixels[index * 4] = isChanged ? 255 : 40
            pixels[index * 4 + 1] = 120
            pixels[index * 4 + 2] = isChanged ? 0 : 200
            pixels[index * 4 + 3] = 255
        }
        let image = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func countsChangedPixelsAndBounds() async throws {
        let fixture = try FolderFixture()
        let left = fixture.url(.left, "a.png")
        let right = fixture.url(.right, "a.png")
        try writePNG(left, width: 20, height: 10)
        try writePNG(right, width: 20, height: 10, changed: [21, 22, 45])
        let comparison = await ImageComparator.compare(left: left, right: right)
        #expect(comparison.changedPixels == 3)
        #expect(comparison.comparedPixels == 200)
        #expect(comparison.changedBounds == CGRect(x: 1, y: 1, width: 5, height: 2))
        #expect(comparison.leftInfo?.pixelWidth == 20)
        #expect(!comparison.sizesDiffer)
    }

    @Test func identicalAndResizedImages() async throws {
        let fixture = try FolderFixture()
        try writePNG(fixture.url(.left, "a.png"), width: 8, height: 8)
        try writePNG(fixture.url(.right, "a.png"), width: 8, height: 8)
        try writePNG(fixture.url(.right, "b.png"), width: 12, height: 8)
        let same = await ImageComparator.compare(left: fixture.url(.left, "a.png"), right: fixture.url(.right, "a.png"))
        #expect(same.changedPixels == 0)
        let resized = await ImageComparator.compare(left: fixture.url(.left, "a.png"), right: fixture.url(.right, "b.png"))
        #expect(resized.sizesDiffer)
        #expect(resized.changedPixels == 32)   // the extra 4×8 columns
    }
}

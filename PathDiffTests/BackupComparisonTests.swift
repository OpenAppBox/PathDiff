//
//  BackupComparisonTests.swift
//  PathDiffTests
//

import AppKit
import AVFoundation
import Foundation
import SwiftUI
import Testing

/// Comparing two copies of a photo and video library, such as two backup drives.
@Suite("Backup and media comparison", .serialized)
struct BackupComparisonTests {
    private let rules = ScanRules(matcher: IgnoreMatcher(patterns: IgnoreMatcher.defaultPatterns), respectsGitIgnore: false)
    private let quick = DiffOptions(comparisonMethod: .quick)
    private let referenceDate = Date(timeIntervalSinceReferenceDate: 750_000_000)

    private func setModified(_ fixture: FolderFixture, _ side: FixtureSide, _ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.url(side, path).path(percentEncoded: false))
    }

    private func statuses(_ nodes: [DiffNode]) -> [String: FileStatus] {
        var result: [String: FileStatus] = [:]
        DiffTree.forEachDepthFirst(nodes) { result[$0.id] = $0.status }
        return result
    }

    // MARK: Comparison methods

    @Test func quickMethodTrustsMatchingSizeAndDate() async throws {
        let fixture = try FolderFixture()
        // Same size and date, different bytes: only a full comparison notices.
        try fixture.write(.left, "same-date.mov", "AAAA")
        try fixture.write(.right, "same-date.mov", "BBBB")
        try setModified(fixture, .left, "same-date.mov", referenceDate)
        try setModified(fixture, .right, "same-date.mov", referenceDate.addingTimeInterval(1.5))   // exFAT rounding
        // Same size, dates far apart: read, and found identical or different by contents.
        try fixture.write(.left, "copied.jpg", "pixels")
        try fixture.write(.right, "copied.jpg", "pixels")
        try setModified(fixture, .left, "copied.jpg", referenceDate)
        try setModified(fixture, .right, "copied.jpg", referenceDate.addingTimeInterval(3600))
        try fixture.write(.left, "edited.jpg", "before")
        try fixture.write(.right, "edited.jpg", "after!")
        try setModified(fixture, .left, "edited.jpg", referenceDate)
        try setModified(fixture, .right, "edited.jpg", referenceDate.addingTimeInterval(60))

        let quickStatus = statuses(try await FolderScanner(cacheDirectory: nil).scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: quick).nodes)
        #expect(quickStatus["same-date.mov"] == .identical)
        #expect(quickStatus["copied.jpg"] == .identical)
        #expect(quickStatus["edited.jpg"] == .modified)

        let fullStatus = statuses(try await FolderScanner(cacheDirectory: nil).scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions()).nodes)
        #expect(fullStatus["same-date.mov"] == .modified)
        #expect(fullStatus["copied.jpg"] == .identical)
        #expect(fullStatus["edited.jpg"] == .modified)
    }

    @Test func quickAndFullResultsAreRememberedSeparately() throws {
        let store = ComparisonCacheStore(directory: URL(filePath: "/tmp/unused"))
        let left = URL(filePath: "/a")
        let right = URL(filePath: "/b")
        #expect(store.fileURL(leftRoot: left, rightRoot: right, options: DiffOptions())
            != store.fileURL(leftRoot: left, rightRoot: right, options: quick))
    }

    // MARK: Moves

    @Test func quickMethodPairsMovesByNameSizeAndDate() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "2023/Trip/clip.mov", "frames-A")
        try fixture.write(.right, "Videos/Trip 2023/clip.mov", "frames-B")
        try setModified(fixture, .left, "2023/Trip/clip.mov", referenceDate)
        try setModified(fixture, .right, "Videos/Trip 2023/clip.mov", referenceDate)
        let scanner = FolderScanner(cacheDirectory: nil)
        let nodes = try await scanner.scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: quick).nodes

        let quickMoves = try await scanner.detectMoves(in: nodes, method: .quick)
        #expect(quickMoves.byLeftPath["2023/Trip/clip.mov"]?.rightPath == "Videos/Trip 2023/clip.mov")
        #expect(quickMoves.byLeftPath["2023/Trip/clip.mov"]?.isExact == true)

        // Read for real, the contents differ: still paired, as an edited video.
        let fullMoves = try await scanner.detectMoves(in: nodes, method: .contents)
        #expect(fullMoves.byLeftPath["2023/Trip/clip.mov"]?.isExact == false)
    }

    @Test func editedMediaWithAUniqueNameIsPairedAcrossFolders() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "Photos/2022/IMG_0420.JPG", "original photo")
        try fixture.write(.right, "Edited/IMG_0420.JPG", "retouched photo, larger")
        try fixture.write(.left, "Photos/song.mp3", "take 1")
        try fixture.write(.right, "Music/song.mp3", "take 2, remastered")
        // Not media: unrelated binaries that share a name are not paired.
        try fixture.write(.left, "a/data.bin", "\u{0}\u{1}\u{2}")
        try fixture.write(.right, "b/data.bin", "\u{0}\u{9}\u{9}\u{9}")
        // Names that occur twice on one side are ambiguous and stay unpaired.
        try fixture.write(.left, "cam1/DSC_0001.JPG", "one")
        try fixture.write(.left, "cam2/DSC_0001.JPG", "two")
        try fixture.write(.right, "all/DSC_0001.JPG", "three!")

        let scanner = FolderScanner(cacheDirectory: nil)
        let nodes = try await scanner.scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions()).nodes
        let moves = try await scanner.detectMoves(in: nodes)
        #expect(moves.byLeftPath["Photos/2022/IMG_0420.JPG"]?.rightPath == "Edited/IMG_0420.JPG")
        #expect(moves.byLeftPath["Photos/2022/IMG_0420.JPG"]?.isExact == false)
        #expect(moves.byLeftPath["Photos/song.mp3"]?.rightPath == "Music/song.mp3")
        #expect(moves.byLeftPath["a/data.bin"] == nil)
        #expect(moves.byRightPath["all/DSC_0001.JPG"] == nil)
    }

    // MARK: Totals, ignores and types

    @Test func summaryReportsBytesPerKind() async throws {
        let fixture = try FolderFixture()
        try fixture.write(.left, "missing.mov", String(repeating: "m", count: 1_000))
        try fixture.write(.right, "extra.jpg", String(repeating: "e", count: 300))
        try fixture.write(.left, "changed.png", String(repeating: "a", count: 40))
        try fixture.write(.right, "changed.png", String(repeating: "b", count: 50))
        try fixture.write(.left, "old/moved.txt", "same contents")
        try fixture.write(.right, "new/moved.txt", "same contents")

        let scanner = FolderScanner(cacheDirectory: nil)
        let nodes = try await scanner.scan(leftRoot: fixture.left, rightRoot: fixture.right, rules: rules, options: DiffOptions()).nodes
        let moves = try await scanner.detectMoves(in: nodes)
        var summary = DiffSummary(nodes: nodes)
        summary.apply(moves, in: nodes)

        #expect(summary.leftOnly == 1)
        #expect(summary.leftOnlyBytes == 1_000)
        #expect(summary.rightOnlyBytes == 300)
        #expect(summary.modifiedBytes == 50)
        #expect(summary.moved == 1)
        #expect(summary.movedBytes == 13)
    }

    @Test func driveBookkeepingFilesAreIgnoredByDefault() {
        let matcher = IgnoreMatcher(patterns: IgnoreMatcher.defaultPatterns)
        #expect(matcher.isIgnored(name: "._IMG_0001.JPG", relativePath: "DCIM/._IMG_0001.JPG", isDirectory: false))
        #expect(matcher.isIgnored(name: ".Spotlight-V100", relativePath: ".Spotlight-V100", isDirectory: true))
        #expect(matcher.isIgnored(name: "Thumbs.db", relativePath: "Photos/Thumbs.db", isDirectory: false))
        #expect(matcher.isIgnored(name: "$RECYCLE.BIN", relativePath: "$RECYCLE.BIN", isDirectory: true))
        #expect(!matcher.isIgnored(name: "IMG_0001.JPG", relativePath: "DCIM/IMG_0001.JPG", isDirectory: false))
    }

    @Test func classifiesFileTypes() {
        #expect(FileCategory(path: "IMG_1234.HEIC") == .images)
        #expect(FileCategory(path: "raw/DSC_0001.NEF") == .images)
        #expect(FileCategory(path: "clip.MOV") == .videos)
        #expect(FileCategory(path: "clip.mp4") == .videos)
        #expect(FileCategory(path: "song.mp3") == .audio)
        #expect(FileCategory(path: "report.pdf") == .documents)
        #expect(FileCategory(path: "letter.docx") == .documents)
        #expect(FileCategory(path: "main.swift") == .code)
        #expect(FileCategory(path: "photos.zip") == .archives)
        #expect(FileCategory(path: "no-extension") == .other)

        #expect(MediaKind(path: "a.jpg") == .image)
        #expect(MediaKind(path: "a.mov") == .video)
        #expect(MediaKind(path: "a.m4a") == .audio)
        #expect(MediaKind(path: "logo.svg") == nil, "SVG keeps its text diff")
        #expect(MediaKind(path: "a.pdf") == nil)
    }

    @Test func checksumsMatchKnownDigests() async throws {
        let fixture = try FolderFixture()
        let url = try fixture.write(.left, "abc.txt", "abc")
        let checksums = try await ChecksumCalculator.checksums(of: url)
        #expect(checksums.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(checksums.md5 == "900150983cd24fb0d6963f7d28e17f72")
    }

    @Test func largeMediaOpensInItsOwnViewWithoutBeingRead() async throws {
        let video = DiffNode(
            name: "long.mov", relativePath: "long.mov",
            leftURL: URL(filePath: "/nonexistent/long.mov"), rightURL: URL(filePath: "/nonexistent/other/long.mov"),
            leftMetadata: ItemMetadata(kind: .file, size: 40_000_000_000), rightMetadata: ItemMetadata(kind: .file, size: 40_000_000_000),
            status: .identical, children: nil
        )
        let content = await DiffEngine.computeDiff(for: video, options: DiffOptions())
        #expect(content == .media(MediaComparison(kind: .video, leftSize: 40_000_000_000, rightSize: 40_000_000_000, areIdentical: true)))

        let photo = DiffNode(
            name: "big.dng", relativePath: "big.dng",
            leftURL: URL(filePath: "/nonexistent/big.dng"), rightURL: nil,
            leftMetadata: ItemMetadata(kind: .file, size: 90_000_000), rightMetadata: nil,
            status: .leftOnly, children: nil
        )
        let photoContent = await DiffEngine.computeDiff(for: photo, options: DiffOptions())
        #expect(photoContent == .binary(BinaryComparison(leftSize: 90_000_000, rightSize: nil, areIdentical: false, isImage: true)))
    }

    @Test func mediaMetadataReadsNaturally() {
        #expect(MediaInspector.iso6709("+63.5321-019.5112+012.000/") == MediaInspector.coordinates(latitude: 63.5321, longitude: -19.5112))
        #expect(MediaInspector.coordinates(latitude: 63.5321, longitude: -19.5112).hasSuffix("° W"))
        #expect(MediaInspector.iso6709("not a location") == nil)
        #expect(MediaInspector.exifDate("2023:06:22 23:41:05") != "2023:06:22 23:41:05", "EXIF dates are shown as dates")
        #expect(MediaInspector.exifDate("garbled") == "garbled")
    }

    // MARK: Media views

    /// Regression: SwiftUI's VideoPlayer crashed because only its overlay framework was linked,
    /// and a window-level inspector made AppKit throw when the window closed.
    @Test @MainActor func videoComparisonOpensAndCloses() async throws {
        let fixture = try FolderFixture()
        try Movie.write(to: fixture.url(.left, "clip.mov"), seconds: 1, codec: .h264, width: 320, height: 180, seed: 1, taken: referenceDate, edited: true)
        try Movie.write(to: fixture.url(.right, "clip.mov"), seconds: 1, codec: .h264, width: 320, height: 180, seed: 2, taken: referenceDate, edited: false)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "PathDiffTests-\(UUID().uuidString)")!)
        settings.watchForChanges = false
        let viewModel = DiffViewModel(settings: settings, scanner: FolderScanner(cacheDirectory: nil))
        let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(request: nil, viewModel: viewModel).environment(settings)))
        window.setContentSize(CGSize(width: 1100, height: 700))
        window.orderFront(nil)
        viewModel.setFolder(fixture.left, for: .left)
        viewModel.setFolder(fixture.right, for: .right)
        try await waitUntil("scan") { viewModel.hasScanned && !viewModel.isScanning }
        viewModel.select(nodeID: "clip.mov")
        try await waitUntil("media view") {
            if case .media = viewModel.activeDiff { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(500))
        window.close()
        try await Task.sleep(for: .milliseconds(300))
    }

    // MARK: Sidebar

    @Test @MainActor func typeFilterListsMatchingFilesInsideMissingFolders() async throws {
        let fixture = try FolderFixture()
        try fixture.writeBoth("keep.txt", "same")
        try fixture.write(.left, "Trip/clip.mov", "video")
        try fixture.write(.left, "Trip/photo.jpg", "photo")
        try fixture.write(.left, "Trip/notes.txt", "notes")

        let defaults = UserDefaults(suiteName: "PathDiffTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.watchForChanges = false
        let viewModel = DiffViewModel(settings: settings, scanner: FolderScanner(cacheDirectory: nil))
        viewModel.setFolder(fixture.left, for: .left)
        viewModel.setFolder(fixture.right, for: .right)
        try await waitUntil("scan") { viewModel.hasScanned && !viewModel.isScanning }
        try await waitUntil("move detection") { !viewModel.isDetectingMoves }

        #expect(viewModel.changeSections.flatMap(\.rows).map(\.id) == ["Trip"], "a missing folder is one row")
        viewModel.typeFilter = .videos
        #expect(viewModel.changeSections.flatMap(\.rows).map(\.id) == ["Trip/clip.mov"])
        viewModel.typeFilter = .images
        #expect(viewModel.changeSections.flatMap(\.rows).map(\.id) == ["Trip/photo.jpg"])
        viewModel.resetFilters()
        #expect(viewModel.typeFilter == nil)
        #expect(viewModel.summary.leftOnlyBytes == 15)
    }
}

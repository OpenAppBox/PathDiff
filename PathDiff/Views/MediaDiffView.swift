//
//  MediaDiffView.swift
//  PathDiff
//

import AVFoundation
import AVKit
import SwiftUI

/// Two players side by side for videos and audio, with buttons that drive both at once, and
/// the files' details in the inspector.
struct MediaDiffView: View {
    let viewModel: DiffViewModel
    let node: DiffNode
    /// The pair actually compared (a moved file is compared with its counterpart).
    let comparedNode: DiffNode
    let comparison: MediaComparison

    @AppStorage("showsMediaInfo") private var showsInfo = true
    @State private var playback = LinkedPlayback()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let move = viewModel.moves.match(for: node) {
                    MoveBanner(viewModel: viewModel, node: node, match: move)
                    Divider()
                }
                HStack(spacing: 0) {
                    pane(.left, player: playback.left)
                    Divider()
                    pane(.right, player: playback.right)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                FileSyncButtons(viewModel: viewModel, node: node)
                    .padding(.vertical, 8)
            }
            if showsInfo {
                FileDetailsPanel(viewModel: viewModel, node: comparedNode)
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsInfo)
        .task(id: comparedNode.contentIdentity) {
            playback.load(left: comparedNode.leftURL, right: comparedNode.rightURL)
        }
        .onDisappear { playback.unload() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            BadgedFileIcon(node: node, move: viewModel.moves.match(for: node), size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).font(.headline).lineLimit(1)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)

            if playback.left != nil && playback.right != nil {
                ControlGroup {
                    Button {
                        playback.restart()
                    } label: {
                        Label("Back to Start", systemImage: "backward.end.fill")
                    }
                    .help("Move both to the beginning")
                    Button {
                        playback.isPlaying ? playback.pause() : playback.play()
                    } label: {
                        Label(playback.isPlaying ? String(localized: "Pause Both") : String(localized: "Play Both"), systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .help(playback.isPlaying ? String(localized: "Pause both") : String(localized: "Play both at the same time"))
                    Button {
                        playback.alignRightWithLeft()
                    } label: {
                        Label("Match Positions", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    .help("Move \(viewModel.sideName(.right)) to the same moment as \(viewModel.sideName(.left))")
                }
                .controlGroupStyle(.navigation)
                .labelStyle(.iconOnly)
                .fixedSize()
            }

            Toggle(isOn: $showsInfo) {
                Label("Details", systemImage: "info.circle")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(showsInfo ? String(localized: "Hide details") : String(localized: "Show details, metadata and checksums"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var summary: String {
        if comparison.leftSize == nil { return String(localized: "Only in \(viewModel.sideName(.right))") }
        if comparison.rightSize == nil { return String(localized: "Only in \(viewModel.sideName(.left))") }
        if comparison.areIdentical { return String(localized: "Identical files") }
        let sameSize = comparison.leftSize == comparison.rightSize
        if comparison.kind == .video {
            return sameSize ? String(localized: "Videos differ (same size, different contents)") : String(localized: "Videos differ")
        }
        return sameSize ? String(localized: "Audio files differ (same size, different contents)") : String(localized: "Audio files differ")
    }

    @ViewBuilder
    private func pane(_ side: Side, player: AVPlayer?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: side == .left ? "l.square.fill" : "r.square.fill")
                    .foregroundStyle(.tertiary)
                Text(viewModel.sideName(side))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(DiffPalette.gutterBackground)
            Divider()
            if let player {
                ZStack {
                    PlayerView(player: player)
                    if comparison.kind == .audio {
                        Image(systemName: "waveform")
                            .font(.system(size: 56, weight: .light))
                            .foregroundStyle(.white.opacity(0.35))
                            .allowsHitTesting(false)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Not in \(viewModel.sideName(side))",
                    systemImage: comparison.kind == .video ? "film" : "waveform",
                    description: Text("This file only exists in \(viewModel.sideName(side.opposite)).")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// AppKit's player with the standard macOS controls. Using `AVPlayerView` directly (rather than
/// SwiftUI's `VideoPlayer`) also makes the app link AVKit itself: with only the SwiftUI overlay
/// linked, creating a player crashed because its superclass couldn't be found.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// The two players of a media comparison, driven together.
@Observable
final class LinkedPlayback {
    private(set) var left: AVPlayer?
    private(set) var right: AVPlayer?
    private(set) var isPlaying = false

    func load(left leftURL: URL?, right rightURL: URL?) {
        unload()
        left = leftURL.map { AVPlayer(url: $0) }
        right = rightURL.map { AVPlayer(url: $0) }
    }

    func unload() {
        pause()
        left = nil
        right = nil
    }

    func play() {
        left?.play()
        right?.play()
        isPlaying = true
    }

    func pause() {
        left?.pause()
        right?.pause()
        isPlaying = false
    }

    func restart() {
        for player in [left, right].compactMap({ $0 }) {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func alignRightWithLeft() {
        guard let left, let right else { return }
        right.seek(to: left.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

// MARK: - Details inspector

/// The details panel beside a photo, video, audio or other image (PDF) comparison.
///
/// A plain side panel rather than SwiftUI's `.inspector`: an inspector inside the split view's
/// detail column blurred the comparison's header, and one on the window made AppKit throw while
/// closing the window.
struct FileDetailsPanel: View {
    let viewModel: DiffViewModel
    /// The compared pair (for a moved file, both sides of the move).
    let node: DiffNode

    var body: some View {
        HStack(spacing: 0) {
            Divider()
            content
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .interfaceLayout()
        }
        .transition(.move(edge: .trailing))
    }

    @ViewBuilder
    private var content: some View {
        if let kind = MediaKind(path: node.relativePath) {
            MediaInfoPanel(viewModel: viewModel, node: node, kind: kind)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    FileFactsRows(viewModel: viewModel, node: node)
                    ChecksumSection(viewModel: viewModel, node: node, isCompact: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Size, dates, embedded metadata and checksums of both files, with differences marked.
struct MediaInfoPanel: View {
    let viewModel: DiffViewModel
    /// The compared pair: for a moved file, both sides of the move.
    let node: DiffNode
    let kind: MediaKind

    @State private var leftFields: [MetadataField]?
    @State private var rightFields: [MetadataField]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section(String(localized: "File")) {
                    FileFactsRows(viewModel: viewModel, node: node)
                }
                section(kind == .image ? String(localized: "Photo") : kind == .video ? String(localized: "Video") : String(localized: "Audio")) {
                    if let leftFields = leftFields ?? (node.leftURL == nil ? [] : nil),
                       let rightFields = rightFields ?? (node.rightURL == nil ? [] : nil) {
                        let rows = Self.rows(left: leftFields, right: rightFields)
                        if rows.isEmpty {
                            Text("No embedded details.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(rows, id: \.label) { row in
                                ComparedValueRow(
                                    label: row.label,
                                    left: node.leftURL == nil ? nil : (row.left ?? "—"),
                                    right: node.rightURL == nil ? nil : (row.right ?? "—"),
                                    viewModel: viewModel
                                )
                            }
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                section(String(localized: "Checksums")) {
                    ChecksumSection(viewModel: viewModel, node: node, isCompact: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: node.contentIdentity) {
            leftFields = nil
            rightFields = nil
            async let left = Self.fields(of: node.leftURL, kind: kind)
            async let right = Self.fields(of: node.rightURL, kind: kind)
            let (l, r) = await (left, right)
            leftFields = l
            rightFields = r
        }
    }

    private static func fields(of url: URL?, kind: MediaKind) async -> [MetadataField] {
        guard let url else { return [] }
        return await MediaInspector.fields(of: url, kind: kind)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// Every label found on either side, in the order the left side lists them.
    static func rows(left: [MetadataField], right: [MetadataField]) -> [(label: String, left: String?, right: String?)] {
        var labels: [String] = []
        for field in left + right where !labels.contains(field.label) { labels.append(field.label) }
        let leftValues = Dictionary(left.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        let rightValues = Dictionary(right.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        return labels.map { ($0, leftValues[$0], rightValues[$0]) }
    }
}

/// Size and modification date of both sides, marking the newer copy.
struct FileFactsRows: View {
    let viewModel: DiffViewModel
    let node: DiffNode

    var body: some View {
        let left = node.leftURL == nil ? nil : node.leftMetadata
        let right = node.rightURL == nil ? nil : node.rightMetadata
        ComparedValueRow(
            label: String(localized: "Size"),
            left: left.map { DisplayFormat.byteCount($0.size) },
            right: right.map { DisplayFormat.byteCount($0.size) },
            viewModel: viewModel
        )
        ComparedValueRow(
            label: String(localized: "date.modified", defaultValue: "Modified", comment: "Label for a file's modification date"),
            left: left.map { DisplayFormat.date($0.modificationDate) },
            right: right.map { DisplayFormat.date($0.modificationDate) },
            viewModel: viewModel,
            leftNote: newer(left, than: right) ? String(localized: "Newer") : nil,
            rightNote: newer(right, than: left) ? String(localized: "Newer") : nil
        )
    }

    private func newer(_ metadata: ItemMetadata?, than other: ItemMetadata?) -> Bool {
        guard let date = metadata?.modificationDate, let otherDate = other?.modificationDate else { return false }
        return date.timeIntervalSince(otherDate) > ComparisonMethod.modificationDateTolerance
    }
}

/// One fact for both sides: shown once when equal, or per side with a "differs" mark.
/// A `nil` side means the file doesn't exist there.
struct ComparedValueRow: View {
    let label: String
    let left: String?
    let right: String?
    let viewModel: DiffViewModel
    var leftNote: String?
    var rightNote: String?

    var body: some View {
        let differs = left != nil && right != nil && left != right
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if differs {
                    TagLabel(text: String(localized: "Differs"), color: ChangeKind.modified.color)
                }
            }
            if left != nil, left == right {
                Text(left ?? "")
                    .font(.callout)
                    .textSelection(.enabled)
            } else {
                if let left { sideValue(.left, left, note: leftNote, highlighted: differs) }
                if let right { sideValue(.right, right, note: rightNote, highlighted: differs) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sideValue(_ side: Side, _ value: String, note: String?, highlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: side == .left ? "l.square.fill" : "r.square.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help(viewModel.sideName(side))
            Text(value)
                .font(.callout)
                .foregroundStyle(highlighted ? .primary : .secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                TagLabel(text: note, color: Palette.extra)
            }
        }
    }
}

// MARK: - Checksums

/// Calculates SHA-256 and MD5 for both files on request and says whether they match.
struct ChecksumSection: View {
    let viewModel: DiffViewModel
    /// The compared pair (for a moved file, both sides of the move).
    let node: DiffNode
    /// Narrow layout for the inspector.
    var isCompact = false

    private enum Phase: Equatable {
        case idle
        case running(left: Double, right: Double)
        case done(left: FileChecksums?, right: FileChecksums?)
        case failed(String)
    }

    @State private var phase = Phase.idle
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: isCompact ? .leading : .center, spacing: 10) {
            switch phase {
            case .idle:
                Button {
                    start()
                } label: {
                    Label("Calculate Checksums", systemImage: "number")
                }
                Text("SHA-256 and MD5 of each file, to verify copies byte for byte or check them against other tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(isCompact ? .leading : .center)
                    .fixedSize(horizontal: false, vertical: true)
            case .running(let left, let right):
                VStack(alignment: .leading, spacing: 6) {
                    if leftURL != nil { progressRow(.left, left) }
                    if rightURL != nil { progressRow(.right, right) }
                }
                Button("Stop") { cancel() }
                    .controlSize(.small)
            case .done(let left, let right):
                result(left: left, right: right)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Try Again") { start() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: isCompact ? .infinity : 560, alignment: isCompact ? .leading : .center)
        // A result for a file that has since been replaced would be wrong.
        .onChange(of: node.contentIdentity) { cancel() }
        .onDisappear { task?.cancel() }
    }

    private var leftURL: URL? { node.leftURL }
    private var rightURL: URL? { node.rightURL }

    private func progressRow(_ side: Side, _ value: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: side == .left ? "l.square.fill" : "r.square.fill")
                .foregroundStyle(.tertiary)
            ProgressView(value: value)
                .frame(minWidth: 120)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func result(left: FileChecksums?, right: FileChecksums?) -> some View {
        if let left, let right {
            TagLabel(
                text: left == right
                    ? String(localized: "Checksums match: the files are identical")
                    : String(localized: "Checksums differ: the contents are not the same"),
                color: left == right ? Palette.extra : ChangeKind.modified.color,
                systemImage: left == right ? "checkmark" : "xmark"
            )
        }
        VStack(alignment: .leading, spacing: 8) {
            digestRow("SHA-256", left: left?.sha256, right: right?.sha256)
            digestRow("MD5", left: left?.md5, right: right?.md5)
        }
    }

    private func digestRow(_ label: String, left: String?, right: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let left { digest(.left, left) }
            if let right { digest(.right, right) }
        }
    }

    private func digest(_ side: Side, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: side == .left ? "l.square.fill" : "r.square.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help(viewModel.sideName(side))
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy")
        }
    }

    private func start() {
        task?.cancel()
        phase = .running(left: 0, right: 0)
        let leftURL = leftURL
        let rightURL = rightURL
        task = Task {
            let report: @Sendable (Side, Double) -> Void = { side, value in
                Task { @MainActor in
                    guard case .running(let left, let right) = phase else { return }
                    phase = side == .left ? .running(left: value, right: right) : .running(left: left, right: value)
                }
            }
            do {
                async let left = Self.checksums(of: leftURL) { report(.left, $0) }
                async let right = Self.checksums(of: rightURL) { report(.right, $0) }
                let (l, r) = try await (left, right)
                guard !Task.isCancelled else { return }
                phase = .done(left: l, right: r)
            } catch is CancellationError {
                return
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private static func checksums(of url: URL?, progress: @escaping @Sendable (Double) -> Void) async throws -> FileChecksums? {
        guard let url else { return nil }
        return try await ChecksumCalculator.checksums(of: url, progress: progress)
    }

    private func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }
}

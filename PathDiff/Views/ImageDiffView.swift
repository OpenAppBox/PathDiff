//
//  ImageDiffView.swift
//  PathDiff
//

import SwiftUI

/// Visual comparison of two images (or PDF / SVG files): side by side, swipe, onion skin and
/// a pixel difference map, with zoom and change statistics.
struct ImageDiffView: View {
    let viewModel: DiffViewModel
    let node: DiffNode
    /// The pair actually compared (a moved image is compared with its counterpart).
    let comparedNode: DiffNode
    /// Text-based images (SVG) can switch back to the text diff.
    let canShowText: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case sideBySide = "Side by Side"
        case swipe = "Swipe"
        case onionSkin = "Onion Skin"
        case difference = "Difference"

        var id: Self { self }

        /// The name shown in the mode picker (the raw value is only an identifier).
        var title: String {
            switch self {
            case .sideBySide: String(localized: "Side by Side")
            case .swipe: String(localized: "Swipe")
            case .onionSkin: String(localized: "Onion Skin")
            case .difference: String(localized: "Difference")
            }
        }

        var symbolName: String {
            switch self {
            case .sideBySide: "rectangle.split.2x1"
            case .swipe: "slider.horizontal.below.rectangle"
            case .onionSkin: "square.stack"
            case .difference: "plusminus"
            }
        }
    }

    @State private var comparison: ImageComparison?
    @State private var mode = Mode.sideBySide
    @State private var zoom = 1.0
    @State private var swipePosition = 0.5
    @State private var onionOpacity = 0.5
    @AppStorage("showsMediaInfo") private var showsInfo = true

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let move = viewModel.moves.match(for: node) {
                    MoveBanner(viewModel: viewModel, node: node, match: move)
                    Divider()
                }
                Group {
                    if let comparison {
                        content(comparison)
                    } else {
                        DelayedProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
            }
            if showsInfo {
                FileDetailsPanel(viewModel: viewModel, node: comparedNode)
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsInfo)
        .task(id: comparedNode.contentIdentity) {
            comparison = nil
            comparison = await ImageComparator.compare(left: comparedNode.leftURL, right: comparedNode.rightURL)
            if comparison?.left == nil || comparison?.right == nil { mode = .sideBySide }
        }
    }

    // MARK: Toolbar and footer

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

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(comparison?.left == nil || comparison?.right == nil)

            HStack(spacing: 2) {
                Button {
                    zoom = max(1, zoom / 2)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .disabled(zoom <= 1)
                .help("Zoom Out")
                (zoom == 1 ? Text("Fit") : Text(verbatim: "\(Int(zoom))×"))
                    .font(.callout.weight(.medium).monospacedDigit())
                    .frame(minWidth: 34)
                Button {
                    zoom = min(16, zoom * 2)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .disabled(zoom >= 16)
                .help("Zoom In")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 3)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Palette.cardStroke))
            .fixedSize()

            if canShowText {
                Button("Compare as Text") { viewModel.showsImageComparison = false }
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
        guard let comparison else { return String(localized: "Comparing…") }
        guard comparison.left != nil, comparison.right != nil else {
            return comparison.left == nil
                ? String(localized: "Only in \(viewModel.sideName(.right))")
                : String(localized: "Only in \(viewModel.sideName(.left))")
        }
        if comparison.changedPixels == 0 {
            let same = comparison.sizesDiffer
                ? String(localized: "Same pixels where they overlap, but the sizes differ")
                : String(localized: "Pixel-identical")
            // A reduced-size comparison can average away changes of a few pixels.
            return comparison.wasDownscaled ? same + " · " + String(localized: "compared at reduced size") : same
        }
        let percent = (comparison.changedFraction * 100).formatted(.number.precision(.fractionLength(0...2)))
        let differ = String(localized: "\(comparison.changedPixels) pixels differ (\(percent)%)")
        return comparison.wasDownscaled ? differ + " · " + String(localized: "compared at reduced size") : differ
    }

    private var footer: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                info(comparison?.leftInfo, side: .left)
                Divider()
                info(comparison?.rightInfo, side: .right)
            }
            .frame(height: 44)
            .background(DiffPalette.gutterBackground)
            Divider()
            FileSyncButtons(viewModel: viewModel, node: node)
                .padding(.vertical, 8)
        }
    }

    private func info(_ info: ImageInfo?, side: Side) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: side == .left ? "l.square.fill" : "r.square.fill")
                    .foregroundStyle(.tertiary)
                Text(viewModel.sideName(side))
                    .fontWeight(.semibold)
            }
            .font(.caption)
            if let info {
                Text(details(info))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                (comparison == nil ? Text(verbatim: "…") : Text("Missing or not a readable image"))
                    .font(.caption.italic())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func details(_ info: ImageInfo) -> String {
        var parts = [
            String(localized: "\(info.pixelWidth) × \(info.pixelHeight) px"),
            DisplayFormat.byteCount(info.fileSize),
            info.typeName,
        ]
        if info.hasAlpha { parts.append(String(localized: "alpha", comment: "Image has an alpha (transparency) channel")) }
        if let colorModel = info.colorModel { parts.append(colorModel) }
        return parts.joined(separator: " · ")
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ comparison: ImageComparison) -> some View {
        if comparison.left == nil && comparison.right == nil {
            ContentUnavailableView("Can’t Display Image", systemImage: "photo.badge.exclamationmark", description: Text("Neither file could be decoded as an image."))
        } else {
            switch mode {
            case .sideBySide:
                HStack(spacing: 0) {
                    ZoomableCanvas(size: canvasSize(comparison.left, comparison.leftInfo), zoom: zoom) { scale in
                        layer(comparison.left, comparison.leftInfo, scale: scale)
                    }
                    Divider()
                    ZoomableCanvas(size: canvasSize(comparison.right, comparison.rightInfo), zoom: zoom) { scale in
                        layer(comparison.right, comparison.rightInfo, scale: scale)
                    }
                }
            case .swipe:
                ZoomableCanvas(size: sharedCanvasSize(comparison), zoom: zoom) { scale in
                    ZStack(alignment: .topLeading) {
                        layer(comparison.right, comparison.rightInfo, scale: scale)
                        layer(comparison.left, comparison.leftInfo, scale: scale)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: sharedCanvasSize(comparison).width * scale * swipePosition)
                            }
                        SwipeHandle(position: $swipePosition, width: sharedCanvasSize(comparison).width * scale)
                    }
                }
            case .onionSkin:
                VStack(spacing: 0) {
                    ZoomableCanvas(size: sharedCanvasSize(comparison), zoom: zoom) { scale in
                        ZStack(alignment: .topLeading) {
                            layer(comparison.left, comparison.leftInfo, scale: scale)
                            layer(comparison.right, comparison.rightInfo, scale: scale).opacity(onionOpacity)
                        }
                    }
                    Divider()
                    HStack {
                        Text(viewModel.sideName(.left)).font(.caption)
                        Slider(value: $onionOpacity, in: 0...1)
                        Text(viewModel.sideName(.right)).font(.caption)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            case .difference:
                ZoomableCanvas(size: sharedCanvasSize(comparison), zoom: zoom) { scale in
                    ZStack(alignment: .topLeading) {
                        if let mask = comparison.differenceMask {
                            Image(decorative: mask.cgImage, scale: 1)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: sharedCanvasSize(comparison).width * scale, height: sharedCanvasSize(comparison).height * scale)
                        }
                        if let bounds = comparison.changedBounds {
                            Rectangle()
                                .strokeBorder(Color.pink, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                                .frame(width: bounds.width * scale + 6, height: bounds.height * scale + 6)
                                .offset(x: bounds.minX * scale - 3, y: bounds.minY * scale - 3)
                        }
                    }
                }
            }
        }
    }

    /// The image's displayed size, which can be larger than the decoded image (see `ImageInfo`).
    private func canvasSize(_ image: SendableImage?, _ info: ImageInfo?) -> CGSize {
        guard let image else { return CGSize(width: 1, height: 1) }
        guard let info else { return CGSize(width: image.cgImage.width, height: image.cgImage.height) }
        return CGSize(width: info.pixelWidth, height: info.pixelHeight)
    }

    private func sharedCanvasSize(_ comparison: ImageComparison) -> CGSize {
        let left = canvasSize(comparison.left, comparison.leftInfo)
        let right = canvasSize(comparison.right, comparison.rightInfo)
        return CGSize(width: max(left.width, right.width), height: max(left.height, right.height))
    }

    @ViewBuilder
    private func layer(_ image: SendableImage?, _ info: ImageInfo?, scale: CGFloat) -> some View {
        if let image {
            let size = canvasSize(image, info)
            Image(decorative: image.cgImage, scale: 1)
                .resizable()
                .interpolation(zoom > 2 ? .none : .high)
                .frame(width: size.width * scale, height: size.height * scale)
        } else {
            Text(String(localized: "image.missing", defaultValue: "Missing", comment: "Placeholder when the image doesn't exist on that side"))
                .foregroundStyle(.tertiary)
                .padding()
        }
    }
}

/// Fits content of a given pixel size into the available space (never upscaling more than
/// 4× at "Fit"), multiplied by `zoom`, scrollable when larger than the view.
private struct ZoomableCanvas<Content: View>: View {
    let size: CGSize
    let zoom: Double
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { geometry in
            let padding: CGFloat = 24
            let fit = min(
                (geometry.size.width - padding * 2) / max(size.width, 1),
                (geometry.size.height - padding * 2) / max(size.height, 1),
                4
            )
            let scale = max(0.01, fit) * zoom
            ScrollView([.horizontal, .vertical]) {
                content(scale)
                    .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                    .background(CheckerboardBackground())
                    .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.3)))
                    .padding(padding)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
        }
    }
}

/// The draggable divider of the swipe mode; drag anywhere on the image to move it.
private struct SwipeHandle: View {
    @Binding var position: Double
    let width: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let x = width * position
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: geometry.size.height)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .position(x: x, y: geometry.size.height / 2)
                Circle()
                    .fill(Color.white)
                    .frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.black))
                    .position(x: x, y: geometry.size.height / 2)
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                position = min(1, max(0, value.location.x / max(width, 1)))
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Swipe position")
        .accessibilityValue("\(Int(position * 100)) percent")
        .accessibilityAdjustableAction { direction in
            position = min(1, max(0, position + (direction == .increment ? 0.05 : -0.05)))
        }
    }
}

struct CheckerboardBackground: View {
    /// One tile of four 8 pt squares. Filling with it costs the same at any size, while
    /// drawing each square stalled zoomed-in images (hundreds of thousands of squares).
    private static let tile: Image = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
            NSColor(white: 0.97, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.88, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return Image(nsImage: image)
    }()

    var body: some View {
        Rectangle().fill(ImagePaint(image: Self.tile))
    }
}

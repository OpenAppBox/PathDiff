//
//  Styles.swift
//  PathDiff
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

nonisolated extension NSColor {
    /// A color with separate light and dark appearance values (`0xRRGGBB`).
    ///
    /// AppKit and SwiftUI resolve dynamic colors on whatever thread draws them (for example
    /// asynchronously rendered canvases), so the provider must not be main-actor isolated:
    /// an isolated closure traps when it is called off the main thread.
    static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { @Sendable appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

extension Color {
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: .adaptive(light: light, dark: dark))
    }
}

/// The app's colors. Change colors are tuned to stay legible as text, fills and tints in
/// both appearances.
enum Palette {
    static let modified = Color.adaptive(light: 0xE09400, dark: 0xF2B83D)
    static let moved = Color.adaptive(light: 0x2F6FED, dark: 0x5B9BFF)
    /// Only on the left: missing from the right.
    static let missing = Color.adaptive(light: 0xE0393E, dark: 0xFF6166)
    /// Only on the right: extra.
    static let extra = Color.adaptive(light: 0x23A04A, dark: 0x45C77A)
    static let neutral = Color.adaptive(light: 0x8A8A8F, dark: 0x8D8D93)
    static let edit = Color.adaptive(light: 0xF07A1A, dark: 0xFF9A3D)
    static let history = Color.adaptive(light: 0x7A4FE0, dark: 0xA27BFF)

    /// Raised surfaces (cards, chips) on the window background.
    static let cardFill = Color.adaptive(light: 0xF5F5F7, dark: 0x2A2A2D)
    static let cardStroke = Color.primary.opacity(0.07)
    /// Bars that sit on top of content (pane titles, footers).
    static let barFill = Color.adaptive(light: 0xFAFAFB, dark: 0x232326)
}

extension FileStatus {
    var color: Color {
        switch self {
        case .modified: Palette.modified
        // Left is the reference side: left-only items are missing from the right.
        case .leftOnly: Palette.missing
        case .rightOnly: Palette.extra
        case .identical: Palette.neutral
        case .ignored: Palette.neutral.opacity(0.6)
        }
    }

    var badgeLetter: String? {
        switch self {
        case .modified: String(localized: "M", comment: "One-letter status badge: modified")
        case .leftOnly: String(localized: "L", comment: "One-letter status badge: only in the left folder")
        case .rightOnly: String(localized: "R", comment: "One-letter status badge: only in the right folder")
        case .identical, .ignored: nil
        }
    }

    var label: String {
        switch self {
        case .identical: String(localized: "Identical")
        case .modified: String(localized: "Modified")
        case .leftOnly: String(localized: "Only in Left")
        case .rightOnly: String(localized: "Only in Right")
        case .ignored: String(localized: "Ignored")
        }
    }
}

extension ChangeKind {
    var color: Color {
        switch self {
        case .modified: Palette.modified
        case .moved: Palette.moved
        case .leftOnly: Palette.missing
        case .rightOnly: Palette.extra
        }
    }

    var symbolName: String {
        switch self {
        case .modified: "pencil"
        case .moved: "arrow.turn.down.right"
        case .leftOnly: "minus"
        case .rightOnly: "plus"
        }
    }

    /// Section title using the compared folders' names.
    func title(left: String, right: String) -> String {
        switch self {
        case .modified: String(localized: "Modified")
        case .moved: String(localized: "Moved or Renamed")
        case .leftOnly: String(localized: "Missing from \(right)")
        case .rightOnly: String(localized: "Extra in \(right)")
        }
    }

    /// Two-line labels for summary tiles: "Missing" / "from project-v2".
    func tileTitle() -> String {
        switch self {
        case .modified: String(localized: "Modified")
        case .moved: String(localized: "Moved")
        case .leftOnly: String(localized: "Missing", comment: "Summary tile title; the subtitle below reads “from <folder>”")
        case .rightOnly: String(localized: "Extra", comment: "Summary tile title; the subtitle below reads “in <folder>”")
        }
    }

    func tileSubtitle(right: String) -> String {
        switch self {
        case .modified: String(localized: "in both folders", comment: "Summary tile subtitle under “Modified”")
        case .moved: String(localized: "or renamed", comment: "Summary tile subtitle under “Moved”")
        case .leftOnly: String(localized: "tile.missing.subtitle", defaultValue: "from \(right)", comment: "Summary tile subtitle under “Missing”: missing from this folder; the argument is a folder name")
        case .rightOnly: String(localized: "tile.extra.subtitle", defaultValue: "in \(right)", comment: "Summary tile subtitle under “Extra”: extra in this folder; the argument is a folder name")
        }
    }

    func shortTitle(left: String, right: String) -> String {
        switch self {
        case .modified: String(localized: "Modified")
        case .moved: String(localized: "Moved")
        case .leftOnly: String(localized: "Only in \(left)")
        case .rightOnly: String(localized: "Only in \(right)")
        }
    }
}

/// The blue badge for one-sided items that were matched as a move.
struct MoveBadge: View {
    let match: MoveMatch

    var body: some View {
        Image(systemName: "arrow.turn.down.right")
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(ChangeKind.moved.color.gradient))
            .help(match.isExact ? String(localized: "Moved (identical contents)") : String(localized: "Moved and edited"))
            .accessibilityLabel(match.isExact ? String(localized: "Moved") : String(localized: "Moved and edited"))
    }
}

/// Colors for the side-by-side diff.
enum DiffPalette {
    static let deleted = Palette.missing
    static let added = Palette.extra
    static let modified = Palette.modified

    static let deletedBackground = Palette.missing.opacity(0.10)
    static let addedBackground = Palette.extra.opacity(0.11)
    static let deletedHighlight = Palette.missing.opacity(0.30)
    static let addedHighlight = Palette.extra.opacity(0.30)
    static let deletedGutter = Palette.missing.opacity(0.16)
    static let addedGutter = Palette.extra.opacity(0.17)
    static let fillerBackground = Color.primary.opacity(0.035)
    static let gutterBackground = Palette.barFill
}

/// A small colored status letter used in the sidebar and headers.
struct StatusBadge: View {
    let status: FileStatus

    var body: some View {
        if let letter = status.badgeLetter {
            Text(letter)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(status == .modified ? Color.black.opacity(0.72) : Color.white)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(status.color.gradient))
                .help(status.label)
                .accessibilityLabel(status.label)
        }
    }
}

/// A rounded, gradient-filled square with a white symbol, like the icons in System Settings.
struct IconTile: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(color.gradient)
                    .shadow(color: color.opacity(0.28), radius: size * 0.08, y: size * 0.04)
            }
            .accessibilityHidden(true)
    }
}

/// A small tinted capsule label ("Swift", "Editing", "Undone").
struct TagLabel: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 8.5, weight: .bold))
            }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.13)))
        .fixedSize()
    }
}

/// A keyboard key, for shortcut references.
struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 21)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Palette.cardFill)
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
            }
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.cardStroke))
    }
}

/// A shortcut such as "⌥⌘E" shown as key caps.
struct ShortcutKeys: View {
    let shortcut: String

    var body: some View {
        KeyCap(key: shortcut.replacingOccurrences(of: " ", with: ""))
            .accessibilityLabel(shortcut)
    }
}

extension View {
    /// The raised card surface used across the app.
    func cardBackground(cornerRadius: CGFloat = 12) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Palette.cardFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Palette.cardStroke)
        }
    }
}

/// A big number with a label; clickable when it has an action (filters the sidebar).
struct StatTile: View {
    let title: String
    var subtitle: String?
    let value: Int
    /// Total size of the items, shown under the count when there are any.
    var bytes: Int64?
    let color: Color
    let systemName: String
    var action: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconTile(systemName: systemName, color: value > 0 ? color : Palette.neutral, size: 24)
                Spacer(minLength: 0)
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovered ? 1 : 0)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(DisplayFormat.count(value))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(value > 0 ? .primary : .tertiary)
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let bytes, value > 0 {
                    Text(DisplayFormat.byteCount(bytes))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? color.opacity(0.10) : Palette.cardFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isHovered ? color.opacity(0.45) : Palette.cardStroke)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title) \(subtitle ?? ""): \(DisplayFormat.count(value))"))
        .accessibilityAddTraits(action != nil ? .isButton : [])
    }
}

/// A thin proportional bar: how the compared items split into kinds of change.
struct DistributionBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Int
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 6

    var body: some View {
        let visible = segments.filter { $0.value > 0 }
        let total = max(visible.reduce(0) { $0 + $1.value }, 1)
        GeometryReader { geometry in
            let spacing: CGFloat = visible.count > 1 ? 2 : 0
            let available = max(0, geometry.size.width - spacing * CGFloat(max(visible.count - 1, 0)))
            HStack(spacing: spacing) {
                if visible.isEmpty {
                    Capsule().fill(Color.primary.opacity(0.08))
                } else {
                    ForEach(visible) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(2, available * CGFloat(segment.value) / CGFloat(total)))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Finder icons for files and folders, cached by type.
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(forName name: String, isDirectory: Bool) -> NSImage {
        let key = isDirectory ? "/" : (name as NSString).pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type: UTType = isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}

/// A file or folder's Finder icon at a given size.
struct FileIconView: View {
    let name: String
    let isDirectory: Bool
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: FileIcons.icon(forName: name, isDirectory: isDirectory))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A file icon with a change badge in its corner.
struct BadgedFileIcon: View {
    let node: DiffNode
    var move: MoveMatch?
    var size: CGFloat = 32

    var body: some View {
        FileIconView(name: node.name, isDirectory: node.isDirectory, size: size)
            .overlay(alignment: .bottomTrailing) {
                Group {
                    if let move {
                        MoveBadge(match: move)
                    } else {
                        StatusBadge(status: node.status)
                    }
                }
                .scaleEffect(size >= 30 ? 0.9 : 0.75)
                .offset(x: 4, y: 3)
            }
    }
}

enum DisplayFormat {
    /// The user's real home folder (`NSHomeDirectory()` points into the sandbox container).
    static let homeDirectory: String = {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectory()
    }()

    static func abbreviatedPath(_ url: URL) -> String {
        abbreviatedPath(url.path(percentEncoded: false))
    }

    static func abbreviatedPath(_ path: String) -> String {
        guard path == homeDirectory || path.hasPrefix(homeDirectory + "/") else { return path }
        return "~" + path.dropFirst(homeDirectory.count)
    }

    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }
}

/// Finder and pasteboard helpers shared by context menus and headers.
enum FinderActions {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Layout direction

extension View {
    /// Keeps the left folder on the left in right-to-left languages such as Arabic: "left" and
    /// "right" name the two compared folders, and code reads left to right. Text inside still
    /// uses the app's language; only the arrangement stays fixed.
    func comparisonLayout() -> some View {
        environment(\.layoutDirection, .leftToRight)
    }

    /// Restores the interface's own direction inside a `comparisonLayout()`, for panels such as
    /// an inspector that hold ordinary interface text.
    func interfaceLayout() -> some View {
        environment(\.layoutDirection, NSApplication.shared.userInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }
}

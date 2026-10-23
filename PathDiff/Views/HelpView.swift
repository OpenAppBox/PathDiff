//
//  HelpView.swift
//  PathDiff
//

import AppKit
import SwiftUI

/// The Help ▸ PathDiff Help window: how to read results, sync, and work with large folders.
struct HelpView: View {
    static let windowID = "help"

    var body: some View {
        ScrollView {
            HelpContent()
                .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 560, minHeight: 480)
    }
}

struct HelpContent: View {
    var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                header
                    .padding(.bottom, 8)

                section("Getting Started", systemImage: "folder.badge.plus", color: .accentColor) {
                    paragraph("Drop a folder from Finder on each side of the start screen, or choose them with ⌘O and ⇧⌘O. Once both are chosen, the bar above the diff shows them; click or drop on it to change a folder. Treat the left folder as your reference copy: items that only exist on the left are reported as missing from the right, and items that only exist on the right are reported as extra.")
                    paragraph("Choose the language PathDiff uses in Settings ▸ General ▸ Language. PathDiff relaunches to switch, and your open comparisons reopen.")
                    paragraph("If both folders only wrap a single folder each, as extracted downloads often do, PathDiff offers to compare those inner folders instead.")
                }

                section("Reading the Results", systemImage: "list.bullet.rectangle", color: Palette.modified) {
                    kindRow(.modified, "Modified", "The file exists on both sides with different contents.")
                    kindRow(.moved, "Moved or renamed", "The same file (or a slightly edited one) exists at a different path. Whole renamed folders are shown as one entry.")
                    kindRow(.leftOnly, "Missing", "Only in the left folder, so missing from the right. A missing folder is shown as one entry with its file count.")
                    kindRow(.rightOnly, "Extra", "Only in the right folder.")
                    paragraph("With nothing selected, the overview shows how many items differ in each way; click a count to list just those. The **Changes** view (⌘1) lists every difference grouped by kind; the **Tree** view (⌘2) shows the merged folder structure. Click the counters at the top of the sidebar to show only one kind of change, and type in the search field to filter by name, or by path when the text contains a “/”.")
                }

                section("Reviewing and Syncing", systemImage: "arrow.left.arrow.right", color: Palette.extra) {
                    paragraph("Select a file to see both versions side by side (⌃⌘1) or unified (⌃⌘2), with syntax highlighting and a minimap you can click or drag. Use ⌥⌘↓ and ⌥⌘↑ to jump between changes, and ⌃⌘↓ / ⌃⌘↑ to move to the next or previous changed file.")
                    paragraph("Images, PDFs and SVGs open in the image comparison: side by side, swipe, onion skin, or a difference map that marks every changed pixel.")
                    paragraph("Click **←** or **→** next to a change to copy just that block to the other side. Use the **Copy to** buttons (named after each folder) to copy a whole file or every differing item in a folder; select several items in the sidebar to copy them together. Copies never delete anything on the destination side.")
                    paragraph("**Sync** (⇧⌘Y) handles the selection or everything at once. Pick a direction and what to include: update modified files, copy missing items, apply moves as renames, and, for a full mirror, move extra items to the Trash. Every operation is listed in a dry run first; untick anything you don’t want, then click Sync. The whole sync can be undone with ⌘Z.")
                    paragraph("Click **Edit** (⌥⌘E) to edit both files right in the diff; differences update as you type. **Save** (⌘S) keeps each file’s encoding and line endings, and PathDiff asks before you leave unsaved edits.")
                    paragraph("For moved items, **Apply Move** renames the item on one side so both folders agree on its location.")
                    paragraph("Every copy, move, edit and trash can be undone with ⌘Z. **Sync History** (⇧⌘H) lists every change PathDiff made, with what changed, when and where, and can revert one even after relaunching. Before reverting, it lists files that changed again since.")
                }

                section("Backups, Photos and Videos", systemImage: "externaldrive", color: Palette.missing) {
                    paragraph("To check a backup drive, choose the most complete copy as the left folder and the backup as the right one. **Missing** lists what the backup lacks and **Modified** lists files that differ, each with its total size, so you know how much there is to copy.")
                    paragraph("For drives full of large videos, choose Compare ▸ Compare Files By ▸ **Quick (size and date)**. Files with the same size and modification date then count as identical without being read; everything else is still compared byte by byte. Leave it on **Contents** to be certain that every byte matches.")
                    paragraph("Photos and videos that were reorganized into other folders are found as moves. An edited photo or video that kept its name is paired with its original as **moved and edited**, unless the camera recorded different capture dates.")
                    paragraph("Photos open in the image comparison and videos and audio in two players you can start and pause together. The details panel (ⓘ) lists dimensions, capture date, camera, duration and codecs side by side, marks what differs and which copy is newer, and calculates SHA-256 and MD5 checksums to verify a copy. Use the filter button next to Changes / Tree to list only photos, videos, audio or documents.")
                    paragraph("When each drive has files the other lacks, open **Sync** (⇧⌘Y) and choose **Merge Both Ways**. Each folder gets what only the other has, and for files that differ the newer copy replaces the older one. Nothing is deleted, and files changed on both sides at about the same time are left for you to decide.")
                    paragraph("Files that macOS and Windows leave on drives, such as ._ files, .Spotlight-V100 and Thumbs.db, are ignored by default.")
                }

                section("Large Folders", systemImage: "speedometer", color: Palette.moved) {
                    paragraph("Ignore patterns (Settings ▸ Ignore Patterns) and each folder’s own .gitignore files keep build output, dependencies and other generated files out of the comparison. Right-click an item and choose **Ignore Items Named…** to add a pattern quickly.")
                    paragraph("PathDiff remembers which files matched, so refreshing or reopening a comparison only reads files that changed. Folders are watched while a comparison is open and update on their own. Choose Compare ▸ Rescan Ignoring Remembered Results (⌥⌘R) to re-read everything.")
                    paragraph("Use File ▸ Export Report to save the full list of differences as Markdown or CSV, or File ▸ Export Patch to save every text change as a patch that `git apply` understands.")
                }

                section("Keyboard Shortcuts", systemImage: "keyboard", color: Palette.neutral) {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        ForEach(Self.shortcuts, id: \.0) { shortcut in
                            GridRow {
                                Text(shortcut.0)
                                    .gridColumnAlignment(.leading)
                                HStack(spacing: 6) {
                                    let parts = shortcut.1.components(separatedBy: "  ")
                                    ForEach(Array(parts.enumerated()), id: \.offset) { index, keys in
                                        if index > 0 {
                                            Text(verbatim: "/").foregroundStyle(.tertiary)
                                        }
                                        ShortcutKeys(shortcut: keys)
                                    }
                                }
                            }
                        }
                    }
                }

                openAppBoxFooter
                    .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: 700, alignment: .leading)
    }

    private var openAppBoxFooter: some View {
        HStack(spacing: 12) {
            Image(OpenAppBox.iconImageName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(OpenAppBox.endorsement).font(.callout.weight(.semibold))
                Text("PathDiff is part of OpenAppBox. Open source apps for everyone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Link(destination: OpenAppBox.website) {
                Text(verbatim: "\(OpenAppBox.websiteLabel) ↗")
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity)
    }

    /// Descriptions (localized) and shortcut glyphs (verbatim; alternatives separated by two spaces).
    private static let shortcuts: [(String, String)] = [
        (String(localized: "Choose left / right folder"), "⌘O  ⇧⌘O"),
        (String(localized: "Changes list / folder tree"), "⌘1  ⌘2"),
        (String(localized: "Refresh / rescan ignoring remembered results"), "⌘R  ⌥⌘R"),
        (String(localized: "Swap left and right"), "⌥⌘S"),
        (String(localized: "Show only differences / ignored items"), "⇧⌘D  ⇧⌘I"),
        (String(localized: "Next / previous change"), "⌥⌘↓  ⌥⌘↑"),
        (String(localized: "Next / previous changed file"), "⌃⌘↓  ⌃⌘↑"),
        (String(localized: "Copy current change to right / left"), "⌥⌘→  ⌥⌘←"),
        (String(localized: "Copy selected items to right / left"), "⇧⌥⌘→  ⇧⌥⌘←"),
        (String(localized: "Sync with a dry run"), "⇧⌘Y"),
        (String(localized: "Side-by-side / unified diff"), "⌃⌘1  ⌃⌘2"),
        (String(localized: "Export patch"), "⌥⇧⌘P"),
        (String(localized: "Edit file / save edits"), "⌥⌘E  ⌘S"),
        (String(localized: "Sync history"), "⇧⌘H"),
        (String(localized: "Copy report as Markdown"), "⌥⇧⌘C"),
        (String(localized: "Undo / redo a sync"), "⌘Z  ⇧⌘Z"),
    ]

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text("PathDiff Help").font(.largeTitle.weight(.bold))
                Text("Compare, review and sync two folders — however large.")
                    .foregroundStyle(.secondary)
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    TagLabel(text: String(localized: "Version \(version)"), color: .secondary)
                }
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, systemImage: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(systemName: systemImage, color: color, size: 28)
                Text(title).font(.title3.weight(.semibold))
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 14)
    }

    private func paragraph(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func kindRow(_ kind: ChangeKind, _ title: LocalizedStringKey, _ description: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ChangeKindDot(kind: kind, size: 18)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

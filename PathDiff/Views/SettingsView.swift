//
//  SettingsView.swift
//  PathDiff
//

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case comparison
    case diffView
    case ignorePatterns

    var id: Self { self }
}

struct SettingsView: View {
    @State private var selection: SettingsTab

    init(initialTab: SettingsTab = .general) {
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsView()
            }
            Tab("Comparison", systemImage: "arrow.left.arrow.right.square", value: SettingsTab.comparison) {
                ComparisonSettingsView()
            }
            Tab("Diff View", systemImage: "rectangle.split.2x1", value: SettingsTab.diffView) {
                DiffViewSettingsView()
            }
            Tab("Ignore Patterns", systemImage: "eye.slash", value: SettingsTab.ignorePatterns) {
                IgnorePatternsSettingsView()
            }
        }
        .frame(width: 600, height: 520)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.title).tag(language)
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                if settings.needsRelaunchForLanguage {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Relaunch PathDiff to switch to \(settings.language.title). Open comparisons reopen automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch Now") { settings.relaunch() }
                            .controlSize(.small)
                    }
                } else {
                    Text("English is used for anything not yet translated. You can also choose a language per app in System Settings ▸ General ▸ Language & Region.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                AppearancePicker(selection: $settings.appearance)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows the appearance chosen in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Folders") {
                Toggle(isOn: $settings.watchForChanges) {
                    Text("Watch folders and update automatically")
                    Text("Changes made in other apps appear without refreshing.")
                }
                LabeledContent {
                    Button("Clear") { settings.clearRecentComparisons() }
                        .disabled(settings.recentComparisons.isEmpty)
                } label: {
                    Text("Recent comparisons")
                    Text("\(settings.recentComparisons.count) remembered")
                }
            }

            Section {
                LabeledContent {
                    Button("Manage Subscription…") { subscriptions.manageSubscription() }
                } label: {
                    Text(subscriptions.access == .subscribed ? String(localized: "Your subscription is active") : String(localized: "Not subscribed"))
                    Text("Change or cancel it in your App Store account.")
                }
            } header: {
                Text("Subscription")
            }

            Section {
                LabeledContent {
                    Button("Show History") { openWindow(id: HistoryView.windowID) }
                } label: {
                    Text("Every sync, copy, move, edit and trash")
                    Text("Revert past changes, even after relaunching. ⇧⌘H")
                }
            } header: {
                Text("Sync History")
            } footer: {
                OpenAppBoxBadge()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
        .formStyle(.grouped)
    }
}

/// System / Light / Dark as small window thumbnails, like System Settings.
private struct AppearancePicker: View {
    @Binding var selection: AppAppearance

    var body: some View {
        HStack(spacing: 18) {
            ForEach(AppAppearance.allCases) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    VStack(spacing: 7) {
                        AppearanceThumbnail(appearance: option)
                            .frame(width: 92, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isSelected ? 2.5 : 1)
                            }
                            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                        Text(option.title)
                            .font(.callout.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

private struct AppearanceThumbnail: View {
    let appearance: AppAppearance

    var body: some View {
        switch appearance {
        case .light:
            MiniWindow(dark: false)
        case .dark:
            MiniWindow(dark: true)
        case .system:
            ZStack {
                MiniWindow(dark: false)
                MiniWindow(dark: true)
                    .mask {
                        GeometryReader { geometry in
                            Path { path in
                                path.move(to: CGPoint(x: geometry.size.width * 0.62, y: 0))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                                path.addLine(to: CGPoint(x: geometry.size.width * 0.38, y: geometry.size.height))
                                path.closeSubpath()
                            }
                        }
                    }
            }
        }
    }
}

/// A tiny drawing of a PathDiff window.
private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let background = dark ? Color(white: 0.16) : Color(white: 0.98)
        let sidebar = dark ? Color(white: 0.22) : Color(white: 0.91)
        let line = dark ? Color.white.opacity(0.22) : Color.black.opacity(0.13)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2.5) {
                    Circle().fill(Color.red.opacity(0.85))
                    Circle().fill(Color.yellow.opacity(0.85))
                    Circle().fill(Color.green.opacity(0.85))
                }
                .frame(height: 4.5)
                .padding(.bottom, 3)
                ForEach(0..<4, id: \.self) { index in
                    Capsule().fill(index == 1 ? Color.accentColor : line).frame(width: index == 2 ? 14 : 18, height: 3)
                }
                Spacer(minLength: 0)
            }
            .padding(5)
            .frame(width: 30)
            .frame(maxHeight: .infinity)
            .background(sidebar)
            VStack(alignment: .leading, spacing: 3.5) {
                ForEach(0..<6, id: \.self) { index in
                    HStack(spacing: 3) {
                        Capsule().fill(index == 2 ? Palette.missing.opacity(0.7) : line).frame(width: CGFloat([16, 22, 18, 12, 20, 14][index]), height: 3)
                        Capsule().fill(index == 2 ? Palette.extra.opacity(0.7) : line).frame(width: CGFloat([14, 20, 20, 10, 18, 16][index]), height: 3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.top, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(background)
        }
    }
}

// MARK: - Comparison

private struct ComparisonSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var cacheSize: Int64 = 0

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Compare files by", selection: $settings.comparisonMethod) {
                    ForEach(ComparisonMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
            } header: {
                Text("Files")
            } footer: {
                Text(settings.comparisonMethod == .quick
                     ? String(localized: "Files with the same size and modification date count as identical without being read (dates within 2 seconds match, as FAT and exFAT drives round them). Other files are still compared byte by byte. Best for large photo and video backups.")
                     : String(localized: "Every file present on both sides is read and compared byte by byte, so an edit is never missed. Files of different sizes differ without being read."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Text") {
                Toggle(isOn: $settings.ignoreWhitespace) {
                    Text("Ignore whitespace")
                    Text("Lines that differ only in spaces and tabs count as equal.")
                }
                Toggle(isOn: $settings.ignoreLineEndings) {
                    Text("Ignore line ending differences")
                    Text("Files that differ only in CRLF vs. LF count as equal.")
                }
            }
            Section {
                Toggle("Respect .gitignore files", isOn: $settings.respectsGitIgnore)
                Toggle("Use the git index to skip unchanged files", isOn: $settings.usesGitIndex)
                Toggle("Detect moved and renamed files and folders", isOn: $settings.detectsMoves)
            } header: {
                Text("Repositories")
            } footer: {
                Text("Folders downloaded from repositories usually contain .gitignore files; respecting them hides build output and other generated files. In a git working copy, files git knows are unchanged are compared without being read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    HStack {
                        Text(DisplayFormat.byteCount(cacheSize))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("Clear") {
                            if let directory = ComparisonCacheStore.defaultDirectory {
                                ComparisonCacheStore(directory: directory).removeAll()
                            }
                            cacheSize = 0
                        }
                        .disabled(cacheSize == 0)
                    }
                } label: {
                    Text("Remembered comparison results")
                }
            } header: {
                Text("Performance")
            } footer: {
                Text("PathDiff remembers which files matched, keyed by size, modification date and file identity, so reopening a large comparison only reads files that changed. Compare ▸ Rescan Ignoring Remembered Results (⌥⌘R) re-reads everything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            cacheSize = await Self.measureCache()
        }
    }

    @concurrent
    private static func measureCache() async -> Int64 {
        guard let directory = ComparisonCacheStore.defaultDirectory else { return 0 }
        return ComparisonCacheStore(directory: directory).totalSize()
    }
}

// MARK: - Diff view

private struct DiffViewSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Layout") {
                Picker("Layout", selection: $settings.diffLayout) {
                    Label("Side by Side", systemImage: "rectangle.split.2x1").tag(DiffLayout.sideBySide)
                    Label("Unified", systemImage: "rectangle.grid.1x2").tag(DiffLayout.unified)
                }
                .pickerStyle(.segmented)
                Toggle("Show minimap", isOn: $settings.showsMinimap)
                Toggle("Wrap long lines", isOn: $settings.wrapLines)
                Toggle("Collapse unchanged lines", isOn: $settings.collapseUnchanged)
                Stepper(value: $settings.contextLines, in: 0...20) {
                    LabeledContent("Context lines around changes", value: "\(settings.contextLines)")
                }
                .disabled(!settings.collapseUnchanged)
            }
            Section("Text") {
                Toggle("Syntax highlighting", isOn: $settings.highlightsSyntax)
                Stepper(value: $settings.fontSize, in: 8...28, step: 1) {
                    LabeledContent("Text size", value: "\(Int(settings.fontSize)) pt")
                }
                CodeSample(fontSize: settings.fontSize, highlightsSyntax: settings.highlightsSyntax)
            }
        }
        .formStyle(.grouped)
    }
}

/// A two-line diff preview at the chosen text size.
private struct CodeSample: View {
    let fontSize: Double
    let highlightsSyntax: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line(number: 7, keyword: "var", name: " retries = ", value: "3", background: DiffPalette.deletedBackground, marker: DiffPalette.deleted)
            line(number: 7, keyword: "var", name: " retries = ", value: "5", background: DiffPalette.addedBackground, marker: DiffPalette.added)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.cardStroke))
        .accessibilityHidden(true)
    }

    private func line(number: Int, keyword: String, name: String, value: String, background: Color, marker: Color) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: "\(number)")
                .foregroundStyle(marker)
                .frame(width: fontSize * 2.4, alignment: .trailing)
                .padding(.trailing, 6)
            Rectangle().fill(marker).frame(width: 3)
            // Code, not prose: the "%@%@%@" key this extracts is marked as not translatable.
            Text("\(Text(verbatim: keyword).foregroundStyle(highlightsSyntax ? SyntaxPalette.color(for: .keyword) : .primary))\(name)\(Text(verbatim: value).foregroundStyle(highlightsSyntax ? SyntaxPalette.color(for: .number) : .primary))")
                .padding(.leading, 8)
            Spacer(minLength: 0)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .padding(.vertical, 2)
        .background(background)
    }
}

// MARK: - Ignore patterns

/// A `.gitignore`-style editor: one pattern per line.
private struct IgnorePatternsSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Items matching these patterns are skipped when scanning. One pattern per line; lines starting with # are comments.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                TagLabel(text: String(localized: "\(activePatternCount) patterns"), color: .accentColor)
            }

            TextEditor(text: $text)
                .font(.system(size: 12.5, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))

            VStack(alignment: .leading, spacing: 8) {
                Text("Syntax")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    GridRow {
                        example("node_modules", String(localized: "any depth", comment: "Ignore pattern example"))
                        example("*.log", String(localized: "wildcard", comment: "Ignore pattern example"))
                        example("build/", String(localized: "folders only", comment: "Ignore pattern example"))
                    }
                    GridRow {
                        example("/docs/gen", String(localized: "path from root", comment: "Ignore pattern example"))
                        example("src/**/out", String(localized: "any folders", comment: "Ignore pattern example"))
                        example("# note", String(localized: "comment", comment: "Ignore pattern example"))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(cornerRadius: 10)

            HStack {
                Text("Each folder’s own .gitignore files apply too (Comparison settings).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { settings.resetIgnorePatterns() }
            }
        }
        .padding(20)
        .onAppear { text = settings.ignorePatterns.joined(separator: "\n") }
        .onChange(of: text) { _, newValue in
            let patterns = Self.parse(newValue)
            if patterns != settings.ignorePatterns { settings.ignorePatterns = patterns }
        }
        .onChange(of: settings.ignorePatterns) { _, patterns in
            if Self.parse(text) != patterns { text = patterns.joined(separator: "\n") }
        }
    }

    private var activePatternCount: Int {
        settings.ignorePatterns.filter { !$0.hasPrefix("#") }.count
    }

    private func example(_ pattern: String, _ meaning: String) -> some View {
        HStack(spacing: 6) {
            Text(pattern)
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
            Text(meaning)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

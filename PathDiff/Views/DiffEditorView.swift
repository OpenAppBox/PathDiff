//
//  DiffEditorView.swift
//  PathDiff
//

import AppKit
import SwiftUI

/// Both sides of a text file as editors, with differences highlighted live as you type.
/// Save writes the edited sides (⌘S); Done returns to the diff.
struct DiffEditorView: View {
    let viewModel: DiffViewModel
    let session: EditSession

    @Environment(AppSettings.self) private var settings
    @State private var scrollSync = EditorScrollSync()
    @State private var syncsScrolling = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                pane(.left)
                Divider()
                pane(.right)
            }
        }
        .onChange(of: syncsScrolling) { _, enabled in scrollSync.isEnabled = enabled }
    }

    private var header: some View {
        HStack(spacing: 10) {
            FileIconView(name: session.name, isDirectory: false, size: 30)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(Palette.edit.gradient))
                        .offset(x: 4, y: 3)
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.name).font(.headline).lineLimit(1)
                    TagLabel(text: String(localized: "Editing"), color: Palette.edit, systemImage: "pencil")
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            Toggle("Sync Scrolling", isOn: $syncsScrolling)
                .toggleStyle(.switch)
                .controlSize(.mini)
            .help(syncsScrolling ? String(localized: "Scrolling one side scrolls the other (on)") : String(localized: "Scroll the sides independently (sync off)"))
            Button("Revert") { viewModel.revertEdits() }
                .disabled(!session.isDirty || session.isSaving)
                .help("Discard unsaved edits")
            Button {
                viewModel.saveEdits()
            } label: {
                Text(session.isSaving ? String(localized: "Saving…") : String(localized: "Save"))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!session.isDirty || session.isSaving)
            .help("Save the edited sides (⌘S). Saving can be undone or reverted from the History.")
            Button("Done") { viewModel.endEditing() }
                .help("Back to the diff (⌥⌘E)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var statusText: String {
        let changes = session.analysis.changeCount
        var parts = [changes == 0 ? String(localized: "No differences") : String(localized: "\(changes) differences")]
        let edited = Side.allCases.filter { session.isDirty($0) }.map { viewModel.sideName($0) }
        if !edited.isEmpty { parts.append(String(localized: "unsaved edits in \(edited.formatted(.list(type: .and)))")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func pane(_ side: Side) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: side == .left ? "l.square.fill" : "r.square.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(viewModel.sideName(side))
                    .font(.caption.weight(.semibold))
                if session.isDirty(side) {
                    TagLabel(text: String(localized: "Edited"), color: Palette.edit)
                        .help("Unsaved edits")
                }
                if let url = session.url(side) {
                    Text(DisplayFormat.abbreviatedPath(url))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(DiffPalette.gutterBackground)
            Divider()
            if let text = session.text(side) {
                CodeEditor(
                    text: text,
                    revision: session.revision,
                    changedLines: side == .left ? session.analysis.leftChangedLines : session.analysis.rightChangedLines,
                    changeColor: side == .left ? NSColor.systemRed.withAlphaComponent(0.14) : NSColor.systemGreen.withAlphaComponent(0.16),
                    syntax: side == .left ? session.analysis.leftSyntax : session.analysis.rightSyntax,
                    analysisRevision: session.analysisRevision,
                    fontSize: settings.fontSize,
                    scrollSync: scrollSync
                ) { newText in
                    viewModel.updateEditedText(newText, side: side)
                }
            } else {
                ContentUnavailableView(
                    "Not in \(viewModel.sideName(side))",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("This file only exists on the other side. Copy it over first to edit both versions.")
                )
            }
        }
        .frame(maxWidth: .infinity)
    }
}

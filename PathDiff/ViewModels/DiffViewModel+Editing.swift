//
//  DiffViewModel+Editing.swift
//  PathDiff
//

import AppKit
import Foundation

/// A text file being edited in the diff view: both sides' edited text, the versions they
/// were loaded from, and the live analysis of the edits.
struct EditSession {
    let nodeID: String
    let name: String
    /// `nil` for a side where the file doesn't exist (that side isn't editable).
    let leftURL: URL?
    let rightURL: URL?
    let language: SyntaxLanguage?
    var leftOriginal: TextDocument? { didSet { leftOriginalText = leftOriginal?.editorText } }
    var rightOriginal: TextDocument? { didSet { rightOriginalText = rightOriginal?.editorText } }
    /// The originals' `editorText`, kept so checking for edits on every keystroke doesn't
    /// rebuild it (expensive for large files).
    var leftOriginalText: String?
    var rightOriginalText: String?
    var leftText: String?
    var rightText: String?
    /// Bumped when the editors must replace their text (revert, normalization after save).
    var revision = 0
    var analysis = EditAnalysis()
    /// Bumped whenever `analysis` is replaced.
    var analysisRevision = 0
    var isSaving = false

    func text(_ side: Side) -> String? { side == .left ? leftText : rightText }
    func url(_ side: Side) -> URL? { side == .left ? leftURL : rightURL }
    func original(_ side: Side) -> TextDocument? { side == .left ? leftOriginal : rightOriginal }

    func isDirty(_ side: Side) -> Bool {
        guard let original = original(side), let text = text(side) else { return false }
        return text != ((side == .left ? leftOriginalText : rightOriginalText) ?? original.editorText)
    }

    var isDirty: Bool { isDirty(.left) || isDirty(.right) }
}

/// "Save changes?" before leaving unsaved edits.
struct EditGuard: Identifiable {
    let id = UUID()
    let name: String
    let onSave: () -> Void
    let onDiscard: () -> Void
}

/// Editing files directly in the diff view.
extension DiffViewModel {
    /// Larger files open read-only.
    static let maximumEditableBytes: Int64 = 10 * 1024 * 1024
    /// Windows with an edit session, so quitting can warn about unsaved edits.
    private static let editingViewModels = NSHashTable<DiffViewModel>.weakObjects()

    static var hasUnsavedEdits: Bool {
        editingViewModels.allObjects.contains { $0.editSession?.isDirty == true }
    }

    var canEdit: Bool {
        guard case .text(let diff) = activeDiff, let node = activeDiffNode, !isPerformingFileOperation,
              diff.left != nil || diff.right != nil
        else { return false }
        return (node.leftMetadata?.size ?? 0) <= Self.maximumEditableBytes && (node.rightMetadata?.size ?? 0) <= Self.maximumEditableBytes
    }

    func toggleEditing() {
        if editSession == nil { beginEditing() } else { endEditing() }
    }

    func beginEditing() {
        guard editSession == nil, canEdit, case .text(let diff) = activeDiff,
              let node = activeDiffNode, let selected = selectedNode
        else { return }
        editSession = EditSession(
            nodeID: selected.id,
            name: selected.name,
            leftURL: diff.left == nil ? nil : node.leftURL,
            rightURL: diff.right == nil ? nil : node.rightURL,
            language: settings.highlightsSyntax ? SyntaxLanguage.detect(path: node.relativePath) : nil,
            leftOriginal: diff.left,
            rightOriginal: diff.right,
            leftOriginalText: diff.left?.editorText,
            rightOriginalText: diff.right?.editorText,
            leftText: diff.left?.editorText,
            rightText: diff.right?.editorText
        )
        Self.editingViewModels.add(self)
        analyzeEdits(after: .zero)
    }

    func updateEditedText(_ text: String, side: Side) {
        guard var session = editSession, session.text(side) != text else { return }
        if side == .left { session.leftText = text } else { session.rightText = text }
        editSession = session
        analyzeEdits(after: .milliseconds(250))
    }

    /// Discards unsaved edits, back to the versions on disk.
    func revertEdits() {
        guard var session = editSession else { return }
        session.leftText = session.leftOriginal?.editorText
        session.rightText = session.rightOriginal?.editorText
        session.revision += 1
        editSession = session
        analyzeEdits(after: .zero)
    }

    /// Leaves editing, asking first if there are unsaved edits.
    func endEditing() {
        requestLeavingEdits {}
    }

    /// Runs `action` after the edit session ended: immediately when nothing is unsaved,
    /// otherwise once the user saved or discarded the edits.
    func requestLeavingEdits(_ action: @escaping () -> Void) {
        guard let session = editSession else {
            action()
            return
        }
        guard session.isDirty else {
            closeEditSession()
            action()
            return
        }
        editGuard = EditGuard(name: session.name) { [weak self] in
            self?.saveEdits { [weak self] in
                self?.closeEditSession()
                action()
            }
        } onDiscard: { [weak self] in
            self?.closeEditSession()
            action()
        }
    }

    private func closeEditSession() {
        editAnalysisTask?.cancel()
        editSession = nil
        Self.editingViewModels.remove(self)
    }

    private func analyzeEdits(after delay: Duration) {
        editAnalysisTask?.cancel()
        guard let session = editSession else { return }
        let left = session.leftText
        let right = session.rightText
        let language = session.language
        let options = settings.diffOptions
        editAnalysisTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            let analysis = await EditAnalysis.analyze(left: left, right: right, options: options, language: language)
            guard let self, !Task.isCancelled,
                  self.editSession?.leftText == left, self.editSession?.rightText == right
            else { return }
            self.editSession?.analysis = analysis
            self.editSession?.analysisRevision += 1
        }
    }

    // MARK: - Saving

    /// Writes the edited sides. Refuses (offering to overwrite) when a file changed on disk
    /// since it was loaded. Saving is recorded in the history and can be undone.
    func saveEdits(overwritingExternalChanges force: Bool = false, then action: (() -> Void)? = nil) {
        guard var session = editSession, !session.isSaving else { return }
        guard session.isDirty else {
            action?()
            return
        }
        struct Write {
            let side: Side
            let url: URL
            let original: TextDocument
            let updated: TextDocument
            /// The editor's text when saving started.
            let savedText: String
        }
        let writes = Side.allCases.compactMap { side -> Write? in
            guard session.isDirty(side), let url = session.url(side), let original = session.original(side), let text = session.text(side) else { return nil }
            return Write(side: side, url: url, original: original, updated: original.replacingText(text), savedText: text)
        }
        guard let first = writes.first else { return }

        session.isSaving = true
        editSession = session
        let service = fileService
        let history = HistoryContext(
            kind: .edit,
            title: writes.count == 2
                ? String(localized: "Edit \(session.name) (both sides)")
                : String(localized: "Edit \(session.name) in \(sideName(first.side))"),
            direction: nil,
            side: first.side,
            items: writes.map { HistoryItem(action: .updated, path: relativePath(of: $0.url, side: $0.side), previousPath: nil, side: $0.side) }
        )
        performFileOperation(actionName: String(localized: "undo.save", defaultValue: "Save", comment: "Undo action name, shown after “Undo”: use a noun where the language prefers one"), refreshPaths: activeDiffPaths, history: history, reportsErrors: false) { [weak self] error in
            guard let self else { return }
            self.editSession?.isSaving = false
            if let error {
                self.handleSaveError(error, then: action)
                return
            }
            for write in writes {
                let text = write.updated.editorText
                // Replace the editor's text with the saved form only if nothing was typed
                // while saving; otherwise keep the typing (the file then shows as edited).
                if write.side == .left {
                    self.editSession?.leftOriginal = write.updated
                    if self.editSession?.leftText == write.savedText, write.savedText != text {
                        self.editSession?.leftText = text
                        self.editSession?.revision += 1
                    }
                } else {
                    self.editSession?.rightOriginal = write.updated
                    if self.editSession?.rightText == write.savedText, write.savedText != text {
                        self.editSession?.rightText = text
                        self.editSession?.revision += 1
                    }
                }
            }
            action?()
        } operation: {
            // Check every file before writing any, so a conflict never leaves a half save.
            if !force {
                for write in writes {
                    if await !service.isUnchanged(write.url, expected: write.original) {
                        throw FileOperationError.fileChangedOnDisk(write.url.lastPathComponent)
                    }
                }
            }
            let snapshots = try await service.capture(writes.map(\.url))
            for write in writes {
                try await service.write(write.updated, to: write.url, expecting: nil)
            }
            return snapshots
        }
    }

    private func handleSaveError(_ error: Error, then action: (() -> Void)?) {
        guard case FileOperationError.fileChangedOnDisk(let name) = error else {
            alert = AlertMessage(title: String(localized: "Couldn’t Save"), message: error.localizedDescription)
            return
        }
        pendingConfirmation = PendingConfirmation(
            title: String(localized: "“\(name)” Changed on Disk"),
            message: String(localized: "The file was changed by another app after you started editing. Overwrite it with your version? You can still revert this from the History."),
            confirmTitle: String(localized: "Overwrite"),
            isDestructive: true
        ) { [weak self] in
            self?.saveEdits(overwritingExternalChanges: true, then: action)
        }
    }
}

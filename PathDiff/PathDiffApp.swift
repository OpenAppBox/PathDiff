//
//  PathDiffApp.swift
//  PathDiff
//
//  Created by OpenAppBox on 4.10.2026.
//

import SwiftUI

@main
struct PathDiffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings.shared
    @State private var subscriptions = SubscriptionStore.shared

    var body: some Scene {
        WindowGroup(for: ComparisonRequest.self) { $request in
            SubscriptionGate(store: subscriptions) {
                MainView(request: request)
            }
            .environment(settings)
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            PathDiffCommands(settings: settings)
        }

        Window("Sync History", id: HistoryView.windowID) {
            HistoryView()
        }
        .defaultSize(width: 980, height: 640)

        Window("PathDiff Help", id: HelpView.windowID) {
            HelpView()
        }
        .defaultSize(width: 640, height: 720)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(settings)
                .environment(subscriptions)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window appears, so nothing flashes in the wrong appearance.
        AppSettings.shared.applyAppearance()
        SubscriptionStore.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if DiffViewModel.hasUnsavedEdits {
            let alert = NSAlert()
            alert.messageText = String(localized: "You have unsaved edits.")
            alert.informativeText = String(localized: "Quit anyway and lose them, or cancel and save them first (⌘S).")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Quit Without Saving"))
            alert.buttons.last?.hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        // A copy or sync still running, or a history backup not yet on disk, would otherwise
        // be cut off: files changed, but nothing recorded to undo or revert them.
        Task { @MainActor in
            await DiffViewModel.finishFileOperations()
            await SyncHistory.shared.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

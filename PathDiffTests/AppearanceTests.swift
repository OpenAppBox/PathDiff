//
//  AppearanceTests.swift
//  PathDiffTests
//

import AppKit
import Foundation
import Testing

@Suite("Appearance")
struct AppearanceTests {
    /// Regression: switching between light and dark crashed because the adaptive colors'
    /// provider closure was main-actor isolated and SwiftUI resolves colors off the main
    /// thread (asynchronously rendered canvases such as the minimap).
    @Test func adaptiveColorsResolveOffTheMainThread() async {
        nonisolated(unsafe) let colors: [NSColor] = [
            .adaptive(light: 0x112233, dark: 0x44AA66),
            SyntaxPalette.nsColor(for: .keyword),
            SyntaxPalette.nsColor(for: .comment),
        ]
        let greens: [CGFloat] = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                var result: [CGFloat] = []
                NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                    result = colors.compactMap { $0.usingColorSpace(.sRGB)?.greenComponent }
                }
                continuation.resume(returning: result)
            }
        }
        #expect(greens.count == colors.count)
        #expect(abs((greens.first ?? 0) - CGFloat(0xAA) / 255) < 0.01)
    }

    @Test @MainActor func adaptiveColorsFollowTheAppearance() {
        let color = NSColor.adaptive(light: 0xFF0000, dark: 0x00FF00)
        var light: CGFloat = 0
        var dark: CGFloat = 0
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            light = color.usingColorSpace(.sRGB)?.redComponent ?? 0
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            dark = color.usingColorSpace(.sRGB)?.greenComponent ?? 0
        }
        #expect(light > 0.99)
        #expect(dark > 0.99)
    }

    @Test @MainActor func switchingAppearanceUpdatesTheApplication() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "PathDiffTests-\(UUID().uuidString)")!)
        let original = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = original }
        for appearance in [AppAppearance.dark, .light, .system, .dark] {
            settings.appearance = appearance
            #expect(NSApplication.shared.appearance?.name == appearance.nsAppearance?.name)
        }
    }
}

//
//  AppSettings.swift
//  PathDiff
//

import AppKit
import Foundation
import Observation

/// Everything that changes which items are found and how they are compared.
/// A change requires a rescan.
nonisolated struct ScanConfiguration: Hashable, Sendable {
    var ignorePatterns: [String]
    var options: DiffOptions
    var respectsGitIgnore: Bool
    var usesGitIndex: Bool

    var rules: ScanRules {
        var rules = ScanRules(matcher: IgnoreMatcher(patterns: ignorePatterns), respectsGitIgnore: respectsGitIgnore)
        rules.usesGitIndex = usesGitIndex
        return rules
    }
}

/// The app's light/dark appearance.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: String(localized: "System", comment: "Appearance: follow the system setting")
        case .light: String(localized: "Light", comment: "Appearance")
        case .dark: String(localized: "Dark", comment: "Appearance")
        }
    }

    /// `nil` follows the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The language PathDiff's interface uses. English is the base language and the fallback
/// for anything not translated.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case indonesian = "id"
    case danish = "da"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case dutch = "nl"
    case norwegian = "nb"
    case polish = "pl"
    case portugueseBrazil = "pt-BR"
    case finnish = "fi"
    case swedish = "sv"
    case vietnamese = "vi"
    case turkish = "tr"
    case russian = "ru"
    case arabic = "ar"
    case hindi = "hi"
    case thai = "th"
    case japanese = "ja"
    case korean = "ko"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"

    var id: Self { self }

    /// Each language is named in itself, so people can find theirs whatever is showing.
    var title: String {
        switch self {
        case .system: String(localized: "System Language")
        case .english: "English"
        case .indonesian: "Bahasa Indonesia"
        case .danish: "Dansk"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .french: "Français"
        case .italian: "Italiano"
        case .dutch: "Nederlands"
        case .norwegian: "Norsk bokmål"
        case .polish: "Polski"
        case .portugueseBrazil: "Português (Brasil)"
        case .finnish: "Suomi"
        case .swedish: "Svenska"
        case .vietnamese: "Tiếng Việt"
        case .turkish: "Türkçe"
        case .russian: "Русский"
        case .arabic: "العربية"
        case .hindi: "हिन्दी"
        case .thai: "ไทย"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .chineseSimplified: "简体中文"
        case .chineseTraditional: "繁體中文"
        }
    }
}

/// How a text file's changes are laid out.
enum DiffLayout: String, CaseIterable, Identifiable {
    case sideBySide
    case unified

    var id: Self { self }
    var title: String { self == .sideBySide ? String(localized: "Side by Side") : String(localized: "Unified") }
}

/// How the sidebar presents the comparison.
enum SidebarMode: String, CaseIterable, Identifiable {
    /// Flat list grouped by kind of change; best for large comparisons.
    case changes
    /// The merged folder tree.
    case tree

    var id: Self { self }
    var title: String { self == .changes ? String(localized: "Changes", comment: "Sidebar mode: list of changes") : String(localized: "Tree", comment: "Sidebar mode: folder tree") }
}

/// App-wide preferences shared by every comparison window, persisted in `UserDefaults`.
@Observable
final class AppSettings {
    static let shared = AppSettings()
    static let maximumRecentComparisons = 12

    private enum Keys {
        static let ignorePatterns = "ignorePatterns"
        static let ignoreWhitespace = "ignoreWhitespace"
        static let ignoreLineEndings = "ignoreLineEndings"
        static let showOnlyDifferences = "showOnlyDifferences"
        static let fontSize = "fontSize"
        static let wrapLines = "wrapLines"
        static let collapseUnchanged = "collapseUnchanged"
        static let contextLines = "contextLines"
        static let watchForChanges = "watchForChanges"
        static let recentComparisons = "recentComparisons"
        static let respectsGitIgnore = "respectsGitIgnore"
        static let usesGitIndex = "usesGitIndex"
        static let detectsMoves = "detectsMoves"
        static let sidebarMode = "sidebarMode"
        static let diffLayout = "diffLayout"
        static let highlightsSyntax = "highlightsSyntax"
        static let showsMinimap = "showsMinimap"
        static let appearance = "appearance"
        static let ignorePatternsRevision = "ignorePatternsRevision"
        static let comparisonMethod = "comparisonMethod"
        static let language = "language"
        /// Read by Foundation at launch to pick the app's localization.
        static let appleLanguages = "AppleLanguages"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var ignorePatterns: [String] {
        didSet { defaults.set(ignorePatterns, forKey: Keys.ignorePatterns) }
    }
    var ignoreWhitespace: Bool {
        didSet { defaults.set(ignoreWhitespace, forKey: Keys.ignoreWhitespace) }
    }
    var ignoreLineEndings: Bool {
        didSet { defaults.set(ignoreLineEndings, forKey: Keys.ignoreLineEndings) }
    }
    /// Takes effect at the next launch: macOS picks an app's localization when it starts.
    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
            if language == .system {
                defaults.removeObject(forKey: Keys.appleLanguages)
            } else {
                defaults.set([language.rawValue], forKey: Keys.appleLanguages)
            }
        }
    }
    /// The language chosen when the app launched, i.e. the one currently showing.
    @ObservationIgnored let launchLanguage: AppLanguage

    var needsRelaunchForLanguage: Bool { language != launchLanguage }

    var comparisonMethod: ComparisonMethod {
        didSet { defaults.set(comparisonMethod.rawValue, forKey: Keys.comparisonMethod) }
    }
    var showOnlyDifferences: Bool {
        didSet { defaults.set(showOnlyDifferences, forKey: Keys.showOnlyDifferences) }
    }
    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }
    var wrapLines: Bool {
        didSet { defaults.set(wrapLines, forKey: Keys.wrapLines) }
    }
    var collapseUnchanged: Bool {
        didSet { defaults.set(collapseUnchanged, forKey: Keys.collapseUnchanged) }
    }
    var contextLines: Int {
        didSet { defaults.set(contextLines, forKey: Keys.contextLines) }
    }
    var watchForChanges: Bool {
        didSet { defaults.set(watchForChanges, forKey: Keys.watchForChanges) }
    }
    var respectsGitIgnore: Bool {
        didSet { defaults.set(respectsGitIgnore, forKey: Keys.respectsGitIgnore) }
    }
    var usesGitIndex: Bool {
        didSet { defaults.set(usesGitIndex, forKey: Keys.usesGitIndex) }
    }
    var detectsMoves: Bool {
        didSet { defaults.set(detectsMoves, forKey: Keys.detectsMoves) }
    }
    var sidebarMode: SidebarMode {
        didSet { defaults.set(sidebarMode.rawValue, forKey: Keys.sidebarMode) }
    }
    var diffLayout: DiffLayout {
        didSet { defaults.set(diffLayout.rawValue, forKey: Keys.diffLayout) }
    }
    var highlightsSyntax: Bool {
        didSet { defaults.set(highlightsSyntax, forKey: Keys.highlightsSyntax) }
    }
    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }
    var showsMinimap: Bool {
        didSet { defaults.set(showsMinimap, forKey: Keys.showsMinimap) }
    }
    private(set) var recentComparisons: [RecentComparison] {
        didSet { defaults.set(try? JSONEncoder().encode(recentComparisons), forKey: Keys.recentComparisons) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.showOnlyDifferences: true,
            Keys.fontSize: 12.0,
            Keys.wrapLines: true,
            Keys.collapseUnchanged: false,
            Keys.contextLines: 3,
            Keys.watchForChanges: true,
            Keys.respectsGitIgnore: true,
            Keys.usesGitIndex: true,
            Keys.detectsMoves: true,
            Keys.highlightsSyntax: true,
            Keys.showsMinimap: true,
        ])
        ignorePatterns = Self.migratedIgnorePatterns(defaults)
        ignoreWhitespace = defaults.bool(forKey: Keys.ignoreWhitespace)
        ignoreLineEndings = defaults.bool(forKey: Keys.ignoreLineEndings)
        language = defaults.string(forKey: Keys.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
        launchLanguage = defaults.string(forKey: Keys.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
        comparisonMethod = defaults.string(forKey: Keys.comparisonMethod).flatMap(ComparisonMethod.init(rawValue:)) ?? .contents
        showOnlyDifferences = defaults.bool(forKey: Keys.showOnlyDifferences)
        fontSize = defaults.double(forKey: Keys.fontSize)
        wrapLines = defaults.bool(forKey: Keys.wrapLines)
        collapseUnchanged = defaults.bool(forKey: Keys.collapseUnchanged)
        contextLines = defaults.integer(forKey: Keys.contextLines)
        watchForChanges = defaults.bool(forKey: Keys.watchForChanges)
        respectsGitIgnore = defaults.bool(forKey: Keys.respectsGitIgnore)
        usesGitIndex = defaults.bool(forKey: Keys.usesGitIndex)
        detectsMoves = defaults.bool(forKey: Keys.detectsMoves)
        sidebarMode = defaults.string(forKey: Keys.sidebarMode).flatMap(SidebarMode.init(rawValue:)) ?? .changes
        diffLayout = defaults.string(forKey: Keys.diffLayout).flatMap(DiffLayout.init(rawValue:)) ?? .sideBySide
        highlightsSyntax = defaults.bool(forKey: Keys.highlightsSyntax)
        showsMinimap = defaults.bool(forKey: Keys.showsMinimap)
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        recentComparisons = defaults.data(forKey: Keys.recentComparisons)
            .flatMap { try? JSONDecoder().decode([RecentComparison].self, from: $0) } ?? []
    }

    var diffOptions: DiffOptions {
        DiffOptions(ignoreWhitespace: ignoreWhitespace, ignoreLineEndings: ignoreLineEndings, comparisonMethod: comparisonMethod)
    }

    var scanConfiguration: ScanConfiguration {
        ScanConfiguration(
            ignorePatterns: ignorePatterns,
            options: diffOptions,
            respectsGitIgnore: respectsGitIgnore,
            usesGitIndex: usesGitIndex
        )
    }

    /// Opens a new instance of the app (which picks up the chosen language) and quits this
    /// one. Refuses while edits are unsaved, since quitting would ask about them anyway.
    func relaunch() {
        guard !DiffViewModel.hasUnsavedEdits else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Save or discard your edits first.")
            alert.informativeText = String(localized: "PathDiff needs to restart to change its language.")
            alert.runModal()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if error == nil { NSApplication.shared.terminate(nil) }
            }
        }
    }

    /// Applies the appearance to every window, sheet and panel of the app.
    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    /// A customized pattern list (stored by an older version) gets the patterns added to the
    /// defaults since then, once; an untouched list simply follows the current defaults.
    private static func migratedIgnorePatterns(_ defaults: UserDefaults) -> [String] {
        let revision = defaults.integer(forKey: Keys.ignorePatternsRevision)
        defaults.set(IgnoreMatcher.defaultPatternsRevision, forKey: Keys.ignorePatternsRevision)
        guard let stored = defaults.stringArray(forKey: Keys.ignorePatterns) else {
            return IgnoreMatcher.defaultPatterns
        }
        var patterns = stored
        let added = IgnoreMatcher.patternsAddedInRevision
            .filter { $0.key > revision }
            .sorted { $0.key < $1.key }
            .flatMap(\.value)
        for pattern in added where !patterns.contains(pattern) {
            patterns.append(pattern)
        }
        if patterns != stored {
            defaults.set(patterns, forKey: Keys.ignorePatterns)
        }
        return patterns
    }

    func resetIgnorePatterns() {
        ignorePatterns = IgnoreMatcher.defaultPatterns
    }

    func addIgnorePattern(_ pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !ignorePatterns.contains(trimmed) else { return }
        ignorePatterns.append(trimmed)
    }

    // MARK: Recent comparisons

    func recordRecentComparison(left: URL, right: URL) {
        guard let leftBookmark = BookmarkStore.bookmark(for: left),
              let rightBookmark = BookmarkStore.bookmark(for: right)
        else { return }
        let leftPath = left.path(percentEncoded: false)
        let rightPath = right.path(percentEncoded: false)
        var recents = recentComparisons.filter { !($0.leftPath == leftPath && $0.rightPath == rightPath) }
        recents.insert(RecentComparison(
            leftPath: leftPath,
            rightPath: rightPath,
            leftBookmark: leftBookmark,
            rightBookmark: rightBookmark,
            lastOpened: .now
        ), at: 0)
        recentComparisons = Array(recents.prefix(Self.maximumRecentComparisons))
    }

    func removeRecentComparison(_ recent: RecentComparison) {
        recentComparisons.removeAll { $0.id == recent.id }
    }

    func clearRecentComparisons() {
        recentComparisons = []
    }
}

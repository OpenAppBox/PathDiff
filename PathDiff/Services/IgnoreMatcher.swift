//
//  IgnoreMatcher.swift
//  PathDiff
//

import Foundation

/// Decides which items are excluded from a comparison.
///
/// Pattern syntax (a pragmatic subset of `.gitignore`):
/// - `node_modules` — a plain name matches an item with that name at any depth.
/// - `*.log`, `temp?` — `*`, `?` and `[abc]` wildcards match against the item name.
/// - `docs/generated`, `/vendor` — a pattern containing `/` matches the path relative to the
///   compared root; a leading `/` is optional.
/// - `**` matches across folders: `src/**/fixtures`, `**/*.snap`.
/// - A trailing `/` (`build/`) matches folders only.
/// - Blank lines and lines starting with `#` are ignored.
nonisolated struct IgnoreMatcher: Sendable {
    static let defaultPatterns: [String] = [
        ".git",
        "node_modules",
        ".DS_Store",
        "build",
        "dist",
        ".target",
        ".pytest_cache",
        "DerivedData",
        ".build",
        "__pycache__",
        "xcuserdata",
        "*.pyc",
        "__MACOSX",
        ".claude",
        ".trae",
        "npm-cache",
        // Bookkeeping that macOS and Windows leave on drives, especially external ones.
        "._*",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
        "Thumbs.db",
        "desktop.ini",
        "$RECYCLE.BIN",
        "System Volume Information",
    ]

    /// Patterns added to the defaults over time, by revision. Existing users who customized
    /// their list get these appended once (see `AppSettings`).
    static let patternsAddedInRevision: [Int: [String]] = [
        2: [".claude", ".trae", "npm-cache"],
        3: ["._*", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100",
            "Thumbs.db", "desktop.ini", "$RECYCLE.BIN", "System Volume Information"],
    ]
    static let defaultPatternsRevision = 3

    private struct GlobRule: Sendable {
        let regex: NSRegularExpression
        let matchesRelativePath: Bool
        let directoryOnly: Bool
    }

    private let names: Set<String>
    private let directoryNames: Set<String>
    private let rules: [GlobRule]

    init(patterns: [String]) {
        var names = Set<String>()
        var directoryNames = Set<String>()
        var rules: [GlobRule] = []

        for raw in patterns {
            var pattern = raw.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty, !pattern.hasPrefix("#") else { continue }

            let directoryOnly = pattern.hasSuffix("/")
            while pattern.hasSuffix("/") { pattern.removeLast() }
            let anchored = pattern.hasPrefix("/")
            while pattern.hasPrefix("/") { pattern.removeFirst() }
            guard !pattern.isEmpty else { continue }

            let matchesRelativePath = anchored || pattern.contains("/")
            if !matchesRelativePath && !Self.containsWildcard(pattern) {
                if directoryOnly {
                    directoryNames.insert(pattern)
                } else {
                    names.insert(pattern)
                }
                continue
            }
            let expression = "^" + Self.regularExpression(forGlob: pattern) + "$"
            guard let regex = try? NSRegularExpression(pattern: expression) else { continue }
            rules.append(GlobRule(regex: regex, matchesRelativePath: matchesRelativePath, directoryOnly: directoryOnly))
        }

        self.names = names
        self.directoryNames = directoryNames
        self.rules = rules
    }

    func isIgnored(name: String, relativePath: String, isDirectory: Bool) -> Bool {
        if names.contains(name) { return true }
        if isDirectory && directoryNames.contains(name) { return true }
        for rule in rules where !rule.directoryOnly || isDirectory {
            let subject = rule.matchesRelativePath ? relativePath : name
            let range = NSRange(location: 0, length: subject.utf16.count)
            if rule.regex.firstMatch(in: subject, range: range) != nil { return true }
        }
        return false
    }

    /// Checks `relativePath` and every ancestor folder; used for file-system events, which
    /// can report paths deep inside ignored folders.
    func isPathOrAncestorIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
        let components = relativePath.split(separator: "/")
        var prefix = ""
        for (offset, component) in components.enumerated() {
            prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
            let isLast = offset == components.count - 1
            if isIgnored(name: String(component), relativePath: prefix, isDirectory: isLast ? isDirectory : true) {
                return true
            }
        }
        return false
    }

    private static func containsWildcard(_ pattern: String) -> Bool {
        pattern.contains { $0 == "*" || $0 == "?" || $0 == "[" }
    }

    static func regularExpression(forGlob glob: String) -> String {
        let characters = Array(glob)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                let isDoubleStar = index + 1 < characters.count && characters[index + 1] == "*"
                if isDoubleStar {
                    let followedBySlash = index + 2 < characters.count && characters[index + 2] == "/"
                    if followedBySlash {
                        result += "(?:.*/)?"
                        index += 3
                    } else {
                        result += ".*"
                        index += 2
                    }
                    continue
                }
                result += "[^/]*"
            case "?":
                result += "[^/]"
            case "\\" where index + 1 < characters.count:
                // A backslash makes the next character literal (`\*`, `\#`, `\ `).
                result += NSRegularExpression.escapedPattern(for: String(characters[index + 1]))
                index += 2
                continue
            case "[":
                if let close = characters[(index + 1)...].firstIndex(of: "]"), close > index + 1 {
                    var body = String(characters[(index + 1)..<close])
                    if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                    body = body.replacingOccurrences(of: "\\", with: "\\\\")
                    result += "[" + body + "]"
                    index = close + 1
                    continue
                }
                result += "\\["
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return result
    }
}

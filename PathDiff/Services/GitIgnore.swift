//
//  GitIgnore.swift
//  PathDiff
//

import Foundation

/// The rules of one `.gitignore` (or `.git/info/exclude`) file.
///
/// Follows git's semantics: patterns without a slash match a name at any depth below the
/// file's folder; patterns with a slash are anchored to that folder; `!` re-includes; a
/// trailing `/` matches folders only; the last matching rule wins; deeper files override
/// shallower ones.
nonisolated struct GitIgnoreFile: Sendable {
    struct Rule: Sendable {
        let regex: NSRegularExpression
        let isNegated: Bool
        let directoryOnly: Bool
        let matchesPath: Bool
    }

    /// Folder of the file, relative to the compared root (`""` for the root).
    let basePath: String
    let rules: [Rule]

    init?(contents: String, basePath: String) {
        var rules: [Rule] = []
        for rawLine in contents.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            if let rule = Self.parse(String(rawLine)) { rules.append(rule) }
        }
        guard !rules.isEmpty else { return nil }
        self.basePath = basePath
        self.rules = rules
    }

    static func load(directory: URL, basePath: String) -> GitIgnoreFile? {
        load(file: directory.appending(path: ".gitignore"), basePath: basePath)
    }

    /// Repository-local excludes, only present when the root is a git work tree.
    static func loadExclude(root: URL) -> GitIgnoreFile? {
        load(file: root.appending(path: ".git/info/exclude"), basePath: "")
    }

    private static func load(file: URL, basePath: String) -> GitIgnoreFile? {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return nil }
        return GitIgnoreFile(contents: text, basePath: basePath)
    }

    /// `true` = ignored, `false` = explicitly re-included, `nil` = no rule applies.
    func match(relativePath: String, name: String, isDirectory: Bool) -> Bool? {
        let subject: Substring
        if basePath.isEmpty {
            subject = relativePath[...]
        } else {
            guard relativePath.hasPrefix(basePath + "/") else { return nil }
            subject = relativePath.dropFirst(basePath.count + 1)
        }
        let pathSubject = String(subject)
        for rule in rules.reversed() where !rule.directoryOnly || isDirectory {
            let target = rule.matchesPath ? pathSubject : name
            if rule.regex.firstMatch(in: target, range: NSRange(location: 0, length: target.utf16.count)) != nil {
                return !rule.isNegated
            }
        }
        return nil
    }

    static func parse(_ line: String) -> Rule? {
        var pattern = line
        if pattern.hasPrefix("#") { return nil }

        // Trailing spaces are ignored unless escaped.
        while pattern.hasSuffix(" ") && !pattern.hasSuffix("\\ ") { pattern.removeLast() }
        guard !pattern.isEmpty else { return nil }

        var isNegated = false
        if pattern.hasPrefix("!") {
            isNegated = true
            pattern.removeFirst()
        } else if pattern.hasPrefix("\\!") || pattern.hasPrefix("\\#") {
            pattern.removeFirst()
        }

        var directoryOnly = false
        if pattern.hasSuffix("/") {
            directoryOnly = true
            while pattern.hasSuffix("/") { pattern.removeLast() }
        }
        guard !pattern.isEmpty else { return nil }

        let matchesPath = pattern.contains("/")
        while pattern.hasPrefix("/") { pattern.removeFirst() }
        guard !pattern.isEmpty else { return nil }

        let expression = "^" + IgnoreMatcher.regularExpression(forGlob: pattern) + "$"
        guard let regex = try? NSRegularExpression(pattern: expression) else { return nil }
        return Rule(regex: regex, isNegated: isNegated, directoryOnly: directoryOnly, matchesPath: matchesPath)
    }
}

/// The `.gitignore` files in effect for a folder: its own and all of its ancestors'.
nonisolated struct GitIgnoreStack: Sendable {
    private(set) var files: [GitIgnoreFile] = []

    func pushing(_ file: GitIgnoreFile?) -> GitIgnoreStack {
        guard let file else { return self }
        var copy = self
        copy.files.append(file)
        return copy
    }

    func isIgnored(relativePath: String, name: String, isDirectory: Bool) -> Bool {
        for file in files.reversed() {
            if let result = file.match(relativePath: relativePath, name: name, isDirectory: isDirectory) {
                return result
            }
        }
        return false
    }

    /// The stack in effect for the folder containing `relativePath`.
    static func forParent(of relativePath: String, root: URL) -> GitIgnoreStack {
        var stack = GitIgnoreStack()
            .pushing(GitIgnoreFile.loadExclude(root: root))
            .pushing(GitIgnoreFile.load(directory: root, basePath: ""))
        for ancestor in DiffTree.ancestorPaths(of: relativePath) {
            stack = stack.pushing(GitIgnoreFile.load(directory: root.appending(path: ancestor), basePath: ancestor))
        }
        return stack
    }
}

//
//  IgnoreRulesTests.swift
//  PathDiffTests
//

import Foundation
import Testing

@Suite("Ignore patterns and .gitignore")
struct IgnoreRulesTests {
    @Test(arguments: [
        (".git", ".git", true, true),
        ("node_modules", "a/b/node_modules", true, true),
        ("x.log", "src/x.log", false, true),
        ("x.logs", "x.logs", false, false),
        ("y", "docs/gen/y", false, true),
        ("gen", "docs/gen", true, false),
        ("vendor", "vendor", true, true),
        ("vendor", "src/vendor", true, false),
        ("tmp", "tmp", true, true),
        ("tmp", "tmp", false, false),
        ("a.snap", "x/y/a.snap", false, true),
        ("a.snap", "a.snap", false, true),
        ("file3.txt", "file3.txt", false, true),
        ("filex.txt", "filex.txt", false, false),
        ("main.swift", "src/main.swift", false, false),
        ("__MACOSX", "__MACOSX", true, true),
    ])
    func userPatterns(_ name: String, _ path: String, _ isDirectory: Bool, _ expected: Bool) {
        let matcher = IgnoreMatcher(patterns: IgnoreMatcher.defaultPatterns + [
            "*.log", "docs/gen/**", "/vendor", "tmp/", "**/*.snap", "# comment", "file[0-9].txt",
        ])
        #expect(matcher.isIgnored(name: name, relativePath: path, isDirectory: isDirectory) == expected)
    }

    @Test func ancestorsAreChecked() {
        let matcher = IgnoreMatcher(patterns: IgnoreMatcher.defaultPatterns)
        #expect(matcher.isPathOrAncestorIgnored(".git/objects/ab", isDirectory: false))
        #expect(!matcher.isPathOrAncestorIgnored("src/app/main.swift", isDirectory: false))
    }

    @Test(arguments: [
        ("a.log", false, true),
        ("x/keep.log", false, false),
        ("build", true, true),
        ("src/build", true, false),
        ("out", true, true),
        ("src/out", true, true),
        ("out", false, false),
        ("docs/a.tmp", false, true),
        ("docs/x/a.tmp", false, false),
        ("a/b/cache", true, true),
        ("#hash", false, true),
        ("spaced ", false, true),
        ("pkg/gen", true, true),
        ("gen", true, false),
        ("pkg/important.log", false, false),
        ("pkg/other.log", false, true),
    ])
    func gitIgnoreSemantics(_ path: String, _ isDirectory: Bool, _ expected: Bool) throws {
        let root = try #require(GitIgnoreFile(contents: "*.log\n!keep.log\n/build\nout/\ndocs/*.tmp\n**/cache\n\\#hash\nspaced\\ \n# comment\n", basePath: ""))
        let nested = try #require(GitIgnoreFile(contents: "gen/\n!important.log\n", basePath: "pkg"))
        let stack = GitIgnoreStack().pushing(root).pushing(nested)
        let name = String(path.split(separator: "/").last ?? "")
        #expect(stack.isIgnored(relativePath: path, name: name, isDirectory: isDirectory) == expected)
    }
}
